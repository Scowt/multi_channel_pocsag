# Victorian VHF paging channels

POCSAG paging in Victoria lives in the **148-149 MHz** VHF band at **512 baud**.

## Verified on this Pi, 2026-09-05

Measured by IQ capture and confirmed by live decoding, not taken from a list:

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

## What this traffic contains

Patient age, sex and presenting condition; incident addresses; and for SES jobs,
caller names and mobile numbers. Receiving it is legal in Australia; republishing
it is where the Radiocommunications Act and privacy law apply.

`--redact` masks caller names and phone numbers in both console output and the
JSONL log. Use it if the log is going anywhere but your own disk.

## Finding channels yourself

1. `bin/band-scan.sh 5m` - power sweep, ranks carriers.
2. `bin/find-pocsag.sh 60` - dwells per channel, counts real decodes.
3. `bin/pocsag-multi.sh --av` - watches every channel at once.

Use `--gain 49.6`, not `auto`. Measured on this Pi 2026-09-05, the R820T's
AGC drives the front end hard enough that its own noise and intermod bury the
signal: the floor sits at -38 dB with carriers only +6-8 dB above it, and
nothing decodes. At `-g 49.6` the floor drops to -50 dB - close to the -53.3 dB
quiet-band figure - and the same carriers rise to +18.7 dB, which decodes on the
first burst. Gain is multiplicative and cannot change carrier-to-noise ratio on
its own, so a CNR collapse like that is the tell for AGC misbehaving rather than
for a weak antenna.

If the band looks dead, raise gain before suspecting the antenna. A flat band
with the floor 10-12 dB HIGHER than usual is the AGC signature; a genuinely
disconnected antenna lowers the floor instead, because it stops collecting
ambient RF. The continuous carrier on 148.4961 is the fastest check either way -
it is always transmitting, so if it is not well clear of the floor, the problem
is the receive path, not the traffic.
