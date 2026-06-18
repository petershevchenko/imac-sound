# snd-hda-codec-cs8409-imac

DKMS package adding Apple **iMac18,3** (2017 27" 5K) audio support to the
in-kernel Cirrus Logic **CS8409** HDA codec driver (kernel 7.0).

The CS8409 is an HDA→I2C bridge to a **CS42L83** companion DAC on the headphone
path. The stock in-tree driver only supports Dell (CS42L42). This package adds:

- `SND_PCI_QUIRK` / model `imac18-3` for codec subsystem `0x106b1000`
- CS42L83 44.1kHz multi-page I2C bring-up sequence
- CS8409 **ASP2** headphone TDM path with 44.1kHz clocking
- GPIO mapping: GPIO1 = CS42L83 reset, GPIO0 = IRQ, GPIO4 = external amp enable

It builds **only** the single `snd-hda-codec-cs8409.ko` and installs it into
`updates/dkms/`, overriding the stock in-tree module. The 5 private HDA headers
it needs are bundled under `common/` and `codecs/`, so the only build
dependency is the matching `linux-headers` package.

## Layout

```
Kbuild                              out-of-tree build rules
dkms.conf                           DKMS module definition
codecs/cirrus/cs8409.c              patched codec (Apple fixup + hw_init)
codecs/cirrus/cs8409.h              patched header (Apple defines/enums/externs)
codecs/cirrus/cs8409-tables.c       patched tables (verbs, I2C seq, hw_cfg, quirk)
codecs/generic.h                    bundled private header (compile-only)
codecs/side-codecs/hda_component.h  bundled private header (compile-only)
common/hda_local.h                  bundled private header (compile-only)
common/hda_auto_parser.h            bundled private header (compile-only)
common/hda_jack.h                   bundled private header (compile-only)
debian/                             dh-dkms packaging
```

## Fast iteration loop (no packaging)

```sh
make -C /lib/modules/$(uname -r)/build M="$PWD" modules
sudo cp snd-hda-codec-cs8409.ko \
    /lib/modules/$(uname -r)/updates/dkms/
sudo depmod -a
# reload (see "Loading" below), then test audio
make -C /lib/modules/$(uname -r)/build M="$PWD" clean   # before re-editing
```

## Build the DKMS .deb

```sh
dpkg-buildpackage -us -uc -b
# -> ../snd-hda-codec-cs8409-imac-dkms_1.0_all.deb
```

## Install

```sh
sudo dpkg -i ../snd-hda-codec-cs8409-imac-dkms_1.0_all.deb   # dkms build+install
```

## Loading without a reboot

The codec module is held by the running HDA controller, so to pick up the new
build you must detach and re-probe the codec (or just reboot):

```sh
sudo modprobe -r snd_hda_codec_cs8409
sudo modprobe snd_hda_codec_cs8409
# if the controller doesn't re-probe, reload it too:
sudo modprobe -r snd_hda_intel && sudo modprobe snd_hda_intel
```

## Verify

```sh
dmesg | grep -i cs8409                 # expect CS8409/CS42L83
aplay -l | grep -i cs42l83             # expect a CS8409/CS42L83 Analog device
cat /proc/asound/card0/codec#0 | head  # check codec name / pins
```

If auto-detection doesn't trigger, force it: add
`options snd-hda-intel model=imac18-3` (for the relevant card) or boot with the
`model` quirk, then reload.

## Status / tuning notes

First functional cut. The least-certain values (most likely to need tuning on
hardware) are the **ASP2 44.1kHz clock divisors** in
`cs8409_cs42l83_hw_init()` / `cs8409_cs42l83_hw_cfg[]`. Internal speakers need a
separate amplifier driver and are intentionally out of scope here (headphone
path first).
