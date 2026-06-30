#!/usr/bin/env bash
# check-compatible.sh — is this machine supported by snd-hda-codec-cs8409-imac?
#
# Read-only. Checks the Mac model (DMI) and the audio codec (CS8409 + the
# iMac18,3 subsystem id 0x106b1000). Prints a clear COMPATIBLE / not-a-match
# verdict. Safe to run on any machine.
set -u
if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; Z=$'\033[0m'
else G=""; R=""; B=""; Z=""; fi
ok(){ printf '  %s✓%s %s\n' "$G" "$Z" "$1"; }
no(){ printf '  %s✗%s %s\n' "$R" "$Z" "$1"; }
inf(){ printf '      %s\n' "$1"; }

model=$(cat /sys/class/dmi/id/product_name 2>/dev/null)
vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)
printf '%sMachine:%s %s %s\n\n' "$B" "$Z" "${vendor:-?}" "${model:-?}"

pass=1

# 1) Mac model
if [ "$model" = "iMac18,3" ]; then
	ok "Mac model is iMac18,3 (2017 27\" 5K) — supported"
else
	no "Mac model is '${model:-unknown}', not iMac18,3"
	inf "This package targets the Apple iMac18,3 only."
	pass=0
fi

# 2) CS8409 audio codec + subsystem id
found=0
for c in /proc/asound/card*/codec#*; do
	[ -e "$c" ] || continue
	grep -qi "CS8409" "$c" || continue
	found=1
	sub=$(awk '/Subsystem Id:/{print $NF; exit}' "$c")
	if [ "$sub" = "0x106b1000" ]; then
		ok "Cirrus CS8409 codec present, subsystem $sub (iMac18,3)"
	else
		no "CS8409 codec found but subsystem is ${sub:-?} (expected 0x106b1000)"
		pass=0
	fi
done
if [ "$found" = 0 ]; then
	no "No Cirrus CS8409 audio codec found in /proc/asound"
	inf "Either this isn't the right hardware, or no sound card is present."
	pass=0
fi

echo
if [ "$pass" = 1 ]; then
	printf '%sRESULT: COMPATIBLE%s — this package should work on this machine.\n' "$G" "$Z"
	exit 0
else
	printf '%sRESULT: NOT A MATCH%s — this package is for the Apple iMac18,3 only.\n' "$R" "$Z"
	exit 1
fi
