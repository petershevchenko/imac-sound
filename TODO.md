# Handoff / TODO — snd-hda-codec-cs8409-imac

**Working version: 1.19** (built & verified; 1.20 = 1.19 + log/doc cleanup,
functionally identical). git HEAD is still 1.14 — 1.15–1.20 are built locally
but **not yet committed** (see "HP/speaker auto-mute — SOLVED" for what changed).

## Current state

| Feature | Status |
|---|---|
| 🎧 Headphone output (CS42L83 / ASP2, 44.1 kHz) | WORKS |
| 🎤 Internal mic (DMIC2, pin 0x45 → ADC 0x23) | WORKS |
| 🔊 Internal speakers (4× TAS5764 on ASP1 4-ch TDM) | WORKS — stereo correct (4.1/2.1/stereo all good) |
| 🔀 HP ↔ speaker auto-mute (jack in → speakers off, HP plays) | WORKS (1.19, verified 7 cycles) |
| Suspend/resume | WORKS (audio comes back) |

Build/iterate: edit `codecs/cirrus/cs8409.{c,h}` / `cs8409-tables.c`, bump
`PACKAGE_VERSION` in `dkms.conf` + the path in
`debian/snd-hda-codec-cs8409-imac-dkms.install`, add a `debian/changelog` entry,
`dpkg-buildpackage -us -uc -b`, `sudo dpkg -i ../...deb && sudo reboot`.
Compile-check first: `make -C /lib/modules/$(uname -r)/build M="$PWD" modules`.

Testing as petershev over SSH: `export XDG_RUNTIME_DIR=/run/user/1000` then
`pactl` / `pw-play`. petershev is in the `audio` group (device access without a
GNOME login). **Do NOT use /usr/share/sounds/alsa/Front_*.wav for stereo tests —
they are MONO** (PipeWire duplicates them, always sounds centered). Generate a
true one-sided stereo wav with python `wave`, or use GNOME → Sound → Test.

## HP/speaker auto-mute — SOLVED (v1.16–1.19)

**Goal achieved:** headphone in → internal speakers mute & HP plays; HP out →
speakers play. Implemented in `codecs/cirrus/cs8409.c`.

How it actually works (several wrong turns corrected along the way):

1. **No jack interrupt.** The CS42L83 delivers NO unsolicited response through
   the CS8409 on this board (confirmed: real plug/unplug produced zero unsol
   events even with pre-filter logging). So detection is **polled**: a 500 ms
   `delayed_work` (`cs8409_cs42l83_jack_poll_work`, started in `hw_init`,
   re-armed on resume, cancelled on suspend/remove).
2. **Tip-sense read.** The shared CS42L42 `TSRS_PLUG_STATUS` (TS_PLUG=3) encoding
   does NOT apply here — it reads single bits, never 0/3. Use the raw tip-sense
   LEVEL: `DET_STATUS1` (0x1b77) bit7. Measured **unplugged = 0x16 (bit7=0)**,
   **plugged = 0x96 (bit7=1)**. Polarity macro: `CS42L83_TIP_SENSE_LEVEL_PRESENT`
   (=1; flip to 0 if ever backwards).
3. **Muting via the amp GPIO, not the generic auto-mute.** The speakers parse as
   line-outs (`speaker_outs=0`), so "Auto-Mute Mode" defaults off; and
   WirePlumber turns it off anyway and only does cosmetic port switching. So the
   driver mutes the speakers itself by gating **GPIO4** (the external TAS5764 amp
   enable, `CS8409_CS42L83_AMP_PDN`): amps on when HP out, off when HP in
   (`cs8409_cs42l83_set_speaker_amps` / `cs8409_cs42l83_update_outputs`). Nothing
   in the parser or userspace touches that GPIO → conflict-free, guaranteed
   silence, no hum. `suppress_auto_mute = 1` is kept so the confusing
   userspace-disabled control is gone.
4. **Pin-sense intercept made machine-aware.** `cs8409_cs42l42_exec_verb` only
   knew the Dell ASP1 NIDs; it now returns hp/mic presence for the iMac ASP2
   NIDs (0x2c / 0x3c) under `CS8409_IMAC18_3`, so the jack kcontrol/PipeWire see
   the real state.

Headphone output itself was verified fine while ASP1/speakers run (the TODO's
old open question) — the earlier "no HP sound" was just the HP volume at ~7%.
Plugging/unplugging briefly pauses the playing app (PipeWire reroutes) — normal.

Diagnostics tip: detection logs one info line per plug/unplug
(`CS42L83 headphone plugged in/unplugged`); raw `DET_STATUS1` is at `codec_dbg`
(enable with `echo "module snd_hda_codec_cs8409 +p" > \
/sys/kernel/debug/dynamic_debug/control`). HDA `reconfig` is blocked while
PipeWire holds the device; iterate with reboots (do NOT stop PipeWire over SSH —
it tears down the user session and drops the connection).

## Other not-done items (lower priority)

- Headset mic (external mic in jack, 0x3c → CS42L83 ADC + ASP2-RX). Internal
  mic is done; headset mic would mirror the HP output power-up (egorenar
  `set_power_state_on` instate=true: PWR_CTL1 0xfe→0x7e→0x7a).
- Speaker amps are now gated off when a headphone is plugged in (1.19). They
  are still on whenever no headphone is present (even with nothing playing);
  could additionally gate on stream-active for power saving.
- Speaker volume calibration; suspend/resume hardening.
