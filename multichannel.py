#!/usr/bin/env python3
"""Watch every Victorian POCSAG paging channel at once from a single RTL-SDR.

One 1 MHz capture covers ~148.14-149.16 MHz. Each channel is shifted to
baseband, FM-demodulated and fed to its own multimon-ng, whose output is
formatted by pocsagfmt.py. Because paging is bursty, watching eight channels
in parallel finds traffic roughly eight times faster than tuning them serially.

Signal chain, per channel:
    xlating FIR (decim 6)  ->  LPF (decim 4)  ->  quadrature demod
      ->  LPF (decim 2)  ->  arbitrary resampler (exact 22050 Hz)
      ->  float->short   ->  multimon-ng  ->  pocsagfmt.py

Run via bin/pocsag-multi.sh.
"""
import argparse
import os
import signal
import math
import subprocess
import sys
import threading
import time

from gnuradio import analog, blocks, gr
from gnuradio import filter as grfilter
from gnuradio.filter import firdes
import osmosdr

ROOT = os.path.dirname(os.path.abspath(__file__))
PY = os.path.join(ROOT, ".venv", "bin", "python")

# Victorian VHF paging channels (MHz). See FREQUENCIES.md.
DEFAULT_CHANNELS = [
    148.3375, 148.3625, 148.4961, 148.5625, 148.5875,
    148.6375, 148.6875, 148.7988, 148.9125, 148.9375,
]

AUDIO_RATE = 22050          # multimon-ng's required POCSAG input rate
SAMP_RATE = 22050 * 48      # 1_058_400 Hz, an exact multiple
MAX_DEV = 4500.0            # NBFM deviation for paging


