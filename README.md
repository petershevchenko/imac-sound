# snd-hda-codec-cs8409-imac

DKMS package adding Apple **iMac18,3** (2017 27" 5K) audio support to the
in-kernel Cirrus Logic **CS8409** HDA codec driver (kernel 7.0 / Ubuntu 26.04).

The CS8409 is an HDA→I2C bridge. On the iMac it drives a **CS42L83** companion
DAC (headphone) and four **TAS5764** amplifiers (internal speakers), none of
which the stock in-tree driver supports — upstream only covers Dell laptops
(CS42L42). This package adds the Apple quirk and the full bring-up.

## What works

| Feature | Notes |
|---------|-------|
| 🎧 **Headphone output** | CS42L83 on ASP2, 44.1 kHz. Automatic default sink. |
| 🎤 **Internal microphone** | DMIC2 (pin 0x45 → ADC 0x23), enabled during capture. |
| 🔊 **Internal speakers** | Stereo, via 4× TAS5764 amps on ASP1 4-channel TDM. |

Outputs are exposed as **manually selectable** ports — pick *Headphones* or
*Speakers* in GNOME Sound settings (no automatic plug/unplug switching).

**Not (yet) implemented:** headset mic (external mic in the jack), automatic
headphone/speaker switching, suspend/resume hardening. PCM is fixed at 44.1 kHz
(PipeWire resamples transparently).

## How it works

- `SND_PCI_QUIRK` / model `imac18-3` for codec subsystem `0x106b1000`.
- **Headphone**: CS42L83 multi-page I2C bring-up + CS8409 ASP2 TDM at 44.1 kHz.
  The companion-DAC bring-up and HP output-stage power-up run in the *playback*
  hook (the PLL only locks with live clocks); the HP jack is reported as a
  no-presence/phantom jack so the desktop keeps a usable sink.
- **Internal mic**: sets DMIC2_SCL_EN (PAD_CFG bit 0x0002) while capturing.
- **Speakers**: re-enables the ASP1 speaker pins, programs the four TAS5764
  amps over I2C (addresses 0xd8/0xda/0xdc/0xde = L-tweeter/L-woofer/R-tweeter/
  R-woofer, TDM channel map 0/2/1/3 so L drives both left speakers and R both
  right), sets up the CS8409 ASP1 4-channel TDM path,
  and enables the amp rail on GPIO4.
- GPIO: GPIO0 = CS42L83 IRQ, GPIO1 = CS42L83 reset, GPIO4 = speaker-amp enable.

It builds **only** the single `snd-hda-codec-cs8409.ko` and installs it into
`updates/dkms/`, overriding the stock in-tree module. The 5 private HDA headers
it needs are bundled under `common/` and `codecs/`, so the only build
dependency is the matching `linux-headers` package.

## Layout

```
Kbuild                              out-of-tree build rules
dkms.conf                           DKMS module definition
codecs/cirrus/cs8409.c              patched codec (Apple fixups, hooks, amp/HP/mic setup)
codecs/cirrus/cs8409.h              patched header (Apple defines/enums/externs)
codecs/cirrus/cs8409-tables.c       patched tables (verbs, CS42L83 I2C seq, quirk, pincfgs)
codecs/generic.h                    bundled private header (compile-only)
codecs/side-codecs/hda_component.h  bundled private header (compile-only)
common/hda_local.h                  bundled private header (compile-only)
common/hda_auto_parser.h            bundled private header (compile-only)
common/hda_jack.h                   bundled private header (compile-only)
debian/                             dh-dkms packaging
```

## Build & install the DKMS .deb

```sh
dpkg-buildpackage -us -uc -b
sudo dpkg -i ../snd-hda-codec-cs8409-imac-dkms_*_all.deb   # dkms build+install
sudo reboot                                                # cleanest activation
```

The codec module is held by the running HDA controller, so a reboot is the
simplest way to activate a new build. (For dev you can `modprobe -r
snd_hda_codec_cs8409` then `insmod` the freshly built `.ko`, but the controller
usually won't release it while audio clients are active.)

## Fast iteration loop (no packaging)

```sh
make -C /lib/modules/$(uname -r)/build M="$PWD" modules
# ... copy/insmod and test ...
make -C /lib/modules/$(uname -r)/build M="$PWD" clean      # before re-editing
```

## Verify

```sh
dmesg | grep -i cs8409                 # expect "CS8409/CS42L83", picked fixup 106b:1000
pactl list sinks short                 # expect alsa_output...analog-stereo (not auto_null)
```

If auto-detection doesn't trigger, force it with `options snd-hda-intel
model=imac18-3`.

### Notes for testing over SSH / headless

- `/dev/snd/*` is `root:audio` with an ACL for the *active seat* user only.
  Over SSH with no GNOME login, PipeWire (as your user) sees no cards. Add your
  user to the `audio` group (`sudo usermod -aG audio <user>`, then reboot) for
  device access, and `export XDG_RUNTIME_DIR=/run/user/$(id -u)` before
  `pactl`/`pw-play`.
- To test **stereo separation**, do NOT use `/usr/share/sounds/alsa/Front_*.wav`
  — they are mono and PipeWire duplicates them to both channels (always sounds
  centered). Use a true one-sided stereo signal or GNOME → Sound → Test.

## Reference

Register sequences were reverse-engineered from the macOS AppleHDA driver via
the out-of-tree `egorenar/snd-hda-codec-cs8409` project, ported onto the
kernel 7.0 in-tree CS8409 driver's fixup/hook architecture.
