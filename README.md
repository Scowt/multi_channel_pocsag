# POCSAG paging receiver

Decode VHF pager traffic from an RTL-SDR and print it as clear text on the
console. Built for finding Ambulance Victoria / emergency-services paging in
the 148 MHz band.

## Setup

One root step, once, from the repository root:

```bash
sudo bash SUDO-SETUP.sh
```

Then **unplug and replug the dongle** and confirm it works:

```bash
rtl_test -t
```

You should see `Found 1 device(s): 0: Realtek, RTL2838UHIDIR`. If you instead
get `usb_claim_interface error -6`, the DVB-T kernel drivers are still bound —
reboot and try again.

## Finding a live channel

Channel assignments vary by location, so measure rather than guess:

```bash
bin/band-scan.sh 5m          # power sweep of 148-149 MHz, ranks carriers
bin/find-pocsag.sh 60        # dwells 60s per known channel, counts decodes
```

`find-pocsag.sh` prints a table of messages-per-channel and a sample line, and
saves every raw decode under `logs/`.

## Receiving all channels at once (recommended)

Paging is bursty and idle most of the time, so tuning one channel at a time
wastes most of the wait. `pocsag-multi.sh` uses GNU Radio to demodulate every
channel simultaneously from a single 1.0584 MHz capture covering
148.19-149.25 MHz:

```bash
bin/pocsag-multi.sh                  # all 8 channels until Ctrl-C
bin/pocsag-multi.sh --duration 1800  # half an hour, then stop
bin/pocsag-multi.sh --av             # highlight emergency traffic
bin/pocsag-multi.sh --channels 148.6875,148.9125
```

It also runs a **carrier detector** per channel, printing `~~ carrier up` /
`~~ carrier down` when a channel rises above its own quiet baseline. This
matters: it separates *no traffic* from *traffic that will not decode*. A
carrier that comes up but produces no message means a signal is there but is
the wrong baud, too weak, or not POCSAG at all.

Cost is about 420 MMAC/s for eight channels, which a Pi 5 handles comfortably.

## rtl_fm vs the GNU Radio path

Both are installed and both work, but they are not equivalent here. Measured
head to head on 148.6875 MHz:

| Path | 90-150s window |
|---|---|
| `rtl_fm \| multimon-ng` | **0 messages** |
| `pocsag-multi.sh` (GNU Radio) | decodes reliably |

The cause is adjacent-channel selectivity. There is a continuously keyed carrier
at 148.4961 MHz sitting **50 dB above the noise floor**, only 190 kHz from the
ambulance channel. `rtl_fm`'s decimation filter is broad enough to let it
through, where it dominates the tuner AGC and buries the paging bursts - in the
captured audio the 512-baud signature reached only +7 dB over noise. The GNU
Radio chain applies a proper 71-tap 8 kHz channel filter and decodes the same
bursts cleanly.

So `pocsag-rx.sh` is kept for strong, isolated channels, but **use
`pocsag-multi.sh` for Ambulance Victoria**.

## Receiving one channel

```bash
bin/pocsag-rx.sh                          # default 148.9125 MHz (SES/ambulance)
bin/pocsag-rx.sh -f 148.6875M             # a different channel
bin/pocsag-rx.sh -f 148.9125M --av        # highlight emergency traffic in red
bin/pocsag-rx.sh -f 148.9125M --only-av   # show nothing else
bin/pocsag-rx.sh --grep 'RICHMOND|MICA'   # arbitrary regex filter
bin/pocsag-rx.sh --capcode 1234567        # follow one pager address
bin/pocsag-rx.sh --quiet-numeric          # drop numeric-only heartbeats
```

Output is `time  baud  address  function  message`. Every decode is also
appended as JSON to `logs/pocsag.jsonl`, so you can query history:

```bash
jq -r 'select(.emergency_match) | "\(.ts) \(.text)"' logs/pocsag.jsonl
```

## Tuning for a weak or noisy signal

| Symptom | Try |
|---|---|
| Nothing at all | `-g 49.6` (max gain), or `-g 0` for auto |
| Garbled text | wrong baud — force it with `--512` or `--1200` |
| Drifting / partial decodes | crystal error: find it with `rtl_test -p`, then pass `-p <ppm>` |
| Strong local FM breaking through | drop gain to `-g 20` |
| Squelch cutting messages off | leave `-l 0` (the default); squelch hurts POCSAG |

Gain, ppm and frequency can also be set by environment variable:
`FREQ=148.6875M GAIN=49.6 PPM=12 bin/pocsag-rx.sh`

