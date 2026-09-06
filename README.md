# POCSAG paging receiver

Decode VHF pager traffic from an RTL-SDR and print it as clear text on the
console. Built for finding Ambulance Victoria / emergency-services paging in
the 148 MHz band, with an optional private PagerMon instance for archiving and
searching what it hears.

## Setup

Two scripts. Everything needing root is in one, everything else in the other:

```bash
sudo bash sudo-setup.sh   # 1. root: packages, driver blacklist, udev, systemd units
bash setup.sh             # 2. you:  venv, clone PagerMon, generate config + secrets
sudo bash sudo-setup.sh   # 3. root: re-run to start the services
```

Step 3 is the same script again, deliberately. `sudo-setup.sh` installs the
systemd units on the first pass but refuses to start them until `setup.sh` has
generated PagerMon's config — so re-running it is what brings the stack up. Both
scripts are idempotent, though `setup.sh` regenerates the admin password and API
key each time it runs.

Then **unplug and replug the dongle** and confirm it works:

```bash
rtl_test -t
```

You should see `Found 1 device(s): 0: Realtek, RTL2838UHIDIR`. If you instead
get `usb_claim_interface error -6`, the DVB-T kernel drivers are still bound —
reboot and try again.

PagerMon is installed to `~/opt/pagermon`. Override with `PAGERMON_HOME` if you
want it elsewhere; `setup.sh` and `bin/pagermon-server.sh` both honour it.

## Victorian VHF paging channels

POCSAG paging in Victoria lives in the **148-149 MHz** VHF band at **512 baud**.
Measured here by IQ capture and confirmed by live decoding, not taken from a
list:

| Frequency (MHz) | Peak above floor | Character | Confirmed content |
|---|---|---|---|
| 148.3625 | +30.4 dB | continuous | paging |
| 148.4961 | **+50.1 dB** | continuous carrier | strongest signal in the band |
| 148.5625 | +31.4 dB | continuous | paging |
| 148.6375 | +33.5 dB | mostly continuous | paging |
| **148.6875** | **+36.7 dB** | **bursty** | **Ambulance Victoria dispatch** |
| **148.9125** | **+37.5 dB** | **bursty** | **VICSES** |
| 148.3375 | +15.6 dB | weak | paging |
| 148.5875 | +13.6 dB | weak | - |
| 148.7988 | +12.7 dB | weak | - |
| 148.9375 | +14.0 dB | weak | - |

The peak-versus-mean gap is the useful discriminator. A channel whose peak sits
far above its mean is bursty, and bursty means dispatch traffic. 148.4961 is the
loudest signal in the band but its peak and mean are nearly equal, so it is a
continuously keyed carrier rather than something worth watching for jobs.

## The Emergency Alerting System is NOT encrypted

This was the open question when this project started, and it is now settled by
observation rather than by reading. The statewide EAS that pages CFA, FRV,
VICSES and rural Ambulance Victoria crews transmits in **clear text**.

An Ambulance Victoria dispatch on 148.6875 has the shape below.

> **This is a synthetic example.** Every value in it is invented - the incident
> number, unit code, times, address, map reference and patient details are all
> placeholders arranged in the real field layout. No received message, and no
> real person's data, appears anywhere in this repository.

```
@@E26010100001 SIG1 XMPL0000 REQ1200 DSP1201 LOC 10 EXAMPLE ST SAMPLETOWN
/SPECIMEN RD //TEMPLATE CR M 000 A0 SVVB C 0000 A00 CC: 10D4 - A CHEST
PAIN/DISCOMFORT: CLAMMY OR COLD SWEATS Pat:1 Age:90 Years Gen:M [XMPL]
```

Fields: `@@E` EAS emergency prefix, `SIG1` signal level, responding unit,
`REQ`/`DSP` request and dispatch times, location with cross streets, Melway/VicRoads
map reference, `CC:` AMPDS card code (10D4 = chest pain), patient count, age and sex.

Patient transport bookings appear as `PU:` (pickup) messages. VICSES on 148.9125
uses a different shape - `S26095nnnn`, a unit code such as `[CRAB]` or `[YACK]`,
and an incident type like TREE DOWN or TRAFFIC HAZARD.

The 2014 ABC report quoting a CFA radio technician calling for encryption is
still an accurate description of the situation twelve years later.

### What this traffic contains

Patient age, sex and presenting condition; incident addresses; and for SES jobs,
caller names and mobile numbers. Receiving it is legal in Australia; republishing
it is where the Radiocommunications Act and privacy law apply.

`--redact` masks caller names and phone numbers in both console output and the
JSONL log. Use it if the log is going anywhere but your own disk.

## Finding a live channel

Channel assignments vary by location, so measure rather than guess:

