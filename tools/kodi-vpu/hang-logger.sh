#!/bin/bash
# Kernel-Stacks beim Hänger sichern (HDMI-Moduswechsel, clk_prepare_lock).
# Läuft AUF DEM BOARD als root, in einer zweiten Konsole, vor Kodi bzw. dem Stresstest.
# Schreibt nach <ausgabe-dir> (Standard /media/BigData/hang), nicht auf die eMMC:
# Während des Hängers blockiert I/O auf der eMMC.
# Aufruf: hang-logger.sh [ausgabe-dir]
set -u

OUT="${1:-/media/BigData/hang}"
mkdir -p "${OUT}" || exit 1
LOG="${OUT}/hang.log"

echo 1 > /proc/sys/kernel/sysrq
if [[ -e /proc/sys/kernel/hung_task_timeout_secs ]]; then
	echo 20 > /proc/sys/kernel/hung_task_timeout_secs
	echo "hung_task: aktiv (20 s)"
else
	echo "hung_task: nicht im Kernel"
fi

# Ausgangszustand. Nur JETZT lesen: clk_summary nimmt clk_prepare_lock.
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
{
	uname -a
	cat /sys/kernel/debug/clk/clk_summary
	echo
	cat /sys/kernel/debug/pm_genpd/pm_genpd_summary
} > "${OUT}/baseline.txt" 2>&1
sync "${OUT}/baseline.txt"

# Kernel-Meldungen fortlaufend mitschreiben (läuft schon vor dem Hänger).
cat /dev/kmsg > "${OUT}/kmsg.log" &
KMSG=$!
trap 'kill ${KMSG} 2>/dev/null' EXIT

# Nur dateibezogenes sync: ein globales sync hängt an der eMMC.
# Alle Programme der Schleife einmal aufrufen, damit sie im Page-Cache liegen.
ps -e > /dev/null; awk "BEGIN{}" < /dev/null; grep -q x /dev/null; date > /dev/null; sync "${OUT}/baseline.txt"

echo "Logger läuft, Ausgabe in ${OUT}. Jetzt Kodi oder hdmi-mode-stress.sh starten. Abbruch mit Strg+C."
dumped=0
seen=0
while true; do
	D="$(ps -eLo pid,tid,stat,wchan:28,comm | awk '$3 ~ /D/')"
	{
		date +%T
		grep -E '38300000|38310000' /proc/interrupts
		echo "${D}"
	} >> "${LOG}"
	# Auslöser: Task im D-Zustand in clk_prepare_lock oder rpm_resume, zwei Runden in Folge.
	if grep -qE 'clk_prepare_lock|rpm_resume' <<< "${D}"; then
		seen=$((seen + 1))
	else
		seen=0
	fi
	if [[ ${seen} -ge 2 && ${dumped} -lt 3 ]]; then
		{
			echo "### Hänger erkannt, Dump $((dumped + 1))"
			while read -r pid tid _; do
				echo "== pid ${pid} tid ${tid} ($(< "/proc/${tid}/comm"))"
				cat "/proc/${tid}/stack"
			done <<< "${D}"
		} >> "${LOG}" 2>&1
		echo w > /proc/sysrq-trigger
		[[ ${dumped} -eq 0 ]] && echo l > /proc/sysrq-trigger
		dumped=$((dumped + 1))
	fi
	echo >> "${LOG}"
	sync "${LOG}" "${OUT}/kmsg.log"
	sleep 2
done
