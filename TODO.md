# Handoff / TODO — snd-hda-codec-cs8409-imac

Last updated end of the session that got headphone + internal mic + stereo
speakers working. **Installed & working version: 1.14** (git HEAD).

## Current state (all in git, ~15 commits)

| Feature | Status |
|---|---|
| 🎧 Headphone output (CS42L83 / ASP2, 44.1 kHz) | WORKS |
| 🎤 Internal mic (DMIC2, pin 0x45 → ADC 0x23) | WORKS |
| 🔊 Internal speakers (4× TAS5764 on ASP1 4-ch TDM) | WORKS — stereo correct (4.1/2.1/stereo all good) |
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

## THE OPEN BUG — headphone & speakers are not mutually exclusive

**Symptom:** selecting the **Headphones** port in GNOME still plays the
**internal speakers** (the jack and the speakers are not isolated).

**Root cause (confirmed by diagnostics):** with the Headphones port active and
audio playing, ALL output DACs stream — `0x02`+`0x03` (speakers) AND `0x0a`
(headphone) all show `stream=1`, and pins `0x24`/`0x25`/`0x2c` are all OUT
(0x40). The single analog PCM is fed to every output at once, and the speaker
amps are always-on, so the internal speakers play regardless of the selected
port. Port "selection" in PipeWire is cosmetic at the HDA level here.

**Why we're in this state:** to fix an earlier PipeWire "Dummy Output" problem
(when headphone was the ONLY output), we:
  1. made the HP a **phantom / no-presence jack** —
     `snd_hda_codec_set_pincfg(codec, 0x2c, 0x002b4120)` (NO_PRESENCE bit) in
     `cs8409_cs42l83_fixups()` PRE_PROBE;
  2. force `hp_jack_in = 1` (in the fixup and in
     `cs8409_cs42l83_jack_unsol_event()`);
  3. set `spec->gen.suppress_auto_mute = 1` and `no_primary_hp = 1`.
That was correct for a single output, but with speakers added there is now
nothing telling the driver "HP in use → mute internal speakers."

## THE FIX — real jack-detection-based auto-mute

Goal: HP plugged in → internal speakers auto-mute (and HP plays); HP unplugged
→ internal speakers play. This is the standard HDA auto-mute, which we bypassed.

Plan:
1. **Fix the inverted jack detection.** The iMac uses an INVERTED tip-sense
   circuit (init_seq writes `0x1b73 = 0xe0`, vs `0xc0` non-inverted — see
   `cs42l83_init_reg_seq` in `cs8409-tables.c` and egorenar
   `cs42l83_tip_sense(codec, invert=1)`). The reused
   `cs42l42_jack_unsol_event()` / `cs42l42_run_jack_detect()` mis-read it (HP
   reported unplugged when plugged), which is why we went phantom. Get
   `cs42l83->hp_jack_in` to reflect reality: read TSRS_PLUG_STATUS (0x130F) /
   the 0x1B detect regs and invert the interpretation as needed. Verify with
   the user plugging/unplugging while watching `amixer -c 0 contents | grep -A3
   "Headphone Jack"` (run as root).
2. **Remove the phantom/forced-present hacks:** restore HP pincfg to
   `0x002b4020` (drop the `0x002b4120` NO_PRESENCE override), drop the
   `hp_jack_in = 1` forces in the fixup and the unsol handler (let the unsol
   handler report the real detected state).
3. **Enable auto-mute:** drop `suppress_auto_mute = 1` (and reconsider
   `no_primary_hp`) so the generic parser mutes the speaker pins/DACs when the
   HP jack is present. Confirm the speaker amps stop driving when HP is in (the
   parser should disable pins 0x24/0x25; if the always-on amps still hum,
   gate them on the speaker pin's OUT state or mute amp reg 0x01).
4. **Re-verify the original "Dummy Output" problem does NOT return.** That was
   the whole reason for the phantom. With working detection: HP unplugged →
   speaker (internal, always-present) port keeps a real sink; HP plugged → HP
   port available. Neither should fall back to `auto_null`. Test both states.

Key code locations (all in `codecs/cirrus/cs8409.c`):
- `cs8409_cs42l83_fixups()` — PRE_PROBE sets the phantom pincfg, GPIO
  (gpio_mask 0x1f), `hp_jack_in = 1`, `suppress_auto_mute`, `no_primary_hp`;
  PROBE sets the playback/capture hooks and names.
- `cs8409_cs42l83_jack_unsol_event()` — currently forces `hp_jack_in = 1`.
- `cs8409_cs42l83_hw_init()` — ASP2 (HP) + `cs42l42_resume()` +
  `cs8409_cs42l83_speaker_setup()` (amps, always-on at init).
- `cs8409_cs42l83_speaker_setup()` — amp programming + ASP1 TDM; amp channel
  map `{0,2,1,3}` (physical: 0xd8=L-tweet, 0xda=L-woof, 0xdc=R-tweet,
  0xde=R-woof).

## Open item to clarify with the user (asked, not yet answered)

When Headphones is selected, does the jack output audio AT ALL (alongside the
internal speakers), or ONLY internal speakers? `0x0a` streams, so the jack
*should* work — confirm whether the jack output itself is fine and it's purely
"speakers not muted," or if the jack is also dead (would point at an ASP1/ASP2
or CS42L83 resource conflict when both stream).

## Other not-done items (lower priority)

- Headset mic (external mic in jack, 0x3c → CS42L83 ADC + ASP2-RX). Internal
  mic is done; headset mic would mirror the HP output power-up (egorenar
  `set_power_state_on` instate=true: PWR_CTL1 0xfe→0x7e→0x7a).
- Speaker amps are always-on at init (Phase 1). Could gate on speaker-port
  active for power/cleanliness once auto-mute exists.
- Speaker volume calibration; suspend/resume hardening.
