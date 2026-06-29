#!/usr/bin/env bash
# audio-state.sh — read-only snapshot of the system's audio setup.
#
# Combines the PipeWire view (devices/routing/volume, via pactl/wpctl) with the
# raw ALSA/HDA view (jack sense, converter stream binding, mixer controls, via
# /proc/asound + amixer). Useful for debugging which devices exist, which are
# active/selected, and what state each is in.
#
# Usage: audio-state.sh [-c CARD] [-r]
#   -c CARD   ALSA card index for the HDA detail (default: 0)
#   -r        also dump the raw HDA codec proc (very verbose)
set -u
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

CARD=0
RAW=0
while getopts "c:r" o; do
	case $o in
		c) CARD=$OPTARG ;;
		r) RAW=1 ;;
		*) ;;
	esac
done

c_hdr=$'\033[1;36m'; c_sub=$'\033[1m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
[ -t 1 ] || { c_hdr=""; c_sub=""; c_dim=""; c_off=""; }
hdr(){ printf '\n%s════ %s ════%s\n' "$c_hdr" "$1" "$c_off"; }
sub(){ printf '%s%s%s\n' "$c_sub" "$1" "$c_off"; }
have(){ command -v "$1" >/dev/null 2>&1; }

# ───────────────────────────────────────────────────────────── cards
hdr "SOUND CARDS"
sed 's/^/  /' /proc/asound/cards 2>/dev/null

# ─────────────────────────────────────────────────── pipewire defaults
hdr "PIPEWIRE DEFAULTS"
printf '  default output: %s\n' "$(pactl get-default-sink 2>/dev/null)"
printf '  default input:  %s\n' "$(pactl get-default-source 2>/dev/null)"

# ───────────────────────────────────────── sinks/sources with ports
# Parse `pactl list {sinks,sources}` into: name / desc / state / mute / vol /
# active port / available ports.
dump_devs() {  # $1 = sinks|sources
	pactl list "$1" 2>/dev/null | awk -v dim="$c_dim" -v off="$c_off" '
	function flush() {
		if (name=="") return
		printf "  %s\n", desc
		printf "    node:   %s\n", name
		printf "    state:  %-10s  mute: %-3s  volume: %s\n", st, mute, vol
		if (aport!="") printf "    active: %s\n", aport
		if (ports!="") printf "    ports:  %s%s%s\n", dim, ports, off
		name=desc=st=mute=vol=aport=ports=""; inports=0
	}
	/^(Sink|Source) #/ { flush(); next }
	/^[ \t]+Name:/        { name=$2; next }
	/^[ \t]+Description:/ { $1=""; sub(/^ /,""); desc=$0; next }
	/^[ \t]+State:/       { st=$2; next }
	/^[ \t]+Mute:/        { mute=$2; next }
	/^[ \t]+Volume:/ && vol=="" {
		for (i=1;i<=NF;i++) if ($i ~ /%$/) { vol=$i; break }
		next
	}
	/^[ \t]+Active Port:/ { $1=$2=""; sub(/^[ \t]+/,""); aport=$0; next }
	/^[ \t]+Ports:/ { inports=1; next }
	inports==1 && /^[ \t][ \t]+[a-z]/ {
		s=$0; sub(/^[ \t]+/,"",s)
		ports = (ports=="" ? s : ports "\n            " s)
		next
	}
	inports==1 { inports=0 }
	END { flush() }'
}

hdr "OUTPUTS (sinks)"
dump_devs sinks
hdr "INPUTS (sources)"
dump_devs sources

# ─────────────────────────────────────────── active streams (who is using it)
hdr "ACTIVE STREAMS"
# label(): best-effort app/stream name from the verbose properties block.
stream_dump() {  # $1=sink-inputs|source-outputs  $2=arrow  $3=peer-label
	pactl list "$1" 2>/dev/null | awk -v arrow="$2" -v plabel="$3" '
		function val(l){ sub(/.*= "/,"",l); sub(/".*/,"",l); return l }
		function emit(){ if (peer!="")
			printf "  [%s] %s  %s %s %s\n", peer, (lbl?lbl:"?"), arrow, plabel, peer }
		/^(Sink Input|Source Output) #/ { emit(); lbl=""; peer="" }
		/^[ \t]+(Sink|Source):/        { peer=$2 }   # appears before Properties
		/application.name = /          { if (lbl=="") lbl=val($0) }
		/media.name = /                { if (lbl=="") lbl=val($0) }
		/node.name = /                 { if (lbl=="") lbl=val($0) }
		END { emit() }'
}
sub "playback:"
out=$(stream_dump sink-inputs "->" sink); [ -n "$out" ] && echo "$out" || echo "  (none)"
sub "capture:"
out=$(stream_dump source-outputs "<-" source); [ -n "$out" ] && echo "$out" || echo "  (none)"

# ─────────────────────────────────────────────── HDA jack-sense (card $CARD)
codec=$(ls /proc/asound/card$CARD/codec#* 2>/dev/null | head -1)
hdr "HDA CARD $CARD — JACK SENSE"
if have amixer; then
	# Jack kcontrols live on iface=CARD; pair each name with its value from
	# `amixer contents` (the next "  : values=" line).
	amixer -c "$CARD" contents 2>/dev/null | awk -F"'" '
		/,name=.*[Jj]ack/ { name=$2; next }
		name!="" && /: values=/ { v=$0; sub(/.*values=/,"",v);
			printf "  %-34s %s\n", name, v; name="" }'
fi

# ───────────────────────────────── HDA converters currently bound to a stream
hdr "HDA CARD $CARD — ACTIVE CONVERTERS (DAC/ADC)"
if [ -n "$codec" ]; then
	awk '
		/^Node 0x/ { nid=$2; type="" }
		/\[Audio Output\]/ { type="DAC" }
		/\[Audio Input\]/  { type="ADC" }
		/Converter: stream=/ {
			s=$0; sub(/.*stream=/,"",s); sub(/,.*/,"",s)
			if (s+0 > 0) printf "  %s %s  stream=%s\n", type, nid, s
		}' "$codec"
	echo "  ${c_dim}(only converters with a live stream are shown)${c_off}"
fi

# ────────────────────────────────────────────────── key mixer controls
hdr "HDA CARD $CARD — MIXER CONTROLS (volume / switch)"
if have amixer; then
	amixer -c "$CARD" scontrols 2>/dev/null | sed -E "s/.*'([^']+)',([0-9]+)/\1/" | sort -u | while read -r ctl; do
		line=$(amixer -c "$CARD" sget "$ctl" 2>/dev/null | awk '
			/Mono:|Front Left:|Capture |Playback /{
				if ($0 ~ /\[/) { g=$0; sub(/^[ \t]+/,"",g); print g; exit }
			}')
		[ -n "$line" ] && printf "  %-26s %s\n" "$ctl" "$line"
	done
fi

[ "$RAW" = 1 ] && [ -n "$codec" ] && { hdr "RAW HDA CODEC ($codec)"; cat "$codec"; }
echo
