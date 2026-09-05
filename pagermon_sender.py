#!/usr/bin/env python3
"""Send decoded POCSAG messages to a PagerMon server.

Mirrors the behaviour of PagerMon's own client/reader.js so the server sees
exactly what it expects:

  POST {host}/api/messages
  headers: apikey, X-Requested-With, User-Agent
  body (form-encoded): address, message, datetime, source

  - address is zero-padded to 7 digits      (reader.js padDigits(address, 7))
  - <XXX> control tags are stripped, and the German umlauts multimon-ng emits
    for bracket characters are mapped back                (Ä -> [ , Ü -> ])
  - datetime is a unix timestamp in SECONDS              (moment().unix())
  - messages with an address of 2 chars or fewer are dropped

Sending happens on a background thread so a slow or down server never stalls
decoding. Failed sends retry with exponential backoff, as reader.js does.

Standard library only - no pip install needed.
"""
import json
import queue
import re
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

TAG_RE = re.compile(r"<[A-Za-z]{3}>")


def clean_for_pagermon(text: str) -> str:
    """Apply reader.js's exact message cleaning."""
    text = TAG_RE.sub("", text)
    text = text.replace("Ä", "[").replace("Ü", "]")
    return text.strip()


def pad_address(address: str, digits: int = 7) -> str:
    return str(address).rjust(digits, "0")


class PagerMonSender:
    """Queued, retrying PagerMon client."""

    def __init__(self, host, apikey, source="POCSAG", timeout=10.0,
                 max_retries=10, max_queue=5000, verbose=False):
        host = host.rstrip("/")
        self.uri = host + "/api/messages"
        self.apikey = apikey
        self.source = source
        self.timeout = timeout
        self.max_retries = max_retries
        self.verbose = verbose
        self.q = queue.Queue(maxsize=max_queue)
        self.sent = 0
        self.failed = 0
        self.dropped = 0
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()

    def send(self, address, message, datetime_unix=None, source=None):
        """Queue a message. Never blocks and never raises."""
        body = clean_for_pagermon(message or "")
        addr = str(address or "").strip()
        # reader.js checks the raw address length before padding.
        if len(addr) <= 2 or not body:
            return False
        item = {
            "address": pad_address(addr),
            "message": body,
            "datetime": int(datetime_unix if datetime_unix is not None else time.time()),
            "source": source or self.source,
        }
        try:
            self.q.put_nowait(item)
            return True
        except queue.Full:
            self.dropped += 1
            return False

    def _post(self, item):
        data = urllib.parse.urlencode(item).encode()
        req = urllib.request.Request(
            self.uri,
            data=data,
            headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "X-Requested-With": "XMLHttpRequest",
                "User-Agent": "PagerMon reader.js",
                "apikey": self.apikey,
            },
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            return r.status, r.read(200).decode("utf-8", "replace")

    def _run(self):
        while not self._stop.is_set():
            try:
                item = self.q.get(timeout=0.5)
            except queue.Empty:
                continue
            for attempt in range(self.max_retries + 1):
                if self._stop.is_set():
                    break
                try:
                    status, body = self._post(item)
                    self.sent += 1
                    if self.verbose:
                        print(f"# pagermon {status} {body[:60]}", file=sys.stderr, flush=True)
                    break
                except Exception as e:
                    if attempt >= self.max_retries:
                        self.failed += 1
                        print(f"# pagermon: giving up after {attempt} retries: {e}",
                              file=sys.stderr, flush=True)
                        break
                    delay = min(2 ** attempt, 60)
                    if self.verbose or attempt == 0:
                        print(f"# pagermon: send failed ({e}), retry in {delay}s",
                              file=sys.stderr, flush=True)
                    if self._stop.wait(delay):
                        break
            self.q.task_done()

    def stats(self):
        return {"sent": self.sent, "failed": self.failed,
                "dropped": self.dropped, "queued": self.q.qsize()}

    def close(self, drain_timeout=5.0):
        deadline = time.time() + drain_timeout
        while not self.q.empty() and time.time() < deadline:
            time.sleep(0.1)
        self._stop.set()
        self._thread.join(timeout=2.0)


def load_config(path):
    """Read host/apikey/source from a JSON file, mirroring the client's config."""
    with open(path) as fh:
        cfg = json.load(fh)
    return {
        "host": cfg.get("hostname", "http://127.0.0.1:3000"),
        "apikey": cfg.get("apikey", ""),
        "source": cfg.get("identifier", "POCSAG"),
    }


if __name__ == "__main__":
    # Smoke test:  python pagermon_sender.py <host> <apikey> [source]
    if len(sys.argv) < 3:
        print(__doc__)
        print("usage: pagermon_sender.py <host> <apikey> [source]")
        sys.exit(2)
    s = PagerMonSender(sys.argv[1], sys.argv[2],
                       sys.argv[3] if len(sys.argv) > 3 else "TEST", verbose=True)
    ok = s.send("1234567", "Test message from pagermon_sender.py <EOT>")
    print("queued:", ok)
    s.close()
    print("stats:", s.stats())