class MultiPocsag(gr.top_block):
    def __init__(self, channels_mhz, center_hz, samp_rate, gain, ppm, sinks):
        """channels_mhz is in MHz; center_hz is in Hz. Keep the units explicit -
        mixing them silently tunes every channel to the same frequency."""
        gr.top_block.__init__(self, "multi-pocsag")

        self.src = osmosdr.source(args="rtl=0")
        self.src.set_sample_rate(samp_rate)
        self.src.set_center_freq(center_hz)
        self.src.set_freq_corr(ppm)
        # Measured on this dongle: manual gain gives ~20x LESS signal than the
        # tuner AGC (mean|iq| 0.72 vs 15.5). Auto is the right default.
        if gain is None:
            self.src.set_gain_mode(True)
        else:
            self.src.set_gain_mode(False)
            self.src.set_gain(gain)
            self.src.set_if_gain(20)
            self.src.set_bb_gain(20)
        self.src.set_bandwidth(samp_rate)

        actual = self.src.get_sample_rate()
        self.actual_rate = actual

        # Stage A: wide transition band keeps the tap count low; anything that
        # survives here is cleaned up by stage B.
        taps_a = firdes.low_pass(1.0, actual, 10_000, 70_000)
        rate_a = actual / 6.0
        taps_b = firdes.low_pass(1.0, rate_a, 8_000, 6_000)
        rate_b = rate_a / 4.0
        taps_c = firdes.low_pass(1.0, rate_b, 4_500, 6_500)
        rate_c = rate_b / 2.0

        self.taps = (len(taps_a), len(taps_b), len(taps_c))
        self.rates = (rate_a, rate_b, rate_c)
        self.resamp_ratio = AUDIO_RATE / rate_c
        self.probes = []

        for ch_mhz, fd in zip(channels_mhz, sinks):
            offset = ch_mhz * 1e6 - center_hz
            xlate = grfilter.freq_xlating_fir_filter_ccf(6, taps_a, offset, actual)
            lpf1 = grfilter.fir_filter_ccf(4, taps_b)
            demod = analog.quadrature_demod_cf(rate_b / (2 * 3.14159265 * MAX_DEV))
            lpf2 = grfilter.fir_filter_fff(2, taps_c)
            to_short = blocks.float_to_short(1, 32767 * 0.8)
            sink = blocks.file_descriptor_sink(gr.sizeof_short, fd)

            # Carrier detector: mean power on the narrowed complex stream. This
            # tells us a channel was ACTIVE even when nothing decodes, which
            # separates "no traffic" from "traffic we cannot decode".
            mag = blocks.complex_to_mag_squared(1)
            avg = blocks.moving_average_ff(int(rate_b * 0.1), 1.0 / int(rate_b * 0.1), 4000)
            probe = blocks.probe_signal_f()
            self.connect(lpf1, mag, avg, probe)
            self.probes.append(probe)

            chain = [self.src, xlate, lpf1, demod, lpf2]
            # The tuner lands within a few Hz of nominal, so the resampler is
            # normally unnecessary. Only pay for it if the rate really drifted.
            ratio = AUDIO_RATE / rate_c
            if abs(ratio - 1.0) > 1e-4:
                rtaps = firdes.low_pass(32, 32 * rate_c, rate_c * 0.45, rate_c * 0.1)
                chain.append(grfilter.pfb_arb_resampler_fff(ratio, rtaps, 32))
            chain += [to_short, sink]
            self.connect(*chain)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--channels", default=",".join(str(c) for c in DEFAULT_CHANNELS),
                    help="comma-separated channel frequencies in MHz")
    ap.add_argument("--center", type=float, default=0.0,
                    help="tuner centre in MHz (default: midpoint of the channels)")
    ap.add_argument("--gain", default="auto",
                    help="tuner gain in dB, or 'auto' for AGC (default)")
    ap.add_argument("--ppm", type=int, default=0)
    ap.add_argument("--duration", type=float, default=0,
                    help="stop after N seconds (0 = run until Ctrl-C)")
    ap.add_argument("--av", action="store_true", help="highlight emergency traffic")
    ap.add_argument("--only-av", action="store_true")
    ap.add_argument("--quiet-numeric", action="store_true")
    ap.add_argument("--redact", action="store_true",
                    help="mask caller names and phone numbers")
    ap.add_argument("--pagermon-config", metavar="PATH",
                    help="forward all decodes to PagerMon using this config file")
    ap.add_argument("--log", default=os.path.join(ROOT, "logs", "pocsag.jsonl"))
    ap.add_argument("--no-color", action="store_true")
    ap.add_argument("--carrier-db", type=float, default=6.0,
                    help="report a carrier when a channel rises this many dB "
                         "above its quiet baseline (0 disables)")
    args = ap.parse_args()

    channels = [float(c) for c in args.channels.split(",") if c.strip()]
    if not channels:
        print("no channels given", file=sys.stderr)
        return 2
    center = args.center or (min(channels) + max(channels)) / 2.0

    span = (max(channels) - min(channels)) * 1e6
    if span > SAMP_RATE * 0.8:
        print(f"channel span {span/1e6:.3f} MHz exceeds usable bandwidth "
              f"{SAMP_RATE*0.8/1e6:.3f} MHz - split into two runs", file=sys.stderr)
        return 2

    procs = []
    sinks = []
    for ch in channels:
        label = f"{ch:.4f}"
        fmt_cmd = [PY, os.path.join(ROOT, "pocsagfmt.py"),
                   "--freq", label, "--label", label]
        if args.av:
            fmt_cmd.append("--av")
        if args.only_av:
            fmt_cmd.append("--only-av")
        if args.quiet_numeric:
            fmt_cmd.append("--quiet-numeric")
        if args.redact:
            fmt_cmd.append("--redact")
        if args.pagermon_config:
            # Each channel reports itself as a distinct PagerMon source, so the
            # web UI can tell ambulance traffic from SES at a glance.
            fmt_cmd += ["--pagermon-config", args.pagermon_config,
                        "--pagermon-source", label]
        if args.no_color:
            fmt_cmd.append("--no-color")
        fmt_cmd += ["--log", args.log]

        fmt = subprocess.Popen(fmt_cmd, stdin=subprocess.PIPE)
        mm = subprocess.Popen(
            ["multimon-ng", "-a", "POCSAG512", "-a", "POCSAG1200", "-a", "POCSAG2400",
             "-f", "auto", "-e", "-u", "-t", "raw", "/dev/stdin"],
            stdin=subprocess.PIPE, stdout=fmt.stdin, stderr=subprocess.DEVNULL)
        fmt.stdin.close()
        procs.append((mm, fmt))
        sinks.append(mm.stdin.fileno())

    gain = None if str(args.gain).lower() == "auto" else float(args.gain)
    tb = MultiPocsag(channels, center * 1e6, SAMP_RATE, gain, args.ppm, sinks)

    print(f"# centre {center:.4f} MHz  rate {tb.actual_rate/1e6:.6f} Msps  "
          f"gain {args.gain}  taps {tb.taps}  resamp {tb.resamp_ratio:.6f}", file=sys.stderr)
    print(f"# watching {len(channels)} channels: "
          f"{', '.join(f'{c:.4f}' for c in channels)}", file=sys.stderr)

    stop = False

    def handler(signum, frame):
        nonlocal stop
        stop = True

    signal.signal(signal.SIGINT, handler)
    signal.signal(signal.SIGTERM, handler)

    def watch_carriers():
        """Report channels whose power rises well above their own quiet baseline.

        The flowgraph needs a moment before probes return real values, so we
        warm up first and seed each baseline from the median of a quiet window
        rather than a single reading.
        """
        n = len(channels)
        WARMUP, SEED = 4.0, 6.0
        t_start = time.time()
        seed = [[] for _ in range(n)]
        base = [None] * n
        active = [False] * n
        since = [0.0] * n

        while not stop:
            time.sleep(0.25)
            now = time.time()
            elapsed = now - t_start
            if elapsed < WARMUP:
                continue
            for i, pr in enumerate(tb.probes):
                lvl = pr.level()
                if lvl <= 0.0:
                    continue
                db = 10.0 * math.log10(lvl)
                if base[i] is None:
                    seed[i].append(db)
                    if elapsed > WARMUP + SEED and len(seed[i]) >= 8:
                        q = sorted(seed[i])
                        base[i] = q[len(q) // 2]
                        print(f"# baseline {channels[i]:.4f} MHz = {base[i]:.1f} dB",
                              file=sys.stderr, flush=True)
                    continue
                if not active[i] and db > base[i] + args.carrier_db:
                    active[i] = True
                    since[i] = now
                    print(f"{time.strftime('%H:%M:%S')} "
                          f"~~ carrier up   {channels[i]:.4f} MHz  "
                          f"{db - base[i]:+.1f} dB", file=sys.stderr, flush=True)
                elif active[i] and db < base[i] + args.carrier_db * 0.5:
                    active[i] = False
                    print(f"{time.strftime('%H:%M:%S')} "
                          f"~~ carrier down {channels[i]:.4f} MHz  "
                          f"after {now - since[i]:.1f}s", file=sys.stderr, flush=True)
                elif not active[i]:
                    # Track the quiet floor slowly; never let a burst raise it.
                    base[i] = min(base[i], base[i] * 0.995 + db * 0.005)

    tb.start()
    t0 = time.time()
    if args.carrier_db > 0:
        threading.Thread(target=watch_carriers, daemon=True).start()
    try:
        while not stop:
            if args.duration and time.time() - t0 >= args.duration:
                break
            time.sleep(0.5)
    finally:
        tb.stop()
        tb.wait()
        for mm, fmt in procs:
            for p in (mm, fmt):
                try:
                    p.terminate()
                except Exception:
                    pass
        for mm, fmt in procs:
            for p in (mm, fmt):
                try:
                    p.wait(timeout=3)
                except Exception:
                    p.kill()
    print(f"\n# stopped after {time.time()-t0:.0f}s", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
