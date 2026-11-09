#!/usr/bin/env bash
#
# Automated interface test harness for TQ boards.
#
# Runs the core interface tests (Ethernet, USB, CAN, Audio, GPIO, GPU, VPU)
# over SSH, and prompts for the tests that need a human (Boot, Display, LVDS).
# Requires root SSH access to each board (password, see SSH_PASS), and the
# can-utils/i2c-tools/pciutils/evtest/mesa-utils packages installed on the
# board (see config/boards/*.conf - PACKAGE_LIST_BOARD). The VPU test also
# needs GStreamer with the v4l2codecs plugin (gstreamer1.0-tools,
# -plugins-bad, -plugins-good).
#
# Besides the test results the summary reports:
#   - the running kernel release per run (uname -r) and the number of boots
#     seen (the LVDS test reboots the board; boots are told apart by boot_id),
#   - a "dmesg" row: kernel messages of level err or worse, grouped per boot.
#     It is a hint (~), never a failure - known-harmless messages can be
#     dropped via DMESG_IGNORE_REGEX, after checking them,
#   - the reason of every failing test under the table ("Fehlergruende").
#
# Testing the same board twice in one session (e.g. two kernels or images)
# gives separate table columns: "<board>", "<board> #2", ...
#
# Usage:
#   doc/tests/run-tests.sh                  # run all boards
#   doc/tests/run-tests.sh --board MBa62xx  # run just one board
#   doc/tests/run-tests.sh --list           # show board/test matrix, don't run
#
# CAN test assumes CAN1-TX is physically wired to CAN2-RX (loopback jumper),
# same as the manual tests done in this repo's bring-up sessions.

set -uo pipefail

# ── Board configuration ──────────────────────────────────────────────────
# name;ssh-host;tests (comma-separated: ethernet,usb,can,audio,gpio,display,gpu)
# ssh-host is a static IP on the schmiedel-w test bench (10.250.250.0/24) -
# fill in the real IP before testing a given board; CHANGEME is a placeholder.
declare -a BOARDS=(
	"MBa62xx;10.250.250.12;ethernet,usb,can,audio,gpio,display,gpu"
	"MBa67xx;10.250.250.16;ethernet,usb,can,audio,gpio,display,gpu,lvds"
	"MBa93xxCA;10.250.250.32;ethernet,usb,can,gpio,display"
	"MBa93xxLA-mini;10.250.250.7;ethernet,usb,can,gpio,display"
	"MBa8MPxL;10.250.250.45;ethernet,usb,can,audio,gpio,display,gpu,vpu,lvds"
	"MBa8MPxL-RAS314;10.250.250.19;ethernet,usb,audio,gpio,display,gpu,vpu,lvds"
	"TQ-SMARC2-TQMa8MPxS;CHANGEME;ethernet,usb,can,audio,gpio,display,gpu,vpu"
	"LAVA-BMS;CHANGEME;ethernet,gpio"
)

SSH_USER="root"
SSH_PASS="root"
# Boards get reflashed a lot on this bench, so the host key changes on every
# reflash - don't bother pinning it, this is an isolated test network.
SSH_OPTS=(-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)

if ! command -v sshpass &>/dev/null; then
	echo "sshpass ist nicht installiert (noetig fuer Passwort-Login) - 'apt install sshpass'." >&2
	exit 1
fi

# ── Helpers ───────────────────────────────────────────────────────────────

ssh_run() {
	local host="$1"
	shift
	sshpass -p "$SSH_PASS" ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" "$@"
}

# Results: RESULTS["<board>|<test>"] = PASS / FAIL / SKIP / MANUAL-OK / MANUAL-FAIL
declare -A RESULTS
declare -a TEST_ORDER=(boot ethernet display audio usb can gpio lvds gpu vpu)
declare -a BOARD_ORDER=()

record() {
	RESULTS["$1|$2"]="$3"
}

