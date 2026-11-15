#!/usr/bin/env bash
# Pack Kodi 22 + ffmpeg 9.0.2 (v4l2-request) into two .deb files.
#
# Runs on the board (native build) or in the cross container (cross/build-in-container.sh debs,
# with DEB_HOST_ARCH=arm64), after both trees are installed:
#   /opt/kodi-ffmpeg  ffmpeg 9.0.2 + LibreELEC v4l2-request patch
#                     (configure: --prefix=/opt/kodi-ffmpeg --enable-shared --disable-static
#                      --enable-gpl --enable-libdrm --enable-libudev --enable-v4l2-request
#                      --enable-v4l2-m2m --disable-doc --disable-debug)
#   /opt/kodi-22      Kodi 22.0rc2 (cmake: CORE_PLATFORM_NAME=gbm, APP_RENDER_SYSTEM=gles,
#                     ENABLE_INTERNAL_FFMPEG=OFF, FFMPEG_PATH=/opt/kodi-ffmpeg,
#                     ENABLE_INTERNAL_{CROSSGUID,LIBDVD,SWIG,DATE,KISSFFT,TZDATA}=ON,
#                     ENABLE_VAAPI=OFF, ENABLE_VDPAU=OFF, CMAKE_INSTALL_PREFIX=/opt/kodi-22)
# Kodi is linked with RPATH to /opt/kodi-ffmpeg/lib, so both trees stay at their
# build prefix and nothing is rebuilt.
#
# Usage: pack-debs.sh [output-dir]      (default: ./debs)
set -euo pipefail

FFMPEG_VERSION="9.0.2-tq2"
KODI_VERSION="22.0~rc2-tq8"
ARCH="${DEB_HOST_ARCH:-$(dpkg --print-architecture)}"
OUT="$(realpath -m "${1:-./debs}")"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

for d in /opt/kodi-ffmpeg /opt/kodi-22; do
	[[ -d ${d} ]] || { echo "missing ${d}" >&2; exit 1; }
done
command -v dpkg-shlibdeps > /dev/null || { echo "dpkg-dev is missing: apt-get install -y dpkg-dev" >&2; exit 1; }
mkdir -p "${OUT}"

# Runtime dependencies from the ELF files of a tree. Libraries inside /opt are
# not owned by any package, so --ignore-missing-info; the ffmpeg dependency is
# added by hand for the Kodi package.
shlibs_depends() {
	local tree="$1"
	shift
	local -a elfs=()
	local f
	while IFS= read -r -d '' f; do
		[[ "$(head -c4 "${f}" | tr -d '\0')" == $'\x7f'ELF ]] && elfs+=("-e${f}")
	done < <(find "${tree}" -type f -print0)
	mkdir -p "${WORK}/shl/debian"
	printf 'Source: x\n\nPackage: x\nArchitecture: any\n' > "${WORK}/shl/debian/control"
	(cd "${WORK}/shl" && dpkg-shlibdeps --ignore-missing-info -O "$@" "${elfs[@]}") \
		| sed -n 's/^shlibs:Depends=//p'
}

# 1) ffmpeg: libraries and the ffmpeg/ffprobe CLI (replaces the old Kwiboo extension), no headers
stage="${WORK}/ffmpeg"
mkdir -p "${stage}/opt" "${stage}/DEBIAN"
tar -C / --exclude=opt/kodi-ffmpeg/include --exclude=opt/kodi-ffmpeg/lib/pkgconfig -cf - opt/kodi-ffmpeg | tar -C "${stage}" -xf -
mkdir -p "${stage}/usr/bin"
ln -s /opt/kodi-ffmpeg/bin/ffmpeg "${stage}/usr/bin/ffmpeg-v4l2request"
ln -s /opt/kodi-ffmpeg/bin/ffprobe "${stage}/usr/bin/ffprobe-v4l2request"
ff_deps="$(shlibs_depends "${stage}/opt/kodi-ffmpeg" -l"${stage}/opt/kodi-ffmpeg/lib")"
cat > "${stage}/DEBIAN/control" << EOF
Package: kodi-ffmpeg-v4l2request
Version: ${FFMPEG_VERSION}
Architecture: ${ARCH}
Maintainer: TQ-Systems <noreply@invalid>
Section: video
Priority: optional
Depends: ${ff_deps}
Description: ffmpeg 9.0.2 with V4L2 request hwaccel (Hantro G1/G2)
 ffmpeg libraries and CLI built with --enable-v4l2-request, installed under
 /opt/kodi-ffmpeg for kodi-vpu. The CLI is linked as ffmpeg-v4l2request.
EOF

# 2) Kodi
stage="${WORK}/kodi"
mkdir -p "${stage}/opt" "${stage}/DEBIAN" "${stage}/usr/bin"
tar -C / -cf - opt/kodi-22 | tar -C "${stage}" -xf -
cat > "${stage}/usr/bin/kodi-vpu" << 'EOF'
#!/bin/sh
# Start Kodi on the console (GBM/GLES, no desktop). The build sets the DRM PRIME
# decoder on by default (cross/patches/0001-*).
export KODI_HOME=/opt/kodi-22/share/kodi
exec /opt/kodi-22/lib/kodi/kodi-gbm --windowing=gbm --standalone "$@"
EOF
chmod 0755 "${stage}/usr/bin/kodi-vpu"
# Autostart on tty1 as user kodi. Not enabled by the package: systemctl enable kodi-vpu.service
mkdir -p "${stage}/usr/lib/systemd/system"
cat > "${stage}/usr/lib/systemd/system/kodi-vpu.service" << 'EOF'
[Unit]
Description=Kodi (GBM, Hantro VPU)
After=systemd-user-sessions.service network-online.target sound.target
Wants=network-online.target
Conflicts=getty@tty1.service
Wants=kodi-vpu-cec-watch.service