```bash
bin/band-scan.sh 5m          # power sweep of 148-149 MHz, ranks carriers
bin/find-pocsag.sh 60        # dwells 60s per known channel, counts decodes
bin/pocsag-multi.sh --av     # watch every channel at once
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

## Gain

**Use `--gain 49.6`, not `auto`.** Measured on this Pi 2026-09-05, the R820T's
AGC drives the front end hard enough that its own noise and intermod bury the
signal: the floor sits at -38 dB with carriers only +6-8 dB above it, and
nothing decodes. At `-g 49.6` the floor drops to -50 dB — close to the -53.3 dB
quiet-band figure — and the same carriers rise to +18.7 dB, which decodes on the
first burst. The `pocsag-rx.service` unit pins this, so the service does not
inherit the AGC's behaviour.

Gain is multiplicative and cannot change carrier-to-noise ratio on its own, so a
CNR collapse like that is the tell for AGC misbehaving rather than for a weak
antenna. If the band looks dead, raise gain before suspecting the antenna:

| Observation | Diagnosis |
|---|---|
| Floor **10-12 dB higher** than usual, CNR collapsed | AGC misbehaving — pin the gain |
| Floor **lower** than usual | antenna disconnected — it stops collecting ambient RF |

The continuous carrier on 148.4961 is the fastest check either way. It is always
transmitting, so if it is not well clear of the floor, the problem is the receive
path, not the traffic.

## Tuning for a weak or noisy signal

| Symptom | Try |
|---|---|
| Nothing at all | `-g 49.6` (max gain) — see **Gain** above |
| Garbled text | wrong baud — force it with `--512` or `--1200` |
| Drifting / partial decodes | crystal error: find it with `rtl_test -p`, then pass `-p <ppm>` |
| Strong local FM breaking through | drop gain to `-g 20` |
| Squelch cutting messages off | leave `-l 0` (the default); squelch hurts POCSAG |

Gain, ppm and frequency can also be set by environment variable:
`FREQ=148.6875M GAIN=49.6 PPM=12 bin/pocsag-rx.sh`

## Layout

| Path | What |
|---|---|
| `sudo-setup.sh` | every root step: packages, driver blacklist, udev, systemd units |
| `setup.sh` | every non-root step: venv, clone PagerMon, config, keys, credentials |
| `bin/pocsag-multi.sh` | all channels at once via GNU Radio + carrier detection |
| `multichannel.py` | the GNU Radio flowgraph behind it |
| `bin/pocsag-rx.sh` | single channel: `rtl_fm` → `multimon-ng` → formatter |
| `bin/find-pocsag.sh` | dwell on each known channel, rank by decode count |
| `bin/band-scan.sh` | `rtl_power` sweep, ranks carriers by strength |
| `pocsagfmt.py` | formats/filters/de-dupes multimon-ng output, writes JSONL |
| `bandscan.py` | parses `rtl_power` CSV into a peak list + ASCII spectrum |
| `pagermon_sender.py` | queued, retrying PagerMon client (stdlib only) |
| `bin/pagermon-server.sh` | run the PagerMon web server in the foreground |
| `logs/` | JSONL decodes, raw survey captures, power CSVs |

## PagerMon web UI

A private PagerMon instance stores every decode in SQLite and serves a web UI
to the LAN, with capcode aliases, search, and per-source filtering. It lives in
`~/opt/pagermon` and is set up by the two scripts under **Setup** above.

Once running, both services start at boot:

```bash
systemctl status pagermon pocsag-rx
journalctl -u pocsag-rx -f
```

To run the web server in the foreground instead of under systemd:

```bash
bash bin/pagermon-server.sh           # port 3000
```

To feed it by hand rather than via the service:

```bash
bin/pocsag-multi.sh --av --gain 49.6 --pagermon-config pagermon-client.json
```

Each channel reports as its own PagerMon **source** (`148.6875`, `148.9125`, …)
so ambulance and SES traffic are distinguishable in the UI.

### Privacy

`setup.sh` deliberately departs from PagerMon's shipped defaults:

| Setting | Shipped default | Here | Why |
|---|---|---|---|
| `messages.apiSecurity` | `false` | **`true`** | default lets anyone on the LAN read every message with no login |
| `auth.registration` | `false` | `false` | nobody can self-register |
| `auth.user` / password | `admin` / `changeme` | admin / generated | a documented default password on a LAN service is not private |
| `global.sessionSecret` | hardcoded in repo | generated | the shipped secret is public on GitHub |
| `auth.keys` | two example keys | one generated key | the shipped keys are public on GitHub |

Credentials land in `pagermon-credentials.txt` (mode 600). That file and
`pagermon-client.json` are both gitignored — they hold a live API key.

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

Everything runs through `.venv`, created by `setup.sh`. The scripts are
standard-library only, with one exception: GNU Radio ships as a Debian package
with compiled bindings and cannot be pip-installed, so a
`system-dist-packages.pth` file in the venv's site-packages points it at
`/usr/lib/python3/dist-packages`. That keeps a single interpreter for the whole
project rather than mixing venv and system Python.

## Measured on this Pi

- Tuner locks to 1058400.010 Hz against a nominal 1058400 — 10 ppb, so no
  resampling is needed and the arbitrary resampler stays bypassed.
- Quiet-band noise floor is −53.3 dB on every channel.
- Gain matters enormously here: at `-g 40` the 148 MHz band looked completely
  flat. At `-g 49.6` real carriers appeared 15–20 dB above the floor. If you
  see nothing, raise gain before suspecting the antenna.
