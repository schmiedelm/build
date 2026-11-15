#!/usr/bin/env bash
# Cross-build ffmpeg 9.0.2 (v4l2-request) and Kodi 22 for arm64 trixie.
# Runs inside kodi-cross-arm64:trixie. /work holds src/, /opt is the output.
# Usage: build-in-container.sh [ffmpeg|tools|kodi|debs|all]   (default: all)
set -euo pipefail

STEP="${1:-all}"
JOBS="$(nproc)"
SRC=/work/src
BUILD=/work/build
TRIPLET=aarch64-linux-gnu
KODI_SRC="${BUILD}/xbmc-22.0rc2-Piers"
NATIVE="${BUILD}/native"
TOOLCHAIN="${BUILD}/toolchain-arm64.cmake"
export HOME=/work/home
mkdir -p "${BUILD}" "${HOME}"

build_ffmpeg() {
	local dir="${BUILD}/ffmpeg-9.0.2"
	rm -rf "${dir}"
	tar -C "${BUILD}" -xf "${SRC}/ffmpeg-9.0.2.tar.xz"
	(cd "${dir}" && patch -p1 --batch -i "${SRC}/0001-v4l2-request.patch")
	cd "${dir}"
	./configure --prefix=/opt/kodi-ffmpeg --enable-shared --disable-static --enable-gpl \
		--enable-libdrm --enable-libudev --enable-v4l2-request --enable-v4l2-m2m \
		--disable-doc --disable-debug \
		--extra-ldflags=-Wl,-rpath,/opt/kodi-ffmpeg/lib \
		--enable-cross-compile --arch=aarch64 --target-os=linux \
		--cross-prefix="${TRIPLET}-" --pkg-config="${TRIPLET}-pkg-config"
	make -j"${JOBS}"
	rm -rf /opt/kodi-ffmpeg
	make install
}

# Host tools: native toolchain file (SWIG, JsonSchemaBuilder) and TexturePacker.
build_tools() {
	mkdir -p "${NATIVE}/share" "${NATIVE}/bin"
	cat > "${NATIVE}/share/Toolchain-Native.cmake" << 'EOF'
set(CMAKE_C_COMPILER gcc)
set(CMAKE_CXX_COMPILER g++)
set(CMAKE_PROGRAM_PATH /usr/bin)
EOF
	rm -rf "${BUILD}/texturepacker"
	cmake -S "${KODI_SRC}/tools/depends/native/TexturePacker/src" -B "${BUILD}/texturepacker" -G Ninja \
		-DCMAKE_BUILD_TYPE=Release -DKODI_SOURCE_DIR="${KODI_SRC}" \
		-DARCH_DEFINES="-DTARGET_POSIX;-DTARGET_LINUX;-D_GNU_SOURCE"
	cmake --build "${BUILD}/texturepacker"
	install -m 0755 "${BUILD}/texturepacker/TexturePacker" "${NATIVE}/bin/TexturePacker"
}

write_toolchain() {
	cat > "${TOOLCHAIN}" << EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER ${TRIPLET}-gcc)
set(CMAKE_CXX_COMPILER ${TRIPLET}-g++)
set(CMAKE_LIBRARY_ARCHITECTURE ${TRIPLET})
set(PKG_CONFIG_EXECUTABLE /usr/bin/${TRIPLET}-pkg-config CACHE FILEPATH "")
set(CMAKE_FIND_ROOT_PATH /opt/kodi-ffmpeg /usr/${TRIPLET})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
EOF
}

build_kodi() {
	write_toolchain
	local dir="${BUILD}/kodi-build"
	mkdir -p "${dir}"
	export PKG_CONFIG_PATH=/opt/kodi-ffmpeg/lib/pkgconfig
	cmake -S "${KODI_SRC}" -B "${dir}" -G Ninja \
		-DCMAKE_TOOLCHAIN_FILE="${TOOLCHAIN}" \
		-DNATIVEPREFIX="${NATIVE}" \
		-DWITH_TEXTUREPACKER="${NATIVE}/bin/TexturePacker" \
		-DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/opt/kodi-22 \
		-DCMAKE_INSTALL_RPATH=/opt/kodi-ffmpeg/lib \
		-DCORE_PLATFORM_NAME=gbm -DAPP_RENDER_SYSTEM=gles \
		-DENABLE_INTERNAL_FFMPEG=OFF -DFFMPEG_PATH=/opt/kodi-ffmpeg \
		-DENABLE_VAAPI=OFF -DENABLE_VDPAU=OFF -DENABLE_DVDCSS=OFF \
		-DENABLE_UDEV=ON -DENABLE_OPTICAL=ON -DENABLE_AIRTUNES=ON \
		-DENABLE_INTERNAL_CROSSGUID=ON -DENABLE_INTERNAL_LIBDVD=ON -DENABLE_INTERNAL_SWIG=ON \
		-DENABLE_INTERNAL_DATE=ON -DENABLE_INTERNAL_KISSFFT=ON -DENABLE_INTERNAL_TZDATA=ON \
		-DENABLE_TESTING=OFF
	cmake --build "${dir}" -j"${JOBS}"
	rm -rf /opt/kodi-22
	cmake --install "${dir}"
}

# Debian packages from /opt via ../pack-debs.sh; dpkg-shlibdeps resolves arm64 multiarch libraries.
build_debs() {
	DEB_HOST_ARCH=arm64 DEB_HOST_MULTIARCH="${TRIPLET}" DEB_HOST_GNU_TYPE="${TRIPLET}" \
		bash /scripts/pack-debs.sh /work/out/debs
}

if [[ ! -d ${KODI_SRC} ]]; then
	tar -C "${BUILD}" -xf "${SRC}/xbmc-22.0rc2-Piers.tar.gz"
	for p in /scripts/cross/patches/*.patch; do
		patch -d "${KODI_SRC}" -p1 --batch -i "${p}"
	done
fi

case "${STEP}" in
	ffmpeg) build_ffmpeg ;;
	tools) build_tools ;;
	kodi) build_kodi ;;
	debs) build_debs ;;
	all) build_ffmpeg && build_tools && build_kodi && build_debs ;;
	*) echo "unknown step: ${STEP}" >&2; exit 1 ;;
esac
