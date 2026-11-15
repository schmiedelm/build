#!/usr/bin/env bash
# Pack moonlight-qt (built against /opt/kodi-ffmpeg) into moonlight-vpu_*.deb.
#
# Runs in the cross container (cross/build-in-container.sh moonlight-deb, DEB_HOST_ARCH=arm64)
# after the moonlight step installed /opt/moonlight.
# Contents: /opt/moonlight, /usr/bin/moonlight-vpu, moonlight-vpu.service (stops Kodi, starts
# Kodi again on exit), sudoers rule for user kodi, Kodi add-on script.moonlight-vpu.
#
# Usage: pack-moonlight-deb.sh [output-dir]      (default: ./debs)
set -euo pipefail

MOONLIGHT_VERSION="6.2.0-tq3"
FFMPEG_VERSION="9.0.2-tq2"
ARCH="${DEB_HOST_ARCH:-$(dpkg --print-architecture)}"
TRIPLET="${DEB_HOST_GNU_TYPE:-}"
OUT="$(realpath -m "${1:-./debs}")"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

[[ -x /opt/moonlight/bin/moonlight ]] || { echo "missing /opt/moonlight" >&2; exit 1; }
mkdir -p "${OUT}"

stage="${WORK}/moonlight"
mkdir -p "${stage}/opt" "${stage}/DEBIAN" "${stage}/usr/bin" "${stage}/usr/lib/systemd/system" \
	"${stage}/etc/sudoers.d" "${stage}/etc/default"
tar -C / -cf - opt/moonlight | tar -C "${stage}" -xf -
"${TRIPLET:+${TRIPLET}-}strip" --strip-unneeded "${stage}/opt/moonlight/bin/moonlight"

cat > "${stage}/usr/bin/moonlight-vpu" << 'EOF'
#!/bin/sh
# Start Moonlight on the console (Qt eglfs/KMS, SDL KMSDRM), decoding via the Hantro VPU.
# Normally started by moonlight-vpu.service. Stop kodi-vpu.service first: only one DRM master.
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-eglfs}"
export QT_QPA_EGLFS_INTEGRATION="${QT_QPA_EGLFS_INTEGRATION:-eglfs_kms}"
export QT_QPA_EGLFS_KMS_ATOMIC="${QT_QPA_EGLFS_KMS_ATOMIC:-1}"
# Qt takes the first DRM card; on i.MX8MP that can be etnaviv (no display). Use the card with
# a connector (LCDIF/HDMI). No hardware cursor: LCDIF has no cursor plane.
if [ -z "${QT_QPA_EGLFS_KMS_CONFIG}" ]; then
	card=
	for c in /sys/class/drm/card[0-9]*-*; do
		[ -e "${c}" ] || continue
		n="${c##*/}"
		card="/dev/dri/${n%%-*}"
		break
	done
	if [ -n "${card}" ]; then
		cfg="${XDG_RUNTIME_DIR:-/tmp}/moonlight-vpu-kms.json"
		printf '{ "device": "%s", "hwcursor": false }\n' "${card}" > "${cfg}"
		export QT_QPA_EGLFS_KMS_CONFIG="${cfg}"
		echo "moonlight-vpu: KMS device ${card}" >&2
	fi
fi
exec /opt/moonlight/bin/moonlight "$@"
EOF
chmod 0755 "${stage}/usr/bin/moonlight-vpu"

cat > "${stage}/etc/default/moonlight-vpu" << 'EOF'
# Environment for moonlight-vpu.service.
# SDL audio via ALSA on the HDMI card (list devices with: aplay -L).
SDL_AUDIODRIVER=alsa
AUDIODEV=plughw:CARD=audiohdmi,DEV=0
# Debug output of Moonlight and SDL in the journal.
#QT_LOGGING_RULES=*.debug=true
EOF

# Replaces Kodi on tty1. Starting it stops kodi-vpu.service (Conflicts + After);
# on exit kodi-vpu.service starts again.
cat > "${stage}/usr/lib/systemd/system/moonlight-vpu.service" << 'EOF'
[Unit]
Description=Moonlight game streaming (KMS, Hantro VPU)
Conflicts=kodi-vpu.service getty@tty1.service
After=kodi-vpu.service systemd-user-sessions.service network-online.target sound.target

[Service]
User=kodi
Group=kodi
PAMName=login
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal
EnvironmentFile=-/etc/default/moonlight-vpu
ExecStart=/usr/bin/moonlight-vpu
ExecStopPost=+/usr/bin/systemctl --no-block start kodi-vpu.service
TimeoutStopSec=15
EOF

