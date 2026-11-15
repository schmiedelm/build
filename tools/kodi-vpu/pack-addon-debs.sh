#!/usr/bin/env bash
# Pack Kodi 22 add-ons into one .deb each, installed under /opt/kodi-22.
#
# Runs in the cross container (cross/build-in-container.sh addons-deb, DEB_HOST_ARCH=arm64)
# after the addons step filled /opt/kodi-addons. Python add-ons come as zip from /work/src.
# Kodi lists the add-ons as disabled; enable them under Add-ons -> My add-ons.
#
# Usage: pack-addon-debs.sh [output-dir]      (default: ./debs)
set -euo pipefail

TQ_REV=tq1
KODI_DEP="kodi-vpu (>= 22.0~rc2-tq8)"
# Python add-ons: zip file in /work/src
PY_ADDONS=(script.module.inputstreamhelper-0.8.6.zip)
# Extra dependencies per add-on (Debian package names)
declare -A EXTRA_DEPS=(
	[pvr.zattoo]="kodi-vpu-inputstream-adaptive, kodi-vpu-script-module-inputstreamhelper"
)
SRC=/work/src
ADDONS=/opt/kodi-addons
ARCH="${DEB_HOST_ARCH:-$(dpkg --print-architecture)}"
OUT="$(realpath -m "${1:-./debs}")"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${OUT}"

pkg_name() { echo "kodi-vpu-${1//./-}"; }
addon_version() { python3 -I -c 'import sys,xml.etree.ElementTree as E;print(E.parse(sys.argv[1]).getroot().get("version"))' "$1"; }

# $1 add-on id, $2 stage dir, $3 architecture, $4 depends
build_deb() {
	local id="$1" stage="$2" arch="$3" deps="$4" ver
	ver="$(addon_version "${stage}/opt/kodi-22/share/kodi/addons/${id}/addon.xml")"
	[[ -n ${ver} ]] || { echo "no version in ${id}/addon.xml" >&2; exit 1; }
	mkdir -p "${stage}/DEBIAN"
	cat > "${stage}/DEBIAN/control" << EOF
Package: $(pkg_name "${id}")
Version: ${ver}-${TQ_REV}
Architecture: ${arch}
Maintainer: TQ-Systems <noreply@invalid>
Section: video
Priority: optional
Depends: ${deps}
Description: Kodi 22 add-on ${id} for kodi-vpu
 Kodi add-on ${id} ${ver}, built for Kodi 22 and installed under
 /opt/kodi-22. Enable it in Kodi under Add-ons, My add-ons.
EOF
	dpkg-deb --root-owner-group -Zxz -b "${stage}" "${OUT}"
}

# Binary add-ons
for dir in "${ADDONS}"/share/kodi/addons/*; do
	id="${dir##*/}"
	stage="${WORK}/${id}"
	mkdir -p "${stage}/opt/kodi-22/lib/kodi/addons" "${stage}/opt/kodi-22/share/kodi/addons"
	cp -a "${dir}" "${stage}/opt/kodi-22/share/kodi/addons/"
	cp -a "${ADDONS}/lib/kodi/addons/${id}" "${stage}/opt/kodi-22/lib/kodi/addons/"
	find "${stage}" -name '*.so*' -type f -exec "${DEB_HOST_GNU_TYPE:+${DEB_HOST_GNU_TYPE}-}strip" --strip-unneeded {} +
	mkdir -p "${WORK}/shl/debian"
	printf 'Source: x\n\nPackage: x\nArchitecture: any\n' > "${WORK}/shl/debian/control"
	shl="$(cd "${WORK}/shl" && dpkg-shlibdeps --ignore-missing-info -O \
		$(find "${stage}" -name '*.so*' -type f -printf '-e%p ') | sed -n 's/^shlibs:Depends=//p')"
	deps="${KODI_DEP}, ${shl}"
	[[ -n ${EXTRA_DEPS[${id}]:-} ]] && deps="${deps}, ${EXTRA_DEPS[${id}]}"
	build_deb "${id}" "${stage}" "${ARCH}" "${deps}"
done

# Python add-ons
for zip in "${PY_ADDONS[@]}"; do
	stage="${WORK}/py-${zip%.zip}"
	mkdir -p "${stage}/opt/kodi-22/share/kodi/addons"
	python3 -I -m zipfile -e "${SRC}/${zip}" "${stage}/opt/kodi-22/share/kodi/addons/"
	id="$(ls "${stage}/opt/kodi-22/share/kodi/addons")"
	build_deb "${id}" "${stage}" all "${KODI_DEP}"
done

for f in "${OUT}"/kodi-vpu-*.deb; do
	echo "== ${f##*/}"
	dpkg-deb -f "${f}" Package Version Architecture Depends
done