# Kernel release and kernel-log errors per board. The LVDS test reboots the
# board, which empties dmesg - so dmesg is scanned right after the boot test
# and again after all tests; the findings are merged and de-duplicated.
declare -A KERNEL_VERSION
declare -A DMESG_ERRORS   # formatted report per run (empty = no findings)
declare -A DMESG_BY_BOOT  # "<run>|<boot_id>" -> raw findings of that boot
declare -A BOOT_IDS       # run -> space-separated boot_ids in order of appearance
declare -A BOOT_COUNT     # run -> number of distinct boots seen

# Optional extended regex of known-harmless messages to drop from the report.
# Empty = report everything at level err or worse. Add entries here only after
# a message was checked and judged harmless, with a comment saying why.
DMESG_IGNORE_REGEX=''

collect_kernel() {
	local board="$1" host="$2" rel
	rel=$(ssh_run "$host" "uname -r" 2>/dev/null) && KERNEL_VERSION["$board"]="$rel"
}

# Appends kernel messages of level err/crit/alert/emerg to DMESG_ERRORS[board].
scan_dmesg() {
	local board="$1" host="$2" raw id out
	# boot_id and dmesg in ONE ssh call, so both are guaranteed to come from the
	# same boot (a second call could land after a reboot).
	if raw=$(ssh_run "$host" "cat /proc/sys/kernel/random/boot_id; dmesg --level=err,crit,alert,emerg" 2>/dev/null); then
		id=$(head -n1 <<<"$raw")
		out=$(tail -n +2 <<<"$raw")
	else
		id="unbekannt"
		out="(dmesg konnte nicht gelesen werden)"
	fi
	if [[ -n "$DMESG_IGNORE_REGEX" ]]; then
		out=$(grep -Ev "$DMESG_IGNORE_REGEX" <<<"$out")
	fi
	[[ " ${BOOT_IDS[$board]:-} " == *" $id "* ]] || BOOT_IDS["$board"]+="$id "
	DMESG_BY_BOOT["$board|$id"]+="$out"$'\n'
}

# Merges the scans, records PASS/WARN for the "dmesg" row and prints a summary.
finish_dmesg() {
	local board="$1" id short lines count total=0 boots=0 report=""
	for id in ${BOOT_IDS[$board]:-}; do
		boots=$((boots + 1))
		lines=$(printf '%s' "${DMESG_BY_BOOT["$board|$id"]:-}" | sed '/^$/d' | sort -u)
		[[ -z "$lines" ]] && continue
		count=$(wc -l <<<"$lines")
		total=$((total + count))
		short="${id:0:8}"
		[[ "$id" == "unbekannt" ]] && short="$id"
		report+="Boot $boots ($short):"$'\n'"$lines"$'\n'
	done
	BOOT_COUNT["$board"]=$boots
	DMESG_ERRORS["$board"]="$report"

	if ((boots > 1)); then
		printf "  %-10s %s\n" "boots" "$boots (Neustart erkannt)"
	else
		printf "  %-10s %s\n" "boots" "$boots"
	fi
	if ((total == 0)); then
		record "$board" "dmesg" "PASS"
		printf "  %-10s %s\n" "dmesg" "PASS"
	else
		record "$board" "dmesg" "WARN ($total)"
		printf "  %-10s %s\n" "dmesg" "WARN ($total Meldungen, siehe Zusammenfassung)"
	fi
}

# ── Individual tests ──────────────────────────────────────────────────────

test_boot() {
	local host="$1"
	ssh_run "$host" "true" &>/dev/null && echo PASS || echo FAIL
}

test_ethernet() {
	local host="$1"
	ssh_run "$host" "ip -4 -o addr show scope global | grep -qv ' lo '" &>/dev/null && echo PASS || echo FAIL
}

test_usb() {
	local host="$1"
	local out
	out=$(ssh_run "$host" "lsusb" 2>/dev/null) || {
		echo FAIL
		return
	}
	# Anything beyond the root hub(s) means something actually enumerated.
	# Basic presence check only - doesn't verify storage read/write throughput.
	if echo "$out" | grep -qv "Linux Foundation.*root hub"; then
		echo PASS
	else
		echo "WARN (nur Root-Hub sichtbar, kein externes Geraet erkannt)"
	fi
}

