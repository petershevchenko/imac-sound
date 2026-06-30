# snd-hda-codec-cs8409-imac

DKMS package adding Apple **iMac18,3** (2017 27" 5K) audio support to the
in-kernel Cirrus Logic **CS8409** HDA codec driver (kernel 7.0 / Ubuntu 26.04).

The CS8409 is an HDA→I2C bridge. On the iMac it drives a **CS42L83** companion
DAC (headphone + headset mic) and four **TAS5764** amplifiers (internal
speakers), none of which the stock in-tree driver supports — upstream only
covers Dell laptops (CS42L42). This package adds the Apple quirk and the full
bring-up.

## What works

| Feature | Notes |
|---------|-------|
| 🎧 **Headphone output** | CS42L83 on ASP2, 44.1 kHz. |
| 🎙️ **Headset / jack microphone** | TRRS inline mic; works alongside the internal mic, survives unplug/replug. |
| 🎤 **Internal microphone** | DMIC2 (pin 0x45 → ADC 0x23). |
| 🔊 **Internal speakers** | Stereo, via 4× TAS5764 amps on ASP1 4-channel TDM. |
| 🔀 **Auto-mute** | Plug a headphone → internal speakers mute and the headphone plays; unplug → speakers return. |
| 💤 **Suspend/resume** | Audio comes back after resume. |

PCM is fixed at 44.1 kHz (PipeWire resamples transparently — see the bottom of
this file for why).

---

## Is my Mac compatible?

This package is **only** for the Apple **iMac18,3** (2017 27" 5K). To check, run:

```sh
./tools/check-compatible.sh
```

It reads your Mac model and audio codec and prints `COMPATIBLE` or not. (It only
reads; it changes nothing.)

## How to install

These steps assume **Ubuntu 26.04** (or similar) on the iMac18,3. Open the
**Terminal** app and copy-paste each command (press Enter after each). Lines
starting with `sudo` will ask for your password.

**1. Install the tools needed to build the driver:**

```sh
sudo apt update
sudo apt install -y dkms build-essential devscripts debhelper dh-dkms \
                    linux-headers-$(uname -r)
```

**2. Get this project** (skip if you already have the folder), and enter it:

```sh
git clone https://github.com/<your-fork>/snd-hda-codec-cs8409-imac.git
cd snd-hda-codec-cs8409-imac
```

**3. Check your Mac is supported:**

```sh
./tools/check-compatible.sh
```

If it does **not** say `COMPATIBLE`, stop here — this package won't help your
machine.

**4. Build the installer package:**

```sh
dpkg-buildpackage -us -uc -b
```

This produces a `.deb` file one level up (in the parent folder).

**5. Install it:**

```sh
sudo dpkg -i ../snd-hda-codec-cs8409-imac-dkms_*_all.deb
```

DKMS automatically compiles the driver for your kernel and installs it. It will
also rebuild itself automatically whenever Ubuntu updates the kernel.

**6. Restart the computer:**

```sh
sudo reboot
```

**7. Check it worked:** after logging back in, open **Settings → Sound**. You
should see working **Output** (Speakers / Headphones) and **Input**
(Microphone). Play something and speak into a mic to confirm.

That's it. To **uninstall** later: `sudo apt remove snd-hda-codec-cs8409-imac-dkms`.

## Troubleshooting

**No sound at all after installing.**
First reboot once if you haven't. Then check the driver built and loaded:

```sh
dkms status | grep cs8409          # should say "installed" for your kernel
lsmod | grep cs8409                # should list snd_hda_codec_cs8409
./tools/audio-state.sh             # shows devices, volumes, what's selected
```

If `dkms status` is empty or shows an error, reinstall the `.deb` (step 5) and
watch for build errors. Make sure `linux-headers-$(uname -r)` is installed.

**Sound broke after a Ubuntu / kernel update.**
DKMS should rebuild automatically, but you can force it:

```sh
sudo dkms autoinstall
sudo reboot
```

**The microphone records but is too quiet.**
Open **Settings → Sound → Input** and raise the **Input Volume**. The headset
mic and internal mic have independent levels. (The headset mic already gets a
+20 dB hardware boost in the driver; the slider adds more on top.)

**It says my Mac isn't compatible.**
`./tools/check-compatible.sh` only matches the iMac18,3. If you have a different
Apple model with a CS8409 codec it may be close but is **not** supported by this
package as-is.

**Audio detected as `auto_null` / nothing selectable.**
Auto-detection didn't pick the Apple quirk. Force the model:

```sh
echo 'options snd-hda-intel model=imac18-3' | sudo tee /etc/modprobe.d/cs8409-imac.conf
sudo reboot
```

**Collecting info for a bug report.** Run these and include the output:

```sh
./tools/audio-state.sh
sudo dmesg | grep -i cs8409
# verbose codec register trace (optional):
echo 'module snd_hda_codec_cs8409 +p' | sudo tee /sys/kernel/debug/dynamic_debug/control
```

---

## How it works

- `SND_PCI_QUIRK` / model `imac18-3` for codec subsystem `0x106b1000`.
- **Headphone**: CS42L83 multi-page I2C bring-up + CS8409 ASP2 TDM at 44.1 kHz.
  The companion-DAC bring-up and HP output-stage power-up run in the *playback*
  hook (the PLL only locks with live clocks).
- **Headset / jack mic**: pin 0x3c → CS42L83 analog ADC → ASP2 (receive) →
  CS8409 ADC node 0x1a. Capture runs in the parser's `dyn_adc_switch` mode, so
  the path is identified by the selected input-mux pin (0x3c), and brought up at
  capture time (PCM PREPARE *and* `cap_sync_hook`, since the ASP2 clock is gated
  when idle and PipeWire skips PREPARE on a replug). Needs HSBIAS mic bias, a
  +20 dB ADC boost, both PWR_CTL1 sides powered (so the output SRC locks), and a
  per-capture ASP2-RX re-arm. See `TODO.md` for the full write-up.
- **Internal mic**: DMIC2 clock (PAD_CFG bit 0x0002) left permanently enabled.
- **Speakers**: re-enables the ASP1 speaker pins, programs the four TAS5764 amps
  over I2C (0xd8/0xda/0xdc/0xde = L-tweeter/L-woofer/R-tweeter/R-woofer, TDM
  channel map 0/2/1/3), sets up the CS8409 ASP1 4-channel TDM path, and enables
  the amp rail on GPIO4.
- **Auto-mute**: the board wires no jack interrupt, so a 500 ms tip-sense poll
  drives the speaker-amp GPIO (off when a headphone is in).
- GPIO: GPIO0 = CS42L83 IRQ, GPIO1 = CS42L83 reset, GPIO4 = speaker-amp enable.

It builds **only** the single `snd-hda-codec-cs8409.ko` and installs it into
`updates/dkms/`, overriding the stock in-tree module. The private HDA headers it
needs are bundled under `common/` and `codecs/`, so the only build dependency is
the matching `linux-headers` package.

## Layout

```
Kbuild                              out-of-tree build rules
dkms.conf                           DKMS module definition
codecs/cirrus/cs8409.c              patched codec (Apple fixups, hooks, amp/HP/mic setup)
codecs/cirrus/cs8409.h              patched header (Apple defines/enums/externs)
codecs/cirrus/cs8409-tables.c       patched tables (verbs, CS42L83 I2C seq, quirk, pincfgs)
codecs/, common/                    bundled private HDA headers (compile-only)
debian/                             dh-dkms packaging
tools/audio-state.sh                read-only audio-state snapshot (debugging)
tools/check-compatible.sh           hardware compatibility check
```

## Developing (fast iteration, no packaging)

```sh
make -C /lib/modules/$(uname -r)/build M="$PWD" modules   # compile-check
make -C /lib/modules/$(uname -r)/build M="$PWD" clean      # before re-editing
```

The codec module is held by the running HDA controller, so a **reboot** is the
simplest way to activate a new build. Testing over SSH/headless: add your user
to the `audio` group (`sudo usermod -aG audio <user>`, then reboot) and
`export XDG_RUNTIME_DIR=/run/user/$(id -u)` before `pactl`/`pw-play`. Don't use
`/usr/share/sounds/alsa/Front_*.wav` for stereo tests — they're mono.

## License & credits

Licensed under the **GNU General Public License v2.0 or later**
(`SPDX-License-Identifier: GPL-2.0-or-later`), matching the in-kernel driver this
derives from. Full text in [`LICENSE`](LICENSE); each source file carries an SPDX
header.

- Based on the mainline Linux **Cirrus Logic CS8409** HDA codec driver
  (Copyright © 2021 Cirrus Logic, Inc.).
- The CS42L83 / TAS5764 register sequences were reverse-engineered from the macOS
  AppleHDA driver via the out-of-tree
  [`egorenar/snd-hda-codec-cs8409`](https://github.com/egorenar/snd-hda-codec-cs8409)
  project (also GPL-2.0), and ported onto the kernel 7.0 in-tree driver's
  fixup/hook architecture.