[Service]
User=kodi
Group=kodi
PAMName=login
TTYPath=/dev/tty1
StandardInput=tty
StandardOutput=journal
StandardError=journal
ExecStart=/usr/bin/kodi-vpu
Restart=on-failure
RestartSec=5
TimeoutStopSec=15

[Install]
WantedBy=multi-user.target
EOF
# CEC watchdog: restarts Kodi when libCEC ends up unregistered (LA 15). Workaround for
# unreliable CEC transmits on i.MX8MP (polls end with an error instead of a NACK).
# Not PartOf kodi-vpu.service: a Kodi restart must not reset the restart counter.
mkdir -p "${stage}/usr/lib/kodi-vpu"
cat > "${stage}/usr/lib/kodi-vpu/cec-watch" << 'EOF'
#!/bin/sh
# Restart kodi-vpu.service while libCEC has only the unregistered address (mask 0x8000)
# and the physical address is valid. At most MAX restarts in a row.
DEV=/dev/cec0
MAX="${KODI_CEC_MAX_RESTARTS:-5}"
SETTLE="${KODI_CEC_SETTLE:-25}"
INTERVAL="${KODI_CEC_INTERVAL:-60}"
restarts=0

unregistered() {
	st="$(cec-ctl -d "${DEV}" 2> /dev/null)" || return 1
	echo "${st}" | grep -q "Physical Address *: *f.f.f.f" && return 1
	echo "${st}" | grep -qi "Logical Address Mask *: *0x8000"
}

sleep "${SETTLE}"
while :; do
	if [ -e "${DEV}" ] && systemctl -q is-active kodi-vpu.service; then
		if unregistered; then
			if [ "${restarts}" -lt "${MAX}" ]; then
				restarts=$((restarts + 1))
				echo "CEC unregistered, restarting Kodi (${restarts}/${MAX})"
				systemctl restart kodi-vpu.service
				sleep "${SETTLE}"
				continue
			fi
		else
			restarts=0
		fi
	fi
	sleep "${INTERVAL}"
done
EOF
chmod 0755 "${stage}/usr/lib/kodi-vpu/cec-watch"
cat > "${stage}/usr/lib/systemd/system/kodi-vpu-cec-watch.service" << 'EOF'
[Unit]
Description=Kodi CEC watchdog (restart Kodi when CEC registration failed)
After=kodi-vpu.service

[Service]
ExecStart=/usr/lib/kodi-vpu/cec-watch
Restart=on-failure
EOF
# ALSA default device: HDMI card audio-hdmi (id audiohdmi). Kodi picks "@" (default) on first start,
# Moonlight (SDL) uses default as well. plug converts formats the HDMI driver rejects.
mkdir -p "${stage}/etc/alsa/conf.d"
cat > "${stage}/etc/alsa/conf.d/50-kodi-vpu-hdmi.conf" << 'EOF'
# kodi-vpu: HDMI as ALSA default device.
pcm.!default {
	type plug
	slave.pcm "hw:CARD=audiohdmi,DEV=0"
}
ctl.!default {
	type hw
	card audiohdmi
}
EOF
echo /etc/alsa/conf.d/50-kodi-vpu-hdmi.conf > "${stage}/DEBIAN/conffiles"
cat > "${stage}/DEBIAN/postinst" << 'EOF'
#!/bin/sh
# System user for kodi-vpu.service; groups for DRM, VPU, input and ALSA.
set -e
if [ "$1" = configure ]; then
	if ! getent passwd kodi > /dev/null; then
		useradd --system --user-group --create-home --home-dir /var/lib/kodi \
			--shell /usr/sbin/nologin --comment "Kodi" kodi
	fi
	for g in video render input audio; do
		getent group "$g" > /dev/null && usermod -aG "$g" kodi
	done
fi
exit 0
EOF
chmod 0755 "${stage}/DEBIAN/postinst"
kodi_deps="$(shlibs_depends "${stage}/opt/kodi-22" -l"${stage}/opt/kodi-22/lib" -l/opt/kodi-ffmpeg/lib)"
cat > "${stage}/DEBIAN/control" << EOF
Package: kodi-vpu
Version: ${KODI_VERSION}
Architecture: ${ARCH}
Maintainer: TQ-Systems <noreply@invalid>
Section: video
Priority: optional
Depends: kodi-ffmpeg-v4l2request (= ${FFMPEG_VERSION}), v4l-utils, ${kodi_deps}
Description: Kodi 22 (GBM/GLES) decoding via the Hantro VPU (DRM PRIME)
 Kodi 22.0rc2 built against kodi-ffmpeg-v4l2request, installed under /opt/kodi-22.
 Start with kodi-vpu from a console without a desktop session, or enable
 kodi-vpu.service (runs as user kodi on tty1).
EOF

for p in ffmpeg kodi; do
	dpkg-deb --root-owner-group -Zxz -b "${WORK}/${p}" "${OUT}"
done
ls -l "${OUT}"
for f in "${OUT}"/*.deb; do
	echo "== ${f##*/}"
	dpkg-deb -f "${f}" Package Version Architecture Depends
done