test_can() {
	local host="$1"
	ssh_run "$host" '
		set -e
		ip link set can0 up type can bitrate 500000 2>/dev/null || ip link set can0 up 2>/dev/null || true
		ip link set can1 up type can bitrate 500000 2>/dev/null || ip link set can1 up 2>/dev/null || true
		rm -f /tmp/run-tests-candump.out
		(timeout 2 candump can1 > /tmp/run-tests-candump.out 2>/dev/null &)
		sleep 0.3
		cansend can0 123#DEADBEEF
		sleep 1
		grep -q "DE AD BE EF" /tmp/run-tests-candump.out
	' &>/dev/null && echo PASS || echo "FAIL (CAN1-TX<->CAN2-RX verkabelt?)"
}

# Most TQ boards share the same TLV320AIC32x4 codec/card name (tqmtlv320aic32,
# from the common ASOUND_STATE file), but a board with its own dedicated sound
# card node (e.g. RAS314's tqmba8mpras314) needs its actual ALSA card name here.
declare -A AUDIO_CARD_NAME=(
	["MBa8MPxL-RAS314"]="tqmba8mpras314"
)

test_audio() {
	local board="$1" host="$2"
	local ans
	local card="${AUDIO_CARD_NAME[$board]:-tqmtlv320aic32}"
	if ! ssh_run "$host" "aplay -l 2>/dev/null | grep -qi '^card'" &>/dev/null; then
		echo FAIL
		return
	fi
	# Card is present - play a test tone and ask a human to confirm it was
	# actually audible, same idea as the display check below. Target the
	# card explicitly - plain "aplay" without -D falls back to ALSA's hw:0
	# default, which doesn't exist on boards where the codec is card 1
	# (e.g. MBa8MPxL).
	ssh_run "$host" "aplay -D hw:$card /usr/share/sounds/alsa/Front_Center.wav" &>/dev/null
	read -rp "  [$board] War der Ton hoerbar? [j/N] " ans
	[[ "$ans" =~ ^[jJ] ]] && echo "MANUAL-OK" || echo "MANUAL-FAIL"
}

test_gpio() {
	local host="$1"
	# Presence check: gpiod tooling responds and at least one line has a
	# named consumer (LED/button/expander etc.) - not a full functional test.
	ssh_run "$host" "gpioinfo 2>/dev/null | grep -q 'consumer='" &>/dev/null && echo PASS || echo FAIL
}

# Two different GPU vendors across the fleet, so test_gpu() dispatches per board:
# - "powervr" (MBa62xx, MBa67xx): out-of-tree DKMS Rogue/AXE driver (see
#   custom_kernel_config__*_disable_intree_powervr in the board conf), tested via
#   TI's own rgx_triangle_test (ti-img-rogue-tools-{am62,am62p} package). On MBa67xx
#   "edge" the gpu@fd80000 devicetree node itself is also missing from mainline (same
#   gap class as DSS/DSI, see mba67xx-tqma67xx.conf), so expect FAIL there too.
# - "etnaviv" (MBa8MPxL, MBa8MPxL-RAS314, TQ-SMARC2-TQMa8MPxS): in-tree, mainline,
#   no DKMS/firmware needed. Tested via mesa-utils' "eglinfo -B -p surfaceless" instead
#   of a vendor self-test binary (none exists for etnaviv). The surfaceless EGL platform
#   needs neither X11/Wayland nor KMS ownership (es2_info needs a display and fails on a
#   headless image) and prints the renderer, which we grep for "vivante"/"etnaviv" to
#   rule out a silent llvmpipe (software) fallback - unlike rgx_triangle_test's exit
#   code, eglinfo succeeds either way, so the content check is what actually proves the
#   hardware GPU is in use.
# Both checks are render-node based (/dev/dri/renderDxxx) - no display/KMS needed.
declare -A GPU_VENDOR=(
	["MBa62xx"]="powervr"
	["MBa67xx"]="powervr"
	["MBa8MPxL"]="etnaviv"
	["MBa8MPxL-RAS314"]="etnaviv"
	["TQ-SMARC2-TQMa8MPxS"]="etnaviv"
)