cat > "${stage}/etc/sudoers.d/moonlight-vpu" << 'EOF'
# Kodi add-on script.moonlight-vpu starts Moonlight in place of Kodi.
kodi ALL=(root) NOPASSWD: /usr/bin/systemctl start --no-block moonlight-vpu.service
EOF
chmod 0440 "${stage}/etc/sudoers.d/moonlight-vpu"

addon="${stage}/opt/kodi-22/share/kodi/addons/script.moonlight-vpu"
mkdir -p "${addon}"
cat > "${addon}/addon.xml" << EOF
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<addon id="script.moonlight-vpu" name="Moonlight" version="${MOONLIGHT_VERSION%-*}" provider-name="TQ-Systems">
  <requires>
    <import addon="xbmc.python" version="3.0.0"/>
  </requires>
  <extension point="xbmc.python.script" library="default.py">
    <provides>executable game</provides>
  </extension>
  <extension point="xbmc.addon.metadata">
    <summary lang="en_GB">Game streaming from a PC (Sunshine/Steam)</summary>
    <summary lang="de_DE">Spiele-Streaming vom PC (Sunshine/Steam)</summary>
    <description lang="en_GB">Stops Kodi and starts Moonlight. Kodi starts again when Moonlight exits.</description>
    <description lang="de_DE">Beendet Kodi und startet Moonlight. Nach dem Beenden von Moonlight startet Kodi wieder.</description>
    <platform>linux</platform>
    <license>GPL-3.0-or-later</license>
    <assets>
      <icon>icon.svg</icon>
    </assets>
  </extension>
</addon>
EOF
cat > "${addon}/default.py" << 'EOF'
import subprocess

import xbmc

xbmc.log("script.moonlight-vpu: starting moonlight-vpu.service", xbmc.LOGINFO)
rc = subprocess.call(["sudo", "-n", "/usr/bin/systemctl", "start", "--no-block", "moonlight-vpu.service"])
if rc != 0:
    xbmc.log("script.moonlight-vpu: systemctl failed, rc=%d" % rc, xbmc.LOGERROR)
    xbmc.executebuiltin("Notification(Moonlight,systemctl failed (rc=%d),5000)" % rc)
EOF
cp "${stage}/opt/moonlight/share/icons/hicolor/scalable/apps/moonlight.svg" "${addon}/icon.svg"

printf '/etc/default/moonlight-vpu\n/etc/sudoers.d/moonlight-vpu\n' > "${stage}/DEBIAN/conffiles"

# Runtime libraries via dpkg-shlibdeps; Qt plugins and QML modules are not ELF dependencies.
mkdir -p "${WORK}/shl/debian"
printf 'Source: x\n\nPackage: x\nArchitecture: any\n' > "${WORK}/shl/debian/control"
deps="$(cd "${WORK}/shl" && dpkg-shlibdeps --ignore-missing-info -O -l/opt/kodi-ffmpeg/lib \
	-e"${stage}/opt/moonlight/bin/moonlight" | sed -n 's/^shlibs:Depends=//p')"
cat > "${stage}/DEBIAN/control" << EOF
Package: moonlight-vpu
Version: ${MOONLIGHT_VERSION}
Architecture: ${ARCH}
Maintainer: TQ-Systems <noreply@invalid>
Section: games
Priority: optional
Depends: kodi-ffmpeg-v4l2request (= ${FFMPEG_VERSION}), kodi-vpu (>= 22.0~rc2-tq8), sudo, libqt6opengl6,
 qml6-module-qtquick, qml6-module-qtquick-controls, qml6-module-qtquick-templates,
 qml6-module-qtquick-layouts, qml6-module-qtquick-window, qml6-module-qtqml-workerscript,
 ${deps}
Description: Moonlight game streaming client decoding via the Hantro VPU
 moonlight-qt built against kodi-ffmpeg-v4l2request (DRM PRIME), installed under
 /opt/moonlight. Start from Kodi with the add-on script.moonlight-vpu, or with
 systemctl start moonlight-vpu.service. Host: Sunshine on the PC.
EOF

dpkg-deb --root-owner-group -Zxz -b "${stage}" "${OUT}"
f="${OUT}/moonlight-vpu_${MOONLIGHT_VERSION}_${ARCH}.deb"
dpkg-deb -f "${f}" Package Version Depends
ls -l "${f}"
