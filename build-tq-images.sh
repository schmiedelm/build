#!/bin/bash
# build-tq-images.sh — TQ-Boards bauen
#
# Standard: nur CLI-minimal-Images (reichen für den Boot-Test).
# Desktop-Images (Anzeige-Tests) nur auf Wunsch mit --desktop.
#
#   ./build-tq-images.sh                    # alle Boards, CLI-minimal
#   ./build-tq-images.sh --desktop          # zusätzlich die Desktop-Images
#   ./build-tq-images.sh --board mba8mpxl   # nur dieses Board (Name wie BOARD=...)
#   ./build-tq-images.sh --branch edge      # nur diesen Branch (current, edge oder vendor)
#   ./build-tq-images.sh --board mba8mpxl --branch edge --desktop   # Optionen lassen sich kombinieren
#
# Ein fehlgeschlagener Build stoppt die übrigen nicht. Am Ende steht eine
# Tabelle je Board/Branch; Exit-Code 1, wenn mindestens ein Build fehlschlug.

# $CLI_MINIMAL und $COMMON_* enthalten bewusst mehrere compile.sh-Argumente und
# müssen unquotiert aufgespalten werden.
# shellcheck disable=SC2086
set -uo pipefail

WITH_DESKTOP=0
ONLY_BOARD=""
ONLY_BRANCH=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--desktop) WITH_DESKTOP=1 ;;
		--board)
			if [[ $# -lt 2 ]]; then
				echo "--board braucht einen Board-Namen" >&2
				exit 2
			fi
			ONLY_BOARD="$2"
			shift
			;;
		--branch)
			if [[ $# -lt 2 ]]; then
				echo "--branch braucht current, edge oder vendor" >&2
				exit 2
			fi
			ONLY_BRANCH="$2"
			case "${ONLY_BRANCH}" in
				current | edge | vendor) ;;
				*)
					echo "Unbekannter Branch: ${ONLY_BRANCH} (erlaubt: current, edge, vendor)" >&2
					exit 2
					;;
			esac
			shift
			;;
		-h | --help)
			sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "Unbekannte Option: $1 (siehe --help)" >&2
			exit 2
			;;
	esac
	shift
done

COMMON_CURRENT="BRANCH=current COMPRESS_OUTPUTIMAGE=sha,img KERNEL_CONFIGURE=no NAMESERVER=10.150.72.8 KERNEL_GIT=shallow DESKTOP_TIER=minimal KERNEL_BTF=no"
COMMON_EDGE="BRANCH=edge COMPRESS_OUTPUTIMAGE=sha,img KERNEL_CONFIGURE=no NAMESERVER=10.150.72.8 KERNEL_GIT=shallow DESKTOP_TIER=minimal KERNEL_BTF=no"
COMMON_VENDOR="BRANCH=vendor COMPRESS_OUTPUTIMAGE=sha,img KERNEL_CONFIGURE=no NAMESERVER=10.150.72.8 KERNEL_GIT=shallow DESKTOP_TIER=minimal KERNEL_BTF=no"
CLI_MINIMAL="BUILD_DESKTOP=no BUILD_MINIMAL=yes ARTIFACT_IGNORE_CACHE=yes KERNEL_BTF=no"

declare -a RESULTS=()
FAILED=0

# build <Label> <compile.sh-Argumente...>
# Label erscheint nur in der Abschluss-Tabelle (z. B. "current/cli").
build() {
	local label="$1"
	shift
	local board="" branch="" arg
	for arg in "$@"; do
		[[ "${arg}" == BOARD=* ]] && board="${arg#BOARD=}"
		[[ "${arg}" == BRANCH=* ]] && branch="${arg#BRANCH=}"
	done
	if [[ -n "${ONLY_BOARD}" && "${board}" != "${ONLY_BOARD}" ]]; then
		return 0
	fi
	if [[ -n "${ONLY_BRANCH}" && "${branch}" != "${ONLY_BRANCH}" ]]; then
		return 0
	fi

	local start=${SECONDS} status="ok"
	if ! ./compile.sh "$@"; then
		status="FEHLER"
		FAILED=$((FAILED + 1))
	fi
	RESULTS+=("$(printf '%-7s %-24s %-14s %4d min' "${status}" "${board}" "${label}" $(((SECONDS - start) / 60)))")
}