test_gpu() {
	local board="$1" host="$2"
	case "${GPU_VENDOR[$board]:-}" in
	powervr)
		if ! ssh_run "$host" "dmesg | grep -qi 'Initialized pvr'" &>/dev/null; then
			echo "FAIL (kein 'Initialized pvr' in dmesg - DKMS-Treiber nicht geladen?)"
			return
		fi
		ssh_run "$host" "rgx_triangle_test" &>/dev/null && echo PASS || echo "FAIL (rgx_triangle_test)"
		;;
	etnaviv)
		if ! ssh_run "$host" "dmesg | grep -qi etnaviv" &>/dev/null; then
			echo "FAIL (kein etnaviv-Probe in dmesg)"
			return
		fi
		local renderer
		renderer=$(ssh_run "$host" "eglinfo -B -p surfaceless 2>/dev/null | grep -i renderer")
		if echo "$renderer" | grep -qi "vivante\|etnaviv"; then
			echo PASS
		else
			echo "FAIL (eglinfo renderer nicht Vivante/etnaviv: ${renderer:-leer})"
		fi
		;;
	*)
		echo "SKIP (kein GPU-Check fuer $board definiert)"
		;;
	esac
}

# Hantro VPU (imx8mp only): two decode-only cores, G1 (H.264/MPEG2/VP8) and G2
# (HEVC/VP9), both in-tree/mainline, no firmware/DKMS needed (driver name
# "hantro-vpu"). No encoder is wired up in mainline devicetree at all - decode-only
# is the full extent of what's testable.
# Both cores are *stateless* decoders (v4l2-ctl --list-formats-out: S264/S265/VP8F/MG2S),
# which ffmpeg's *_v4l2m2m wrappers cannot drive, and stock Debian ffmpeg has no
# v4l2request hwaccel (measured: trixie libavcodec.so.61 7.1.5 has no such string). GStreamer's
# v4l2codecs plugin (gstreamer1.0-plugins-bad: v4l2slh264dec / v4l2slh265dec) does drive
# them with stock packages, so the test decodes with gst-launch-1.0 (measured on
# MBa8MPxL-RAS314: G1 and G2 interrupts +25 per 25-frame clip).
# gst-launch exits non-zero when the decoder cannot be set up, but the decode interrupt
# of the core itself is the independent proof and is checked anyway: it must grow while
# the clip is decoded. G1 and G2 have fixed addresses on the i.MX8MP (38300000 / 38310000).
# The clips are shipped in assets/ (4:2:0, 8 bit, 320x240, 25 frames); the board does not
# create them itself.
VPU_ASSETS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/assets"

# Sum of all per-CPU counts of the /proc/interrupts line matching $2.
vpu_irq_count() {
	ssh_run "$1" "awk '/$2/ {for(i=2;i<=NF&&\$i~/^[0-9]+\$/;i++)s+=\$i} END{print s+0}' /proc/interrupts"
}

# $1 host, $2 local clip, $3 core address, $4 label, $5 GStreamer parser, $6 GStreamer
# decoder element. Prints nothing on success.
vpu_decode_check() {
	local host="$1" clip="$2" core="$3" label="$4" parse="$5" dec="$6" before after
	if [[ ! -f "$clip" ]]; then
		echo "FAIL ($label: Testclip fehlt: $clip)"
		return 1
	fi
	if ! sshpass -p "$SSH_PASS" scp "${SSH_OPTS[@]}" "$clip" "${SSH_USER}@${host}:/tmp/" &>/dev/null; then
		echo "FAIL ($label: scp des Clips fehlgeschlagen)"
		return 1
	fi
	before=$(vpu_irq_count "$host" "$core")
	if ! ssh_run "$host" "timeout 60 gst-launch-1.0 -q filesrc location=/tmp/$(basename "$clip") ! qtdemux ! $parse ! $dec ! fakesink" &>/dev/null; then
		echo "FAIL ($label: gst-launch mit $dec fehlgeschlagen)"
		return 1
	fi
	after=$(vpu_irq_count "$host" "$core")
	if ! [[ "$before" =~ ^[0-9]+$ && "$after" =~ ^[0-9]+$ ]] || ((after <= before)); then
		echo "FAIL ($label: Interrupt $core wuchs nicht (${before:-?} -> ${after:-?}), Software-Fallback?)"
		return 1
	fi
	return 0
}

