#!/usr/bin/env python3
"""Format multimon-ng POCSAG output into readable console text.

Reads multimon-ng lines on stdin, prints timestamped, coloured, de-duplicated
messages, and appends every decode to a JSONL log.

Stdlib only. Run with the project's .venv/bin/python.
"""
import argparse
import atexit
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# POCSAG512: Address:  123456  Function: 0  Alpha:   SOME TEXT
LINE = re.compile(
    r"^POCSAG(?P<baud>\d+):\s+Address:\s*(?P<addr>\d+)\s+Function:\s*(?P<func>\d+)"
    r"(?:\s+(?P<kind>Alpha|Numeric|Skyper):\s?(?P<text>.*))?\s*$"
)
# Continuation lines that carry only a payload.
CONT = re.compile(r"^POCSAG(?P<baud>\d+):\s+(?P<kind>Alpha|Numeric|Skyper):\s?(?P<text>.*)$")

# Ambulance-Victoria-ish keywords. Tune with --grep.
# Matched against real traffic observed on 148.6875 (Ambulance Victoria) and
# 148.9125 (VICSES). The structural markers matter more than keywords: an AV
# dispatch is identified by SIG<n>, an AMPDS card code (CC: 10D4) and the
# Pat:/Age:/Gen: block, none of which contain an obvious word like "ambulance".
AV_DEFAULT = (
    r"(@@[A-Z]\d|\bSIG\d\b|\bCC:\s*\d{1,2}[A-Z]\d*|"
    r"\bPat:\s*\d+|\bAge:\s*\d+|\bPU:|\bREQ\d{3,}|\bDSP\d{3,}|"
    r"\bAMBUL\w*|\bAMBO\b|\bMICA\b|\bPARAMEDIC\w*|\bSTRETCHER\b|"
    r"\bHOSPITAL\b|\bPRIORITY\b|\bCODE\s?\d\b|"
    r"\bCFA\b|\bSES\b|\bFRV\b|STRUCTURE\s?FIRE|GRASS\s?FIRE|\bRESCUE\b|"
    r"TREE\s?DOWN|TRAFFIC\s?HAZARD|\bFLOOD\w*)"
)

DEFAULT_LOG = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "logs", "pocsag.jsonl")

PHONE_RE = re.compile(r"\b(?:0[2-8]\s?\d{4}\s?\d{4}|04\d{2}\s?\d{3}\s?\d{3})\b")
CALLER_RE = re.compile(r"(CALLER:\s*)([A-Z][A-Z'\-]+(?:\s+[A-Z][A-Z'\-]+)*)")


def redact(text: str) -> str:
    """Mask caller names and phone numbers. The RF traffic is public, but the
    logs need not be a contact list."""
    text = PHONE_RE.sub("[phone]", text)
    return CALLER_RE.sub(lambda m: m.group(1) + "[name]", text)

RESET = "\033[0m"
DIM = "\033[2m"
BOLD = "\033[1m"
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
GREY = "\033[90m"


def clean(text: str) -> str:
    """Strip control chars multimon-ng emits from noisy decodes."""
    text = text.replace("<NUL>", "").replace("<EOT>", "").replace("<SOH>", "")
    text = re.sub(r"<[A-Z]{2,3}>", " ", text)
    text = "".join(ch if ch.isprintable() or ch == " " else " " for ch in text)
    return re.sub(r"\s+", " ", text).strip()


