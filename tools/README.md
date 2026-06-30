# tools

Helper scripts for the iMac CS8409/CS42L83 driver. All are read-only.

## check-compatible.sh

Checks whether this machine is supported by the package — the Mac model (must be
`iMac18,3`) and the audio codec (Cirrus `CS8409` with subsystem id `0x106b1000`).
Prints a clear `COMPATIBLE` / not-a-match verdict and exits 0 / 1 accordingly.

```sh
./check-compatible.sh
```

The rest are general-purpose ALSA/PipeWire helpers, not specific to this codec:

## audio-state.sh

A read-only snapshot of the machine's audio setup — which devices exist, which
are selected/active, and what state each is in. It combines the **PipeWire**
view (`pactl`) with the raw **ALSA/HDA** view (`/proc/asound` + `amixer`), so you
can see both "what userspace thinks" and "what the hardware is actually doing"
side by side. Nothing is changed; it only reads.

### Usage

```sh
./audio-state.sh            # snapshot of card 0
./audio-state.sh -c 1       # use a different ALSA card for the HDA detail
./audio-state.sh -r         # also dump the full raw HDA codec proc (verbose)
```

Requires `pactl` and `amixer` (both standard on a PipeWire + alsa-utils system);
falls back gracefully if a tool is missing. Run as the desktop user so it can
reach the PipeWire socket (it sets `XDG_RUNTIME_DIR` automatically).

### What each section shows

| Section | Source | What to look for |
|---|---|---|
| **Sound cards** | `/proc/asound/cards` | the cards present and their drivers |
| **PipeWire defaults** | `pactl get-default-*` | the current default output/input |
| **Outputs / Inputs** | `pactl list sinks/sources` | per device: state, mute, volume, **active port**, and every port with its **availability** (how plug/unplug shows up) |
| **Active streams** | `pactl list sink-inputs/source-outputs` | which apps are playing/capturing and on which device |
| **HDA jack sense** | `amixer contents` | real jack-detect state (e.g. `Headphone Jack`, `Mic Jack` = on/off) |
| **Active converters** | `/proc/asound/card*/codec#*` | which DAC/ADC nodes have a live stream (`stream=N`) — i.e. what the hardware is really routing |
| **Mixer controls** | `amixer` | volumes/switches with dB and on/off |

### Why it's handy

It answers the questions that come up constantly when chasing audio bugs:
is the right device selected, is something muted or at zero, is a jack actually
detected, and is the capture/playback stream bound to the converter you expect?
For example, a capture that's silent because the input mux is pointing at the
wrong (or powered-down) ADC shows up immediately as the wrong node under
"active converters".