test_vpu() {
	local host="$1" out
	if ! ssh_run "$host" "dmesg | grep -qi hantro-vpu" &>/dev/null; then
		echo "FAIL (kein hantro-vpu Treiber-Probe in dmesg)"
		return
	fi
	local el
	for el in v4l2slh264dec v4l2slh265dec; do
		if ! ssh_run "$host" "gst-inspect-1.0 $el" &>/dev/null; then
			echo "FAIL (GStreamer-Element $el fehlt - gstreamer1.0-tools/-plugins-bad/-plugins-good im Image?)"
			return
		fi
	done
	out=$(vpu_decode_check "$host" "$VPU_ASSETS/vpu-h264-320x240.mp4" 38300000 "G1/H.264" h264parse v4l2slh264dec) || {
		echo "$out"
		return
	}
	out=$(vpu_decode_check "$host" "$VPU_ASSETS/vpu-hevc-320x240.mp4" 38310000 "G2/HEVC" h265parse v4l2slh265dec) || {
		echo "$out"
		return
	}
	echo PASS
}

test_display() {
	local board="$1"
	local ans
	read -rp "  [$board] Ist ein Bild auf dem Display sichtbar? [j/N] " ans
	[[ "$ans" =~ ^[jJ] ]] && echo "MANUAL-OK" || echo "MANUAL-FAIL"
}

# LVDS needs a manual extlinux.conf edit + reboot on boards where it isn't
# the default output (e.g. MBa8MPxL: HDMI works out of the box, LVDS needs
# an fdtoverlays line first) - guide through that, then ask for confirmation.
# Per-board fdtoverlays line (imx8m/imx93 boards use a /boot/ prefix - single
# ext4 partition with /boot as a plain subdir, unlike the K3 boards' separate
# FAT boot partition, where /boot must NOT be in the path).
declare -A LVDS_OVERLAY_LINE=(
	["MBa8MPxL"]="fdtoverlays /boot/dtb/freescale/overlay/imx8mp-tqma8mpql-mba8mpxl-lvds-tm070jvhg33.dtbo"
	["MBa8MPxL-RAS314"]="fdtoverlays /boot/dtb/freescale/overlay/imx8mp-tqma8mpql-mba8mp-ras314-lvds-tm070jvhg33.dtbo"
	# MBa62xx (K3 board, separate FAT boot partition - no /boot prefix, see
	# comment above) already ships with LVDS as its DEFAULT_OVERLAYS panel, so
	# this line is already present in extlinux.conf out of the box - this is a
	# no-op re-add, just here so test_lvds has the real filename to show/verify
	# rather than its generic TODO placeholder.
	["MBa62xx"]="fdtoverlays /dtb/ti/overlay/k3-am62-tqma62xx-mba62xx-lvds-tm070jdhg30.dtbo"
	# MBa67xx: same no-op-re-add situation as MBa62xx above, but only on
	# "vendor" - the overlay doesn't exist at all on "edge" (see the KNOWN
	# LIMITATION comment in mba67xx-tqma67xx.conf), so expect this test to
	# FAIL there too, same as the "gpu" test.
	["MBa67xx"]="fdtoverlays /dtb/ti/overlay/k3-am67a-tqma67xx-mba67xx-lvds-tm070jdhg30.dtbo"
)

