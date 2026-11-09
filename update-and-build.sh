#!/bin/bash
# update-and-build.sh — wöchentlicher Upstream-Abgleich der TQ-Branches
#
# Branch-Struktur:
#   armbian/main  ← upstream Armbian
#       ↑
#     main        ← TQ-Board-Configs
#       ↑
#     work        ← Support-Skripte, Zertifikate (dieses Skript)
#
# Befehle (jede Phase einzeln aufrufbar; die Entscheidung liegt zwischen fetch und rebase):
#   fetch     Upstream holen und eine Zusammenfassung der Änderungen erzeugen
#             (nach output/weekly/<datum>-summary.md). Ändert KEINE Branches.
#   rebase    Sicherungs-Tags setzen, main auf armbian/main und den aktuellen
#             Branch auf main rebasen, danach range-diff und Board-Validator.
#   build     build-tq-images.sh aufrufen (CLI-minimal; Optionen werden durchgereicht,
#             z. B. --desktop, --board mba8mpxl oder --branch edge).
#   all       fetch + rebase + build (Standard ohne Argument).
#
# Typischer Wochenablauf:
#   ./update-and-build.sh fetch                 # Zusammenfassung lesen, entscheiden
#   ./update-and-build.sh rebase                # nach deinem Okay
#   ./update-and-build.sh build                 # CLI-minimal für den Boot-Test
#   ./update-and-build.sh build --desktop       # bei Bedarf: Desktop für Anzeige-Tests
#
# Bei einem Rebase-Konflikt bricht das Skript ab und lässt den Rebase offen.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/output/logs"
SUMMARY_DIR="${SCRIPT_DIR}/output/weekly"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/build-${TIMESTAMP}.log"
UPSTREAM="armbian/main"
BASE="main"

mkdir -p "${LOG_DIR}" "${SUMMARY_DIR}"
cd "${SCRIPT_DIR}"

# ── Pfade, die dich betreffen (für Zusammenfassung und Zählung) ──────────────
PATHS_FAMILIES=(
	config/sources/families/imx8m.conf
	config/sources/families/imx93.conf
	config/sources/families/k3-tq.conf
	config/sources/families/include/imx8_common.inc
	'patch/kernel/archive/imx8m-*'
	'patch/kernel/archive/imx93-*'
	'patch/kernel/archive/k3-tq-*'
	patch/u-boot/u-boot-tqma
	patch/u-boot/u-boot-k3-tq
	patch/atf/atf-tq
	'config/kernel/linux-imx8m-*'
	'config/kernel/linux-*imx93-*'
	'config/kernel/linux-k3-tq-*'
)
PATHS_BOARDS=('config/boards/mba*' 'config/boards/tq-smarc*' 'config/boards/lavabms*')
PATHS_CORE=(
	lib
	extensions
	packages
	compile.sh
	config/common.conf
	config/sources/arm64.conf
	config/sources/families/include
	':(exclude)config/sources/families/include/imx8_common.inc'
)
PATHS_FOREIGN_BOARDS=(config/boards ':(exclude)config/boards/mba*' ':(exclude)config/boards/tq-smarc*' ':(exclude)config/boards/lavabms*')
PATHS_FOREIGN_PATCHES=(
	patch
	':(exclude)patch/kernel/archive/imx8m-*'
	':(exclude)patch/kernel/archive/imx93-*'
	':(exclude)patch/kernel/archive/k3-tq-*'
	':(exclude)patch/u-boot/u-boot-tqma'
	':(exclude)patch/u-boot/u-boot-k3-tq'
	':(exclude)patch/atf/atf-tq'
)
KERNEL_VERSION_FILES=(
	config/sources/families/imx8m.conf
	config/sources/families/imx93.conf
	config/sources/families/k3-tq.conf
	config/sources/families/include/imx8_common.inc
)

# ── Farben ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info() { echo -e "${GREEN}[INFO]${NC}  $*" | tee -a "${LOG_FILE}"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*" | tee -a "${LOG_FILE}"; }
error() { echo -e "${RED}[ERROR]${NC} $*" | tee -a "${LOG_FILE}"; }

usage() {
	sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
}

# ══════════════════════════════════════════════════════════════════════════════
# Phase 1: fetch + Zusammenfassung
# ══════════════════════════════════════════════════════════════════════════════

# Anzahl geänderter Dateien zwischen BASE und UPSTREAM für die übergebenen Pfade
count_files() {
	git diff --name-only "${BASE}...${UPSTREAM}" -- "$@" | wc -l
}

