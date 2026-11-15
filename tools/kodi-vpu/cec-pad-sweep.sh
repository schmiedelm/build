#!/bin/bash
# Pad-Einstellungen von HDMI_CEC gegen die CEC-Adressvergabe testen (i.MX8MP, dw-hdmi).
# Läuft AUF DEM BOARD als root, Kodi gestoppt, Fernseher bzw. Monitor an HDMI.
# Je Pad-Wert: RUNDEN-mal Adapter abmelden und als Playback anmelden. Die Anmeldung sendet
# schnelle Abfragen (Polls), wie beim Kodi-Start. Gezählt werden belegte Adressen und der
# Ausgang jedes Sendeversuchs aus dem CEC-Debug-Log. Danach steht der Ausgangswert wieder drin.
# Aufruf: cec-pad-sweep.sh [runden] [pad-wert ...]
set -u

ROUNDS="${1:-10}"
shift || true
REG=0x303304A8 # IOMUXC_SW_PAD_CTL_PAD_HDMI_CEC
DBG=/sys/module/cec/parameters/debug

# Bits: 0x100 Pull an, 0x40 Pull-up (sonst -down), 0x80 Schmitt, 0x20 Open Drain, 0x10 schnell, 0x6 Treiberstärke
if [[ $# -gt 0 ]]; then
	VALUES=("$@")
else
	VALUES=(
		0x30  # OD, schnell (alter DT-Wert)
		0xb0  # OD, schnell, Schmitt (aktueller DT-Wert)
		0xb6  # wie 0xb0, Treiberstärke X6
		0xa0  # OD, Schmitt, langsame Flanke
		0x90  # Push-Pull, schnell, Schmitt
		0x10  # Push-Pull, schnell (NXP EVK)
		0x1f0 # OD, schnell, Schmitt, interner Pull-up
		0x1b0 # OD, schnell, Schmitt, interner Pull-down (nur Diagnose)
	)
fi

pad() {
	python3 - "$@" << 'EOF'
import mmap, os, struct, sys
addr = int(sys.argv[1], 16)
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 4096, offset=addr & ~0xfff)
o = addr & 0xfff
if len(sys.argv) > 2:
    m[o:o + 4] = struct.pack("<I", int(sys.argv[2], 16))
print("0x%x" % struct.unpack("<I", m[o:o + 4])[0])
EOF
}

pidof kodi-gbm > /dev/null && { echo "Kodi läuft, erst beenden: systemctl stop kodi-vpu" >&2; exit 1; }
orig="$(pad "${REG}")" || exit 1
orig_dbg="$(cat "${DBG}")"
trap 'pad "${REG}" "${orig}" > /dev/null; echo "${orig_dbg}" > "${DBG}"' EXIT
echo 2 > "${DBG}"
echo "Ausgangswert ${orig}, PA $(cec-ctl -d /dev/cec0 | sed -n 's/.*Physical Address *: *//p')"
printf '%-7s %-9s %-7s %-7s %-7s\n' Pad belegt Error NACK OK

for val in "${VALUES[@]}"; do
	pad "${REG}" "${val}" > /dev/null
	sleep 1
	claimed=0
	err=0
	nack=0
	ok=0
	for ((i = 1; i <= ROUNDS; i++)); do
		cec-ctl -d /dev/cec0 --clear > /dev/null 2>&1
		sleep 0.5
		dmesg -C
		cec-ctl -d /dev/cec0 --playback > /dev/null 2>&1
		sleep 1
		mask="$(cec-ctl -d /dev/cec0 | sed -n 's/.*Logical Address Mask *: *//p')"
		((mask & 0x0910)) && claimed=$((claimed + 1))
		log="$(dmesg | grep "cec_transmit_done_ts: status")"
		err=$((err + $(grep -c "status 0x10" <<< "${log}")))
		nack=$((nack + $(grep -c "status 0x04" <<< "${log}")))
		ok=$((ok + $(grep -c "status 0x01" <<< "${log}")))
	done
	printf '%-7s %-9s %-7s %-7s %-7s\n' "${val}" "${claimed}/${ROUNDS}" "${err}" "${nack}" "${ok}"
done
