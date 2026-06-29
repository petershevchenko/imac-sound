# Handoff / TODO — snd-hda-codec-cs8409-imac

**Working version: 1.33.** Output, internal mic, speakers, HP↔speaker auto-mute,
AND the headset/jack mic all work, including across unplug/replug cycles.

**Headset mic: DONE in 1.33** (verified: boot, unplug→internal, replug→headset;
normal speech ~-25 dBFS). See "HEADSET MIC — SOLVED" below for the (many)
non-obvious keys; the short version:
- Capture runs in the parser's **dyn_adc_switch** mode, so `hinfo->nid` is always
  the nominal `adc_nids[0]` (0x12); the headset is identified by the selected
  input-mux pin (0x3c → ADC 0x1a). pin 0x22 is line-in, not the mic.
- The bring-up must run **at capture time** (the ASP2 clock is gated when idle).
  Triggered from the capture **PREPARE** hook (boot/fresh) AND **cap_sync_hook**
  (input switch on replug, where PipeWire issues no PREPARE). jack detect only
  tears the path down on unplug.
- Re-arm the **CS8409 ASP2-RX** slots every capture (RX loses sync when the
  CS42L83 stops transmitting). Power **both** PWR_CTL1 sides to 0x12 (the output
  SRC/OASRC only locks with the mixer/ASP-in powered). Electret needs **HSBIAS**
  (MISC_DET_CTL 0x1b74 = 0x07). Level needs the **+20 dB ADC boost** (ADC_CTL
  0x1d01 bit0); there is no analog PGA.
- Internal DMIC clock is left **permanently on** (hw_init), since the capture
  hook isn't reliably called on input switches.

## Current state

| Feature | Status |
|---|---|
| 🎧 Headphone output (CS42L83 / ASP2, 44.1 kHz) | WORKS |
| 🎤 Internal mic (DMIC2, pin 0x45 → ADC 0x23) | WORKS |
| 🎙️ Headset/jack mic (pin 0x3c → CS42L83 ADC → ASP2 → ADC 0x1a) | WORKS (1.33; survives unplug/replug) |
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

## HEADSET MIC — SOLVED (1.24); section below is the implementation record

**Done.** A TRRS headset's inline mic works as an additive capture source. The
two things the original plan got wrong (and how 1.24 fixed them):
- **ADC node:** the plan assumed pin 0x3c → ADC 0x22. Live topology: 0x3c → ADC
  **0x1a** (0x22 is the line-in). More importantly, capture is **dyn_adc_switch**,
  so the hook's `hinfo->nid` is always `adc_nids[0]`=0x12 — dispatch on the
  selected input-mux pin (`spec->gen.cur_mux[0]` → `imux_pins[]` == 0x3c), not the
  nid. (`cs42l83_capture_pcm_hook`.)
- **Mic bias:** the bring-up sequence below is necessary but not sufficient — the
  electret needs **HSBIAS** (MISC_DET_CTL `0x1b74` = 0x07, with a HSDET_CTL2
  `0x1120` handshake), enabled on capture / dropped to HiZ on stop. Without it the
  mic was ~40 dB too quiet. (`cs8409_cs42l83_headset_mic_enable`.)

The signal-flow / register details that follow are accurate and were the basis of
the working code.

**Original goal:** when a TRRS headset (headphones + inline mic) is plugged into
the jack, its microphone works as a capture source. Internal mic (DMIC2) already
works and must keep working; this is an *additive* second input path.

### Signal flow (what the hardware does)
```
headset mic  ->  CS42L83 analog ADC  ->  CS42L83 ASP TX
             ->  CS8409 ASP2 RX (pin 0x3c)  ->  CS8409 ADC node 0x22  ->  host
```
ASP2 is **shared/duplex**: the headphone DAC uses ASP2 in the TX direction
(CS8409 -> CS42L83), the mic uses ASP2 in the RX direction (CS42L83 -> CS8409),
on the **same 44.1 kHz frame/bit clock**. The HP TX clocking is already set up
in `cs8409_cs42l83_hw_init()`; the mic work must add the RX direction *without*
disturbing that clock or the internal DMIC.

### What already exists (free — do NOT redo)
- HDA topology + userspace controls are already created by the parser:
  - pin **0x3c** = `CS8409_CS42L83_AMIC_PIN_NID` (= `ASP2_RECEIVER_A`), cfg
    `0x00ab9030`, pin-ctl `0x20: IN`, feeding **ADC node 0x22**.
  - amixer already shows a separate **`Mic`** capture control (0x22) next to
    **`Internal Mic`** (0x45 -> ADC 0x23). GNOME will show it as soon as the
    path carries audio. ADC 0x22 currently sits at **D3** (powered down) = silent.
  - `cs8409_cs42l42_exec_verb` already reports `mic_jack_in` for pin 0x3c under
    `CS8409_IMAC18_3` (made machine-aware in v1.20).
  - "Mic Capture Volume" kctl (`cs42l42_adc_volume_mixer`) is already added in
    the PROBE fixup.

### What's missing (the actual work, all in `codecs/cirrus/cs8409.c` + tables)
1. **CS8409 ASP2 RX path.** `cs8409_cs42l83_hw_init()` only programs ASP2 TX
   (coefs `ASP2_Tx_RATE1`, `ASP2_A_TX_CTRL1/2`, etc.). Add the RX equivalents —
   the enum already defines them: `ASP2_Rx_RATE1/2`, `ASP2_Rx_NULL_INS_RMV`,
   `ASP2_A_RX_CTRL1/2`, plus the ASP2 RX clock bits. Mirror the TX sequence for
   the receive slots (channels 1+2, 44.1 kHz). Reuse the existing ASP2 clock; do
   not re-init it in a way that breaks HP.