def main() -> int:
    ap = argparse.ArgumentParser(description="Pretty-print multimon-ng POCSAG output.")
    ap.add_argument("--grep", metavar="REGEX",
                    help="only show messages whose text matches this regex")
    ap.add_argument("--av", action="store_true",
                    help="highlight likely Ambulance Victoria / emergency traffic")
    ap.add_argument("--only-av", action="store_true",
                    help="show ONLY messages matching the emergency-services filter")
    ap.add_argument("--capcode", metavar="ADDR", action="append", default=[],
                    help="only show these addresses (repeatable)")
    ap.add_argument("--min-len", type=int, default=1,
                    help="hide alpha messages shorter than this (default 1)")
    ap.add_argument("--dedupe", type=float, default=30.0,
                    help="suppress an identical message seen again within N seconds (default 30, 0=off)")
    ap.add_argument("--log", default=DEFAULT_LOG,
                    help="JSONL log path ('' to disable)")
    ap.add_argument("--no-color", action="store_true")
    ap.add_argument("--freq", default=os.environ.get("FREQ", ""),
                    help="frequency label recorded in the log")
    ap.add_argument("--label", default="",
                    help="short channel tag printed before each message")
    ap.add_argument("--pagermon-config", metavar="PATH",
                    help="JSON file with hostname/apikey/identifier; enables "
                         "forwarding every decoded message to PagerMon")
    ap.add_argument("--pagermon-source", metavar="NAME",
                    help="override the PagerMon 'source' for this channel")
    ap.add_argument("--redact", action="store_true",
                    help="mask caller names and phone numbers in output and log")
    ap.add_argument("--quiet-numeric", action="store_true",
                    help="hide numeric-only pages (usually beeps/heartbeats)")
    args = ap.parse_args()

    color = sys.stdout.isatty() and not args.no_color
    def c(s, col):
        return f"{col}{s}{RESET}" if color else s

    av_re = re.compile(AV_DEFAULT, re.I)
    grep_re = re.compile(args.grep, re.I) if args.grep else None
    caps = set(args.capcode)

    sender = None
    if args.pagermon_config:
        from pagermon_sender import PagerMonSender, load_config
        cfg = load_config(args.pagermon_config)
        sender = PagerMonSender(cfg["host"], cfg["apikey"],
                                source=args.pagermon_source or cfg["source"])
        atexit.register(sender.close)
        print(c(f"# forwarding to PagerMon at {cfg['host']} "
                f"as source '{args.pagermon_source or cfg['source']}'", GREY),
              file=sys.stderr, flush=True)

    logf = None
    if args.log:
        os.makedirs(os.path.dirname(args.log), exist_ok=True)
        logf = open(args.log, "a", buffering=1)

    seen: dict[str, float] = {}
    count = 0
    pending_addr = None
    pending_baud = None
    pending_func = None

    print(c(f"# POCSAG decoder ready {args.freq}  (Ctrl-C to stop)", GREY), flush=True)

    for raw in sys.stdin:
        raw = raw.rstrip("\n")
        m = LINE.match(raw)
        kind = text = None
        if m:
            pending_addr = m.group("addr")
            pending_baud = m.group("baud")
            pending_func = m.group("func")
            kind = m.group("kind")
            text = m.group("text")
        else:
            mc = CONT.match(raw)
            if mc and pending_addr:
                pending_baud = mc.group("baud")
                kind = mc.group("kind")
                text = mc.group("text")
            else:
                continue

        if kind is None:
            continue  # address-only tone page, nothing to print

        body = clean(text or "")
        if args.redact:
            body = redact(body)
        if not body:
            continue
        # PagerMon gets every decoded message, independent of the console
        # filters below - the console is a view, PagerMon is the archive.
        if sender is not None:
            sender.send(pending_addr, body)

        if kind == "Numeric" and args.quiet_numeric:
            continue
        if kind == "Alpha" and len(body) < args.min_len:
            continue
        if caps and pending_addr not in caps:
            continue
        if grep_re and not grep_re.search(body):
            continue

        is_av = bool(av_re.search(body))
        if args.only_av and not is_av:
            continue

        now = time.time()
        if args.dedupe:
            key = f"{pending_addr}|{body}"
            last = seen.get(key)
            if last and now - last < args.dedupe:
                continue
            seen[key] = now
            if len(seen) > 4000:
                cutoff = now - args.dedupe
                seen = {k: v for k, v in seen.items() if v > cutoff}

        ts = datetime.now().strftime("%H:%M:%S")
        count += 1

        addr_s = c(f"{pending_addr:>9}", CYAN)
        baud_s = c(f"{pending_baud:>4}", GREY)
        func_s = c(f"f{pending_func}", GREY)
        if is_av and (args.av or args.only_av):
            body_s = c(body, BOLD + RED)
            mark = c("!", RED)
        elif kind == "Numeric":
            body_s = c(body, YELLOW)
            mark = " "
        else:
            body_s = c(body, GREEN)
            mark = " "

        lbl = f"{c(args.label, YELLOW)} " if args.label else ""
        print(f"{c(ts, DIM)} {lbl}{baud_s} {addr_s} {func_s} {mark} {body_s}", flush=True)

        if logf:
            logf.write(json.dumps({
                "ts": datetime.now(timezone.utc).isoformat(),
                "freq": args.freq,
                "label": args.label,
                "baud": int(pending_baud),
                "address": int(pending_addr),
                "function": int(pending_func),
                "type": kind.lower(),
                "text": body,
                "emergency_match": is_av,
            }) + "\n")

    print(c(f"\n# {count} messages shown", GREY), file=sys.stderr)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except BrokenPipeError:
        sys.exit(0)