test_lvds() {
	local board="$1"
	local ans
	local line="${LVDS_OVERLAY_LINE[$board]:-fdtoverlays /boot/dtb/<family>/overlay/<OVERLAY_PREFIX>-lvds-<panel>.dtbo  # TODO: LVDS_OVERLAY_LINE[$board] eintragen}"
	# run_test()'s caller captures this function's stdout via $(...) to get
	# the PASS/FAIL result - these hint lines must go to stderr, like read
	# -p's prompt does, or they'd be buffered and only show up at the end.
	echo "  [$board] LVDS-Overlay aktivieren: in /boot/extlinux/extlinux.conf ergaenzen" >&2
	echo "    $line" >&2
	echo "  und das Board neu starten." >&2
	read -rp "  Weiter mit Enter, sobald das Board wieder hochgefahren ist... " _
	read -rp "  [$board] Ist jetzt ein Bild auf dem LVDS-Panel sichtbar? [j/N] " ans
	[[ "$ans" =~ ^[jJ] ]] && echo "MANUAL-OK" || echo "MANUAL-FAIL"
}

run_test() {
	local board="$1" host="$2" test="$3"
	case "$test" in
	boot) test_boot "$host" ;;
	ethernet) test_ethernet "$host" ;;
	usb) test_usb "$host" ;;
	can) test_can "$host" ;;
	audio) test_audio "$board" "$host" ;;
	gpio) test_gpio "$host" ;;
	display) test_display "$board" ;;
	lvds) test_lvds "$board" ;;
	gpu) test_gpu "$board" "$host" ;;
	vpu) test_vpu "$host" ;;
	*) echo "SKIP" ;;
	esac
}

# ── Argument parsing ────────────────────────────────────────────────────

FILTER_BOARD=""
LIST_ONLY="no"
while [[ $# -gt 0 ]]; do
	case "$1" in
	--board)
		FILTER_BOARD="$2"
		shift 2
		;;
	--list)
		LIST_ONLY="yes"
		shift
		;;
	*)
		echo "Unbekannte Option: $1" >&2
		exit 1
		;;
	esac
done

if [[ "$LIST_ONLY" == "yes" ]]; then
	for entry in "${BOARDS[@]}"; do
		IFS=';' read -r board host tests <<<"$entry"
		echo "$board ($host): boot,$tests"
	done
	exit 0
fi

# Runs one board's tests and records results. Only one physical board is ever
# connected at a time on this bench, so this is the unit of work - not a loop
# over all of them.
run_board() {
	local board="$1" host="$2" tests="$3"

	# Every run gets its own key (= table column). Testing the same board twice
	# in one session (e.g. two kernels, one after the other) would otherwise
	# overwrite the first run's results, kernel version and dmesg findings.
	local key="$board" n=2
	while printf '%s\n' "${BOARD_ORDER[@]}" | grep -qxF "$key"; do
		key="$board #$n"
		n=$((n + 1))
	done
	BOARD_ORDER+=("$key")

	echo "══════════════════════════════════════════════════════"
	echo "  $key  ($host)"
	echo "══════════════════════════════════════════════════════"

	result=$(test_boot "$host")
	record "$key" "boot" "$result"
	echo "  boot ....... $result"
	if [[ "$result" != "PASS" ]]; then
		echo "  -> Board nicht erreichbar, ueberspringe restliche Tests."
		for t in ethernet display audio usb can gpio lvds gpu vpu dmesg; do
			record "$key" "$t" "SKIP"
		done
		return
	fi

	collect_kernel "$key" "$host"
	echo "  kernel ..... ${KERNEL_VERSION[$key]:-unbekannt}"
	scan_dmesg "$key" "$host"

	IFS=',' read -ra test_list <<<"$tests"
	for t in "${TEST_ORDER[@]}"; do
		[[ "$t" == "boot" ]] && continue
		if printf '%s\n' "${test_list[@]}" | grep -qx "$t"; then
			result=$(run_test "$board" "$host" "$t")
			record "$key" "$t" "$result"
			printf "  %-10s %s\n" "$t" "$result"
		else
			record "$key" "$t" "N/A"
		fi
	done

	scan_dmesg "$key" "$host"
	finish_dmesg "$key"
	echo ""
}

find_board_entry() {
	local name="$1"
	for entry in "${BOARDS[@]}"; do
		IFS=';' read -r board host tests <<<"$entry"
		[[ "$board" == "$name" ]] && echo "$entry" && return 0
	done
	return 1
}