2. **CS42L83 ADC bring-up** (in `cs42l83_init_reg_seq`, `cs8409-tables.c`, and/or
   the capture hook). Power the ADC and enable its ASP TX:
   - PWR_CTL1 (0x1101): the HP path walks it for the DAC; the ADC needs its own
     power bits. egorenar note: `set_power_state_on(instate=true)` walks
     `PWR_CTL1 0xfe -> 0x7e -> 0x7a`. Confirm which bits are ADC vs HP.
   - Enable the CS42L83 ASP **TX** (page 0x2a registers; the init seq already
     sets RX-side `0x2a01=0x0c` for the DAC — find/add the TX-enable + slot regs
     for the ADC).
   - ADC page 0x23xx is configured a little (`0x2302=0x3f`); verify full ADC
     setup (digital vol/unmute, HPF, etc.).
3. **Mic bias (HSBIAS).** Currently `hsbias_hiz = 0x0000` (off). Electret headset
   mics need bias. `cs42l42_enable_jack_detect()` writes `HSBIAS_SC_AUTOCTL =
   hsbias_hiz`; set an appropriate HSBIAS value (compare the Dell path which uses
   0x0020) and/or drive HSBIAS via `MISC_DET_CTL`.
4. **Capture hook.** `cs42l83_capture_pcm_hook()` today only toggles the DMIC2
   clock (`PAD_CFG` bit 0x0002) for the internal mic. For the headset mic, power
   up the CS42L83 ADC + ASP2-RX when capturing (either always-on at init, or —
   cleaner — gate it when the `Mic` (0x22) source is the active capture).
5. **Detection (optional, for correctness).** The jack poll currently forces
   `mic_jack_in = 0` and only reads tip-sense (no CTIA/OMTP type detection — we
   deliberately bypassed it). Options:
   - First cut: set `mic_jack_in = hp_jack_in` (assume any plug may be a headset;
     the mic is just silent for plain headphones). Simple, good enough to test.
   - Proper: re-introduce headset-type detection (see `cs42l42_manual_hs_det()` /
     the HSDET auto path) to set `mic_jack_in` only for true CTIA/OMTP headsets.

### Strong recommendation: check egorenar's reference FIRST
The HP-output and speaker sequences were ported from egorenar's iMac CS8409
driver (macOS `AppleHDATDM_CS42L83` reverse-engineering). **Before reverse-
engineering the ADC path from scratch, get that driver and see if it already
implements the headset-mic capture path** — if so this becomes a port + tune
(small) instead of fresh RE (multi-iteration). The HP code comments in
`cs8409_cs42l83_hw_init()` cite the macOS `setupTDMPath(full=1)` sequence;
the mic path is the matching receive/ADC sequence.

### How to test (output is easy to hear; capture needs method)
- Hardware: a TRRS headset with an inline mic. `export XDG_RUNTIME_DIR=/run/user/1000`.
- Record + inspect level:
  `pw-record --target <Mic-source> /tmp/m.wav` (or `arecord -D ...`), tap the
  mic / talk, Ctrl-C, then `pw-play /tmp/m.wav` to the internal speakers, or
  check the captured peak with `sox /tmp/m.wav -n stat` (look for nonzero RMS).
- Confirm ADC 0x22 leaves D3: `cat /proc/asound/card0/codec#0` -> Node 0x22
  should show `Power: setting=D0` and `Converter: stream=1` while recording.
- Iterate with reboots (HDA `reconfig` is blocked by PipeWire; do NOT stop
  PipeWire over SSH — it drops the session). Use `codec_dbg` + dynamic debug for
  CS42L83 register traces.

### Risk / gotchas
- **Don't break HP or internal mic** — ASP2 is shared with HP (clock) and the
  DMIC shares the `PAD_CFG` coef. Test all three after each change.
- Duplex ASP2: the CS42L83 must run ADC + DAC on one ASP simultaneously; getting
  the RX slot/clock wrong likely yields silence or kills HP. This is the main
  technical risk, analogous to how wrong TX clock bits gave HP silence.
- Verify mic-bias doesn't introduce hum/pops on the HP output.

### Key code locations
- `cs8409_cs42l83_hw_init()` — add ASP2 RX setup here (next to the ASP2 TX block).
- `cs42l83_init_reg_seq` (`cs8409-tables.c`) — CS42L83 ADC power / ASP-TX enable /
  HSBIAS bring-up lines.
- `cs42l83_capture_pcm_hook()` — power/gate the headset-mic path on capture.
- `cs8409_cs42l83_jack_detect()` — set `mic_jack_in` (first cut: = hp_jack_in).
- `cs8409_cs42l83_codec` (`cs8409-tables.c`) — `hsbias_hiz`, `no_type_dect` if
  re-enabling type detection.

## Other not-done items (lower priority)

- Speaker amps are now gated off when a headphone is plugged in (1.19). They
  are still on whenever no headphone is present (even with nothing playing);
  could additionally gate on stream-active for power saving.
- Speaker volume calibration; suspend/resume hardening.
