# Rockchip RK3399 hexa core 1GB/4GB RAM SoC 2 x GBE USB3 USB-C
BOARD_NAME="NanoPi R4S"
BOARDFAMILY="rockchip64" # Used to be rk3399
BOARD_MAINTAINER=""
BOOTCONFIG="nanopi-r4s-rk3399_defconfig"
KERNEL_TARGET="current,edge"
KERNEL_TEST_TARGET="current"
DEFAULT_CONSOLE="serial"
MODULES_BLACKLIST="rockchipdrm analogix_dp dw_mipi_dsi dw_hdmi gpu_sched lima hantro_vpu panfrost"
HAS_VIDEO_OUTPUT="no"
BOOTBRANCH_BOARD="tag:v2022.04"
BOOTPATCHDIR="u-boot-rockchip64-v2022.04"