# list_commits <Titel> <Pfade...> — Commits aus BASE..UPSTREAM, die diese Pfade berühren
list_commits() {
	local title="$1"
	shift
	local lines total
	lines="$(git log --no-merges --format='- %h %ad %s' --date=short "${BASE}..${UPSTREAM}" -- "$@")"
	echo "## ${title}"
	echo
	if [[ -z "${lines}" ]]; then
		echo "(keine)"
		echo
		return 0
	fi
	total="$(wc -l <<<"${lines}")"
	sed -n '1,40p' <<<"${lines}"
	if [[ "${total}" -gt 40 ]]; then
		echo "- … und $((total - 40)) weitere (git log ${BASE}..${UPSTREAM} -- <Pfad>)"
	fi
	echo
}

# Simuliert das Neuaufsetzen der Commits aus UPSTREAM..<branch> auf UPSTREAM.
# Nutzt dieselbe Merge-Engine wie git rebase, arbeitet nur im Objektspeicher und
# ändert weder Branches noch Index noch Arbeitsbaum.
predict_conflicts() {
	local branch="$1"
	local tree commit out rc n=0 subj files
	tree="$(git rev-parse "${UPSTREAM}^{tree}")"
	while read -r commit; do
		n=$((n + 1))
		subj="$(git log -1 --format='%h %s' "${commit}")"
		rc=0
		out="$(LC_ALL=C git merge-tree --write-tree --name-only --merge-base="${commit}^" "${tree}" "${commit}" 2>&1)" || rc=$?
		if [[ ${rc} -eq 0 ]]; then
			echo "- ok: ${subj}"
			tree="$(head -1 <<<"${out}")"
		elif [[ ${rc} -eq 1 ]]; then
			echo "- **KONFLIKT:** ${subj}"
			# Zeile 1 ist die Baum-ID, danach folgen die betroffenen Dateien, dann Meldungen
			files="$(sed -n '2,$p' <<<"${out}" | grep -v '^$' | grep -v '^Auto-merging\|^CONFLICT' || true)"
			# shellcheck disable=SC2001
			sed 's/^/    - /' <<<"${files}"
			echo "- (ab hier nicht mehr vorhersagbar, weil spätere Commits auf diesem aufbauen)"
			return 0
		else
			echo "- **Simulation fehlgeschlagen** (git merge-tree rc=${rc}) bei ${subj}"
			# shellcheck disable=SC2001
			sed 's/^/    /' <<<"${out}" | sed -n '1,5p'
			return 0
		fi
	done < <(git rev-list --reverse "${UPSTREAM}..${branch}")
	if [[ ${n} -eq 0 ]]; then
		echo "- Keine eigenen Commits auf ${branch} gegenüber ${UPSTREAM}."
	else
		echo
		echo "Alle ${n} Commits lassen sich voraussichtlich konfliktfrei neu aufsetzen."
	fi
}

write_summary() {
	local n branch kv
	n="$(git rev-list --count "${BASE}..${UPSTREAM}")"
	branch="$(git rev-parse --abbrev-ref HEAD)"

	echo "# Armbian-Upstream-Abgleich $(date +%Y-%m-%d)"
	echo
	echo "- ${UPSTREAM}: $(git log -1 --format='%h (%ad)' --date=short "${UPSTREAM}")"
	echo "- ${BASE}: $(git log -1 --format='%h (%ad)' --date=short "${BASE}")"
	echo "- Aktueller Branch: ${branch}"
	echo "- Neue Upstream-Commits: ${n}"
	if [[ "${n}" -eq 0 ]]; then
		echo
		echo "Nichts Neues."
		return 0
	fi
	echo "- Umfang: $(git diff --shortstat "${BASE}...${UPSTREAM}")"
	echo
	echo "## Geänderte Dateien nach Bereich"
	echo
	echo "| Bereich | Dateien |"
	echo "|---|---|"
	echo "| Deine Familien (imx8m, imx93, k3-tq: Configs, Patches, U-Boot, ATF) | $(count_files "${PATHS_FAMILIES[@]}") |"
	echo "| Deine Boards (mba*, tq-smarc*, lavabms*) | $(count_files "${PATHS_BOARDS[@]}") |"
	echo "| Framework-Kern (lib, extensions, packages, common, Familien-Includes) | $(count_files "${PATHS_CORE[@]}") |"
	echo "| Boards anderer Hersteller | $(count_files "${PATHS_FOREIGN_BOARDS[@]}") |"
	echo "| Patches anderer Familien | $(count_files "${PATHS_FOREIGN_PATCHES[@]}") |"
	echo
	echo "## Kernel-Versionswechsel in deinen Familien"
	echo
	kv="$(git diff -U0 "${BASE}...${UPSTREAM}" -- "${KERNEL_VERSION_FILES[@]}" | grep -E '^[+-].*KERNEL_MAJOR_MINOR' || true)"
	if [[ -z "${kv}" ]]; then
		echo "(keine)"
	else
		echo '```'
		echo "${kv}"
		echo '```'
	fi
	echo
	list_commits "Commits an deinen Boards und Familien" "${PATHS_BOARDS[@]}" "${PATHS_FAMILIES[@]}"
	list_commits "Commits am Framework-Kern" "${PATHS_CORE[@]}"
	echo "## Konfliktvorhersage für ${branch} (Simulation, ändert nichts)"
	echo
	predict_conflicts "${branch}"
	echo
	echo "Nächster Schritt, wenn du es übernehmen willst: ./update-and-build.sh rebase"
}