# ══════════════════════════════════════════════════════════════════════════
# Phase 1: minimal images, current/vendor branch
# ══════════════════════════════════════════════════════════════════════════
build current/cli BOARD=lavabms-tqma93xx RELEASE=trixie $CLI_MINIMAL $COMMON_CURRENT
build current/cli BOARD=mba93xxca-tqma93xx RELEASE=trixie $CLI_MINIMAL $COMMON_CURRENT
build current/cli BOARD=mba93xxla-mini RELEASE=trixie $CLI_MINIMAL $COMMON_CURRENT
build current/cli BOARD=mba8mpxl RELEASE=trixie $CLI_MINIMAL $COMMON_CURRENT
build current/cli BOARD=mba8mpxl-ras314 RELEASE=trixie $CLI_MINIMAL $COMMON_CURRENT
build current/cli BOARD=tq-smarc2-tqma8mpxs RELEASE=trixie $CLI_MINIMAL $COMMON_CURRENT
build vendor/cli BOARD=mba62xx-tqma62xx RELEASE=trixie $CLI_MINIMAL $COMMON_VENDOR
build vendor/cli BOARD=mba67xx-tqma67xx RELEASE=trixie $CLI_MINIMAL $COMMON_VENDOR

# ══════════════════════════════════════════════════════════════════════════
# Phase 2: minimal images, edge branch
# ══════════════════════════════════════════════════════════════════════════
build edge/cli BOARD=mba93xxca-tqma93xx RELEASE=trixie $CLI_MINIMAL $COMMON_EDGE
build edge/cli BOARD=mba93xxla-mini RELEASE=trixie $CLI_MINIMAL $COMMON_EDGE
build edge/cli BOARD=mba8mpxl RELEASE=trixie $CLI_MINIMAL $COMMON_EDGE
build edge/cli BOARD=mba8mpxl-ras314 RELEASE=trixie $CLI_MINIMAL $COMMON_EDGE
build edge/cli BOARD=tq-smarc2-tqma8mpxs RELEASE=trixie $CLI_MINIMAL $COMMON_EDGE
build edge/cli BOARD=mba62xx-tqma62xx RELEASE=trixie $CLI_MINIMAL $COMMON_EDGE
build edge/cli BOARD=mba67xx-tqma67xx RELEASE=trixie $CLI_MINIMAL $COMMON_EDGE

# ══════════════════════════════════════════════════════════════════════════
# Phase 3: desktop images (nur mit --desktop)
# ══════════════════════════════════════════════════════════════════════════
if [[ ${WITH_DESKTOP} -eq 1 ]]; then
	build current/desktop BOARD=mba93xxca-tqma93xx RELEASE=trixie BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=xfce DESKTOP_APPGROUPS_SELECTED="" $COMMON_CURRENT
	build current/desktop BOARD=mba93xxla-mini RELEASE=trixie BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=xfce DESKTOP_APPGROUPS_SELECTED="" $COMMON_CURRENT
	build current/desktop BOARD=mba8mpxl RELEASE=noble BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=gnome DESKTOP_APPGROUPS_SELECTED="" $COMMON_CURRENT
	build current/desktop BOARD=mba8mpxl-ras314 RELEASE=noble BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=gnome DESKTOP_APPGROUPS_SELECTED="" $COMMON_CURRENT
	build current/desktop BOARD=tq-smarc2-tqma8mpxs RELEASE=noble BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=gnome DESKTOP_APPGROUPS_SELECTED="" $COMMON_CURRENT
	build vendor/desktop BOARD=mba62xx-tqma62xx RELEASE=trixie BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=xfce DESKTOP_APPGROUPS_SELECTED="" $COMMON_VENDOR
	build vendor/desktop BOARD=mba67xx-tqma67xx RELEASE=noble BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=gnome DESKTOP_APPGROUPS_SELECTED="" $COMMON_VENDOR
fi

# ── mbls1028a (wip, CLI only) ────────────────────────────────────────────────
#build current/cli BOARD=mbls1028a RELEASE=trixie $CLI_MINIMAL $COMMON_CURRENT

# ── Ergebnis ─────────────────────────────────────────────────────────────────
if [[ ${#RESULTS[@]} -eq 0 ]]; then
	echo "Kein Build ausgeführt — passt die Auswahl (--board '${ONLY_BOARD:-alle}', --branch '${ONLY_BRANCH:-alle}') zu keinem Eintrag der Matrix?" >&2
	exit 2
fi
echo
echo "════════ Ergebnis ════════"
printf '%-7s %-24s %-14s %s\n' STATUS BOARD BRANCH/VARIANTE DAUER
printf '%s\n' "${RESULTS[@]}"
echo "──────────────────────────"
echo "${#RESULTS[@]} Builds, ${FAILED} fehlgeschlagen."
[[ ${FAILED} -eq 0 ]]
