# Cross-build environment: Debian trixie amd64 with arm64 multiarch libraries.
FROM --platform=linux/amd64 debian:trixie
ENV DEBIAN_FRONTEND=noninteractive
RUN dpkg --add-architecture arm64 \
	&& sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources \
	&& apt-get update \
	&& apt-get install -y --no-install-recommends \
		crossbuild-essential-arm64 build-essential cmake ninja-build meson bison flex \
		pkgconf nasm autoconf automake libtool gettext gperf git curl ca-certificates \
		python3 default-jre-headless openjdk-21-jdk-headless file xz-utils patch \
		libpng-dev libgif-dev liblzo2-dev libjpeg-dev libpcre2-dev \
		libdrm-dev:arm64 libudev-dev:arm64 \
	&& apt-get build-dep -y -a arm64 --no-install-recommends kodi \
	&& apt-get install -y --no-install-recommends flatbuffers-compiler \
		libass-dev:arm64 libbluray-dev:arm64 libcec-dev:arm64 libcurl4-gnutls-dev:arm64 \
		libdav1d-dev:arm64 libexiv2-dev:arm64 libflatbuffers-dev:arm64 libfmt-dev:arm64 \
		libfstrcmp-dev:arm64 liblcms2-dev:arm64 libmicrohttpd-dev:arm64 liblzo2-dev:arm64 \
		libmariadb-dev:arm64 libnfs-dev:arm64 nlohmann-json3-dev libpcre2-dev:arm64 \
		libspdlog-dev:arm64 libtag-dev:arm64 libudfread-dev:arm64 libxslt1-dev:arm64 \
		libinput-dev:arm64 libxkbcommon-dev:arm64 libgbm-dev:arm64 libdisplay-info-dev:arm64 \
		libpipewire-0.3-dev:arm64 libpulse-dev:arm64 libasound2-dev:arm64 \
		libtinyxml2-dev:arm64 libtinyxml-dev:arm64 libgif-dev:arm64 libjpeg-dev:arm64 libpng-dev:arm64 \
		libp8-platform-dev:arm64 \
	&& apt-get remove -y libavcodec-dev:arm64 libavformat-dev:arm64 libavutil-dev:arm64 \
		libswscale-dev:arm64 libswresample-dev:arm64 libavfilter-dev:arm64 libpostproc-dev:arm64 \
	&& rm -rf /var/lib/apt/lists/*
