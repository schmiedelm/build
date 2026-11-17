#!/bin/sh
# Debug-Modul dw-hdmi-cec: schreibt den rohen CEC-Interruptstatus in den ftrace-Puffer.
# Aufruf auf dem Board als root:
#   cec-stat-debug.sh install   Modul bauen (braucht linux-headers), installieren, neu laden
#   cec-stat-debug.sh log       Puffer leeren und live mitlesen
#   cec-stat-debug.sh remove    Original-Modul wiederherstellen
# Bits: 0x01 DONE, 0x02 EOM, 0x04 NACK, 0x08 ARBLOST, 0x10 ERROR_INIT, 0x20 ERROR_FOLL; lock = HDMI_CEC_LOCK
# Neustart nach ERROR_INIT testen: echo 10 > /sys/module/dw_hdmi_cec/parameters/retry_ms (0 = aus)
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
DEST="/lib/modules/$(uname -r)/updates"
TR=/sys/kernel/tracing

reload() {
	systemctl stop kodi-vpu.service || true
	modprobe -r dw_hdmi_cec
	modprobe dw_hdmi_cec
	systemctl start kodi-vpu.service || true
}

case "$1" in
install)
	[ -d "/lib/modules/$(uname -r)/build" ] || { echo "Kernel-Header fehlen: passendes linux-headers-edge-imx8m_*.deb aus output/debs/ installieren"; exit 1; }
	make -C "${HERE}" clean all
	mkdir -p "${DEST}"
	install -m 0644 "${HERE}/dw-hdmi-cec.ko" "${DEST}/"
	depmod -a
	reload
	modinfo -n dw_hdmi_cec
	;;
log)
	echo > "${TR}/trace"
	echo 1 > "${TR}/tracing_on"
	cat "${TR}/trace_pipe"
	;;
remove)
	rm -f "${DEST}/dw-hdmi-cec.ko"
	depmod -a
	reload
	modinfo -n dw_hdmi_cec
	;;
*)
	echo "Aufruf: $0 install|log|remove" >&2
	exit 1
	;;
esac