# ── Main flow ────────────────────────────────────────────────────────────

if [[ -n "$FILTER_BOARD" ]]; then
	# Non-interactive: test exactly the one board given and exit (e.g. for
	# calling this from another script).
	entry=$(find_board_entry "$FILTER_BOARD") || {
		echo "Unbekanntes Board: $FILTER_BOARD" >&2
		exit 1
	}
	IFS=';' read -r board host tests <<<"$entry"
	run_board "$board" "$host" "$tests"
else
	# Interactive: pick one board, test it, ask whether to continue with the
	# next one - matches a bench with only 1-2 boards connected at a time.
	while true; do
		echo "Welches Board ist gerade angeschlossen?"
		for i in "${!BOARDS[@]}"; do
			IFS=';' read -r board _ <<<"${BOARDS[$i]}"
			printf "  %2d) %s\n" "$((i + 1))" "$board"
		done
		read -rp "Nummer (Enter zum Beenden): " choice
		[[ -z "$choice" ]] && break
		if ! [[ "$choice" =~ ^[0-9]+$ ]] || ((choice < 1 || choice > ${#BOARDS[@]})); then
			echo "Ungueltige Auswahl."
			continue
		fi
		IFS=';' read -r board host tests <<<"${BOARDS[$((choice - 1))]}"
		run_board "$board" "$host" "$tests"
	done
fi

[[ ${#BOARD_ORDER[@]} -eq 0 ]] && exit 0

# ── Summary table (markdown) ───────────────────────────────────────────────

echo ""
echo "## Testergebnis $(date '+%Y-%m-%d %H:%M')"
echo ""
header="| Test |"
sep="|---|"
for b in "${BOARD_ORDER[@]}"; do
	header+=" $b |"
	sep+="---|"
done
echo "$header"
echo "$sep"
for t in "${TEST_ORDER[@]}"; do
	row="| $t |"
	for b in "${BOARD_ORDER[@]}"; do
		v="${RESULTS[$b|$t]:-SKIP}"
		case "$v" in
		PASS | MANUAL-OK) v="✓" ;;
		FAIL* | MANUAL-FAIL) v="✗" ;;
		N/A) v="N/A" ;;
		SKIP) v="—" ;;
		WARN*) v="~" ;;
		esac
		row+=" $v |"
	done
	echo "$row"
done

# dmesg is not a selectable test (always runs), so it has its own row.
row="| dmesg |"
for b in "${BOARD_ORDER[@]}"; do
	v="${RESULTS[$b|dmesg]:-SKIP}"
	case "$v" in
	PASS) v="✓" ;;
	WARN*) v="~ (${v#WARN (}" ;;
	SKIP) v="—" ;;
	esac
	row+=" $v |"
done
echo "$row"

echo ""
echo "Kernel:"
for b in "${BOARD_ORDER[@]}"; do
	echo "- $b: ${KERNEL_VERSION[$b]:-unbekannt} (${BOOT_COUNT[$b]:-0} Boot(s))"
done

# The table only shows symbols; the reason of a failing test is in its result
# string (e.g. "FAIL (eglinfo renderer nicht Vivante/etnaviv: leer)").
reasons=""
for b in "${BOARD_ORDER[@]}"; do
	for t in "${TEST_ORDER[@]}"; do
		v="${RESULTS[$b|$t]:-}"
		case "$v" in
		FAIL* | MANUAL-FAIL* | WARN*) reasons+="- $b / $t: $v"$'\n' ;;
		esac
	done
done
if [[ -n "$reasons" ]]; then
	echo ""
	echo "Fehlergruende:"
	printf '%s' "$reasons"
fi

for b in "${BOARD_ORDER[@]}"; do
	if [[ -n "${DMESG_ERRORS[$b]:-}" ]]; then
		echo ""
		echo "dmesg (err oder schlimmer) $b:"
		echo '```'
		echo "${DMESG_ERRORS[$b]}"
		echo '```'
	fi
done