## Layout

| Path | What |
|---|---|
| `SUDO-SETUP.sh` | the only root-requiring step: packages, driver blacklist, udev |
| `bin/pocsag-multi.sh` | all channels at once via GNU Radio + carrier detection |
| `multichannel.py` | the GNU Radio flowgraph behind it |
| `bin/pocsag-rx.sh` | single channel: `rtl_fm` → `multimon-ng` → formatter |
| `bin/find-pocsag.sh` | dwell on each known channel, rank by decode count |
| `bin/band-scan.sh` | `rtl_power` sweep, ranks carriers by strength |
| `pocsagfmt.py` | formats/filters/de-dupes multimon-ng output, writes JSONL |
| `bandscan.py` | parses `rtl_power` CSV into a peak list + ASCII spectrum |
| `FREQUENCIES.md` | Victorian channel list and notes on EAS encryption |
| `logs/` | JSONL decodes, raw survey captures, power CSVs |
| `pagermon_sender.py` | queued, retrying PagerMon client (stdlib only) |
| `setup-pagermon.sh` | npm install + generate config, keys and credentials |
| `bin/pagermon-server.sh` | run the PagerMon web server |
| `SUDO-PAGERMON.sh` | installs Node.js (root) |
| `SUDO-PAGERMON-SERVICES.sh` | systemd units for both services (root) |

## PagerMon web UI

A private PagerMon instance stores every decode in SQLite and serves a web UI
to the LAN, with capcode aliases, search, and per-source filtering.

Setup, in order:

```bash
sudo bash SUDO-PAGERMON.sh            # 1. Node.js 20 + npm + sqlite3
bash setup-pagermon.sh                # 2. npm install, generate config + credentials
bash bin/pagermon-server.sh           # 3. run it (foreground, port 3000)
sudo bash SUDO-PAGERMON-SERVICES.sh   # 4. once happy, install systemd units
```

Then feed it:

```bash
bin/pocsag-multi.sh --av --pagermon-config pagermon-client.json
```

Each channel reports as its own PagerMon **source** (`148.6875`, `148.9125`, …)
so ambulance and SES traffic are distinguishable in the UI.

### Privacy

`setup-pagermon.sh` deliberately departs from PagerMon's shipped defaults:

| Setting | Shipped default | Here | Why |
|---|---|---|---|
| `messages.apiSecurity` | `false` | **`true`** | default lets anyone on the LAN read every message with no login |
| `auth.registration` | `false` | `false` | nobody can self-register |
| `auth.user` / password | `admin` / `changeme` | admin / generated | a documented default password on a LAN service is not private |
| `global.sessionSecret` | hardcoded in repo | generated | the shipped secret is public on GitHub |
| `auth.keys` | two example keys | one generated key | the shipped keys are public on GitHub |

Credentials land in `pagermon-credentials.txt` (mode 600).

### What gets forwarded

Everything that decodes, regardless of console filters - the console is a view,
PagerMon is the archive. Messages are stored complete, exactly as received.

`--redact` exists but is **off by default**: adding it masks caller names and
phone numbers before they reach the console, the JSONL log and PagerMon alike.
It is applied at decode time and is one-way, so anything captured while it was
on cannot be recovered later.

The sender mirrors PagerMon's own `client/reader.js` exactly: `POST /api/messages`,
`apikey` header, form-encoded `address` (zero-padded to 7 digits), `message`
(`<XXX>` tags stripped, `Ä`/`Ü` mapped to `[`/`]`), `datetime` as unix seconds,
and `source`. Delivery runs on a background thread with exponential-backoff
retries, so a stopped server never stalls decoding.

## Python environment

Everything runs through `.venv`. The scripts are standard-library only, with
one exception: GNU Radio ships as a Debian package with compiled bindings and
cannot be pip-installed, so `.venv/lib/python3.13/site-packages/system-dist-packages.pth`
points the venv at `/usr/lib/python3/dist-packages`. That keeps a single
interpreter for the whole project rather than mixing venv and system Python.

## Measured on this Pi

- Tuner locks to 1058400.010 Hz against a nominal 1058400 — 10 ppb, so no
  resampling is needed and the arbitrary resampler stays bypassed.
- Quiet-band noise floor is −53.3 dB on every channel.
- Gain matters enormously here: at `-g 40` the 148 MHz band looked completely
  flat. At `-g 49.6` real carriers appeared 15–20 dB above the floor. If you
  see nothing, raise gain before suspecting the antenna.
