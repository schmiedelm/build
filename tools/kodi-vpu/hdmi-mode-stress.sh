#!/bin/bash
# Stresstest: HDMI-Moduswechsel 60 Hz <-> 23,976 Hz in einer Schleife (Deadlock
# clk_prepare_lock / Runtime-PM der HDMI-PHY). Läuft AUF DEM BOARD als root,
# ohne Kodi und ohne Desktop. Braucht modetest (Paket libdrm-tests).
# Aufruf: hdmi-mode-stress.sh [-n anzahl] [-v videodatei] [-o ausgabe-dir]
#   -n  Anzahl Durchläufe (Standard 500)
#   -v  dekodiert die Datei parallel per VPU (ffmpeg -hwaccel v4l2request)
#   -o  Protokoll-Verzeichnis (Standard /media/BigData/hang), nicht auf der eMMC
set -u

N=500
VIDEO=""
OUT=/media/BigData/hang
while getopts "n:v:o:" opt; do
	case "${opt}" in
		n) N="${OPTARG}" ;;
		v) VIDEO="${OPTARG}" ;;
		o) OUT="${OPTARG}" ;;
		*) exit 1 ;;
	esac
done
command -v modetest > /dev/null || { echo "modetest fehlt: apt-get install -y libdrm-tests" >&2; exit 1; }
pidof kodi-gbm > /dev/null && { echo "Kodi läuft, erst beenden" >&2; exit 1; }
mkdir -p "${OUT}" || exit 1
LOG="${OUT}/stress.log"
DRV=imx-lcdif

# Verbundenen Connector, seinen Encoder/CRTC und die Modus-Indizes ermitteln.
info="$(modetest -M "${DRV}" -c 2> /dev/null)"
read -r CONN ENC < <(awk '$3 == "connected" {print $1, $2; exit}' <<< "${info}")
[[ -n ${CONN:-} ]] || { echo "kein verbundener Connector" >&2; exit 1; }
CRTC="$(modetest -M "${DRV}" -e 2> /dev/null | awk -v e="${ENC}" '$1 == e {print $2; exit}')"
modes="$(awk -v c="${CONN}" '$1 == c && $3 ~ /connected/ {f = 1; next}
	f && /^[0-9]+\t/ {f = 0} f && $1 ~ /^#[0-9]+$/ {print}' <<< "${info}")"
M60="$(awk '$2 == "1920x1080" && $3 + 0 > 59.99 && $3 + 0 < 60.01 {sub("#", "", $1); print $1; exit}' <<< "${modes}")"
M24="$(awk '$2 == "1920x1080" && $3 + 0 > 23.9 && $3 + 0 < 23.99 {sub("#", "", $1); print $1; exit}' <<< "${modes}")"
[[ -n ${M60} && -n ${M24} ]] || { echo "Modi 1920x1080@60/23.976 nicht gefunden:" >&2; echo "${modes}" >&2; exit 1; }
echo "Connector ${CONN}, CRTC ${CRTC}, Modus 60 Hz #${M60}, 23,976 Hz #${M24}" | tee -a "${LOG}"

if [[ -n ${VIDEO} ]]; then
	(
		while true; do
			/opt/kodi-ffmpeg/bin/ffmpeg -nostdin -loglevel error -hwaccel v4l2request \
				-i "${VIDEO}" -t 30 -f null - < /dev/null
		done
	) &
	FF=$!
	trap 'kill ${FF} 2>/dev/null; pkill -f "ffmpeg -nostdin" 2>/dev/null' EXIT
	echo "VPU-Last läuft (ffmpeg, pid ${FF})" | tee -a "${LOG}"
fi

for ((i = 1; i <= N; i++)); do
	for m in "${M24}" "${M60}"; do
		echo "$(date +%T) lauf ${i} modus #${m}" >> "${LOG}"
		sync "${LOG}"
		# stdin leer: modetest setzt den Modus und beendet sich sofort.
		# Beim Beenden stellt fbcon den Konsolenmodus wieder her (zweiter Wechsel).
		timeout 10 modetest -M "${DRV}" -s "${CONN}@${CRTC}:#${m}" < /dev/null > /dev/null 2>&1
		# Zufällige Pause 0..3 s: Autosuspend der PHY in wechselnden Zeitfenstern.
		sleep "$((RANDOM % 4)).$((RANDOM % 10))"
	done
	((i % 10 == 0)) && echo "lauf ${i}/${N}"
done
echo "$(date +%T) fertig: ${N} Läufe ohne Hänger" | tee -a "${LOG}"
