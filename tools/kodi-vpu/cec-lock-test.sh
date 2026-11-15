#!/bin/bash
# CEC-Sendefehler (sofortiger Initiator-Fehler) gegen HDMI_CEC_LOCK testen (i.MX8MP, dw-hdmi).
# Läuft AUF DEM BOARD als root, Kodi gestoppt, HDMI-Ausgang aktiv (Register sonst nicht lesbar).
# Aufruf: cec-lock-test.sh [anzahl] [ziel-la]   (Standard: 20 Nachrichten an LA 14)
set -u

N="${1:-20}"
TO="${2:-14}"
BASE=0x32fd8000 # dw-hdmi, reg-io-width 1

# Byte-Register lesen/schreiben über /dev/mem. Argumente: offset [wert]
reg() {
	python3 - "${BASE}" "$@" << 'EOF'
import mmap, os, sys
base, off = int(sys.argv[1], 16), int(sys.argv[2], 16)
page = (base + off) & ~0xfff
fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
m = mmap.mmap(fd, 4096, offset=page)
o = (base + off) & 0xfff
if len(sys.argv) > 3:
    m[o] = int(sys.argv[3], 16)
print("0x%02x" % m[o])
EOF
}

dump() {
	local name off
	for name in CTRL:7d00 STAT:7d01 MASK:7d02 POLARITY:7d03 ADDR_L:7d05 ADDR_H:7d06 TX_CNT:7d07 RX_CNT:7d08 LOCK:7d30 IH_CEC_STAT0:0106; do
		off="${name#*:}"
		printf '  %-13s %s\n' "${name%%:*}" "$(reg "0x${off}")"
	done
}

send() {
	cec-ctl -d /dev/cec0 --to "${TO}" --give-osd-name 2>&1 | grep -q "Tx, OK"
}

pidof kodi-gbm > /dev/null && { echo "Kodi läuft, erst beenden: systemctl stop kodi-vpu" >&2; exit 1; }
cec-ctl -d /dev/cec0 --playback > /dev/null
sleep 2

echo "Register vorher:"
dump

ok=0
for ((i = 1; i <= N; i++)); do send && ok=$((ok + 1)); sleep 0.5; done
echo "ohne Eingriff: ${ok} OK von ${N}"
echo "Register danach:"
dump

ok=0
for ((i = 1; i <= N; i++)); do
	reg 0x7d30 0x00 > /dev/null
	send && ok=$((ok + 1))
	sleep 0.5
done
echo "mit HDMI_CEC_LOCK=0 vor jedem Senden: ${ok} OK von ${N}"
