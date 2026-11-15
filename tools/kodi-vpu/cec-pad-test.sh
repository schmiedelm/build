#!/bin/bash
# CEC-Sendefehler gegen die Pad-Einstellung von HDMI_CEC testen (i.MX8MP).
# Läuft AUF DEM BOARD als root, Kodi gestoppt. Schreibt das Pad-Register zur Laufzeit,
# nach dem Test steht wieder der Ausgangswert drin. Kein Kernel-Build nötig.
# Aufruf: cec-pad-test.sh [anzahl] [ziel-la]   (Standard: 30 Nachrichten an LA 14)
set -u

N="${1:-30}"
TO="${2:-14}"
REG=0x303304A8 # IOMUXC_SW_PAD_CTL_PAD_HDMI_CEC (0x30330000 + 0x4A8)

# Register lesen/schreiben über /dev/mem (python3), ohne devmem-Werkzeug.
pad() {
	python3 - "$@" << 'EOF'
import mmap, os, struct, sys
addr = int(sys.argv[1], 16)
base, off = addr & ~0xfff, addr & 0xfff
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 4096, offset=base)
if len(sys.argv) > 2:
    m[off:off + 4] = struct.pack("<I", int(sys.argv[2], 16))
print("0x%08x" % struct.unpack("<I", m[off:off + 4])[0])
EOF
}

pidof kodi-gbm > /dev/null && { echo "Kodi läuft, erst beenden: systemctl stop kodi-vpu" >&2; exit 1; }
orig="$(pad "${REG}")" || exit 1
echo "Ausgangswert ${orig}"
cec-ctl -d /dev/cec0 --playback > /dev/null

# 0x30: ODE+FSEL (RAS314)  0xb0: +Schmitt  0x1f0: +Schmitt+Pull-up
for val in 0x40000030 0x400000b0 0x400001f0; do
	pad "${REG}" "${val}" > /dev/null
	sleep 1
	ok=0
	err=0
	for ((i = 1; i <= N; i++)); do
		if cec-ctl -d /dev/cec0 --to "${TO}" --give-osd-name 2>&1 | grep -q "Tx, OK"; then
			ok=$((ok + 1))
		else
			err=$((err + 1))
		fi
		sleep 0.5
	done
	echo "Pad $(pad "${REG}"): ${ok} OK, ${err} Fehler von ${N}"
done

pad "${REG}" "${orig}" > /dev/null
echo "zurückgesetzt auf $(pad "${REG}")"