cmd_fetch() {
	info "Hole Upstream-Änderungen (git fetch --no-tags armbian)..."
	# --no-tags: Upstream hat hunderte alte Tags, die weder gebraucht werden noch
	# die Ausgabe zumüllen sollen.
	if ! git fetch --no-tags armbian 2>&1 | tee -a "${LOG_FILE}"; then
		error "git fetch fehlgeschlagen — Netzwerk oder Remote prüfen."
		exit 1
	fi
	local out
	out="${SUMMARY_DIR}/$(date +%Y-%m-%d)-summary.md"
	write_summary | tee "${out}"
	info "Zusammenfassung gespeichert: ${out}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Phase 2: rebase
# ══════════════════════════════════════════════════════════════════════════════
rebase_branch() {
	local branch="$1" onto="$2"
	local behind
	behind="$(git rev-list "${branch}..${onto}" --count)"
	if [[ "${behind}" -eq 0 ]]; then
		info "${branch} ist bereits aktuell."
		return 0
	fi
	info "Rebase ${branch} auf ${onto} (${behind} neue Commits)..."
	git checkout "${branch}" 2>&1 | tee -a "${LOG_FILE}"
	if ! git rebase "${onto}" 2>&1 | tee -a "${LOG_FILE}"; then
		error "Rebase-Konflikt auf ${branch}! Manuell lösen:"
		error "  cd ${SCRIPT_DIR}"
		error "  git status"
		error "  # Konflikte beheben, dann: git rebase --continue"
		error "  # Abbrechen und alles zurück: git rebase --abort"
		error "  # Commit bewusst fallenlassen: git rebase --skip"
		error "  # Danach NICHT 'rebase' erneut starten (der Vorher-Nachher-Vergleich ginge verloren), sondern:"
		error "  #   git range-diff <pre-update-Tag>..<pre-update-Tag> ${onto}..${branch}   (Tags: siehe oben im Log)"
		error "  #   ./update-and-build.sh build"
		exit 1
	fi
	info "${branch} erfolgreich rebased. HEAD: $(git rev-parse --short HEAD)"
}

cmd_rebase() {
	local branch old_main old_branch tag_prefix rd changed
	branch="$(git rev-parse --abbrev-ref HEAD)"
	if [[ "${branch}" == "HEAD" ]]; then
		error "Detached HEAD — erst auf deinen Arbeitsbranch wechseln."
		exit 1
	fi
	if [[ "${branch}" == "${BASE}" ]]; then
		error "Du stehst auf ${BASE}. Bitte auf den Arbeitsbranch (z. B. work) wechseln."
		exit 1
	fi
	if [[ -d "$(git rev-parse --git-path rebase-merge)" || -d "$(git rev-parse --git-path rebase-apply)" ]]; then
		error "Ein Rebase läuft noch — erst beenden (git rebase --continue oder --abort)."
		exit 1
	fi
	if ! git diff --quiet || ! git diff --cached --quiet; then
		error "Arbeitsbaum nicht sauber — erst committen oder stashen:"
		git status --short | tee -a "${LOG_FILE}"
		exit 1
	fi

	old_main="$(git rev-parse "${BASE}")"
	old_branch="$(git rev-parse HEAD)"

	# Sicherung als Tags (kein Branch): Rückweg über git reset --hard <tag>
	tag_prefix="pre-update-${TIMESTAMP}"
	git tag "${tag_prefix}-${BASE}" "${old_main}"
	git tag "${tag_prefix}-${branch//\//_}" "${old_branch}"
	info "Sicherungs-Tags: ${tag_prefix}-${BASE} (${old_main:0:9}), ${tag_prefix}-${branch//\//_} (${old_branch:0:9})"

	rebase_branch "${BASE}" "${UPSTREAM}"
	rebase_branch "${branch}" "${BASE}"
	git checkout "${branch}" 2>&1 | tee -a "${LOG_FILE}"

	# Haben sich deine Commits inhaltlich verändert? '=' = unverändert, '!' = verändert
	info "range-diff ${branch} (vorher → nachher; '=' bedeutet: Inhalt unverändert):"
	rd="$(git range-diff "${old_main}..${old_branch}" "${BASE}..${branch}" 2>&1 || true)"
	echo "${rd}" | tee -a "${LOG_FILE}"
	changed="$(grep -cE '^[0-9-]+:[[:space:]]+[0-9a-f-]+ [!<>] ' <<<"${rd}" || true)"
	if [[ "${changed}" -gt 0 ]]; then
		warn "${changed} Commit(s) haben sich beim Rebase inhaltlich verändert (!, <, >) — vor dem Build ansehen."
	else
		info "Alle Commits inhaltlich unverändert."
	fi

	# Billiges Gate vor dem teuren Build: Board-Konfigurationen validieren
	local board_files=() f
	for f in config/boards/mba*.conf config/boards/tq-smarc*.conf config/boards/lavabms*.conf; do
		[[ -e "${f}" ]] && board_files+=("${f}")
	done
	info "Validiere ${#board_files[@]} Board-Konfigurationen..."
	if ! tools/validate-board-config.py "${board_files[@]}" 2>&1 | tee -a "${LOG_FILE}"; then
		error "Board-Validator meldet Fehler — nicht bauen, erst beheben."
		exit 1
	fi
	info "Rebase abgeschlossen. Nächster Schritt: ./update-and-build.sh build [--desktop] [--board NAME]"
}

# ══════════════════════════════════════════════════════════════════════════════
# Phase 3: build
# ══════════════════════════════════════════════════════════════════════════════
cmd_build() {
	local build_start build_end marker rc=0 image_count
	info "Starte Build der TQ-Boards (build-tq-images.sh ${*:-ohne Optionen = CLI-minimal})..."
	build_start=$(date +%s)
	marker=$(mktemp "${LOG_DIR}/.build-marker.XXXXXX")
	touch "${marker}"

	"${SCRIPT_DIR}/build-tq-images.sh" "$@" 2>&1 | tee -a "${LOG_FILE}" || rc=${PIPESTATUS[0]}

	build_end=$(date +%s)
	info "──────────────────────────────────────────"
	info "Build beendet nach $(((build_end - build_start) / 60)) Minuten (Exit-Code ${rc})."
	info "Images: ${SCRIPT_DIR}/output/images/"

	image_count=$(find "${SCRIPT_DIR}/output/images" -name "*.img" -newer "${marker}" 2>/dev/null | wc -l)
	info "Neue Images: ${image_count}"
	if [[ ${image_count} -gt 0 ]]; then
		find "${SCRIPT_DIR}/output/images" -name "*.img" -newer "${marker}" 2>/dev/null |
			sort | sed 's|.*/||' | while read -r f; do
			info "  ✓ ${f}"
		done
	fi
	rm -f "${marker}"

	info "Log gespeichert: ${LOG_FILE}"
	info "Boot-Test auf der Hardware: doc/tests/run-tests.sh (--list zeigt die Matrix)"
	return "${rc}"
}

cmd_all() {
	cmd_fetch
	cmd_rebase
	cmd_build "$@"
}

# ══════════════════════════════════════════════════════════════════════════════
CMD="${1:-all}"
if [[ $# -gt 0 ]]; then
	shift
fi

info "update-and-build ${CMD} — $(date)"
info "Log: ${LOG_FILE}"

case "${CMD}" in
	fetch) cmd_fetch ;;
	rebase) cmd_rebase ;;
	build) cmd_build "$@" ;;
	all) cmd_all "$@" ;;
	-h | --help | help) usage ;;
	*)
		error "Unbekannter Befehl: ${CMD}"
		usage
		exit 2
		;;
esac
