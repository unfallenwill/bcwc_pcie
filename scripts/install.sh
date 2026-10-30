#!/bin/bash
#
# SPDX-License-Identifier: GPL-2.0-only
#
# install.sh — 安装 facetimehd 驱动与固件
#
# 做三件事:
#   1. 安装固件到 /usr/lib/firmware/facetimehd/
#   2. 用 DKMS 安装内核模块（内核升级后自动重建）
#   3. 加载模块并检查 /dev/video*
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${HERE}/kernel/facetimehd"
FWSRC="${HERE}/firmware"
KVER="$(uname -r)"

if [[ "$EUID" -ne 0 ]]; then
	echo "需要 root，请用: sudo $0" >&2
	exit 1
fi

# ---------------------------------------------------------------- 固件 --
FWDIR="/usr/lib/firmware/facetimehd"
[[ -d /usr/lib/firmware ]] || FWDIR="/lib/firmware/facetimehd"

echo "==> 安装固件到 ${FWDIR}"
mkdir -p "$FWDIR"
install -m644 "${FWSRC}/firmware.bin" "$FWDIR/"
install -m644 "${FWSRC}"/*_01XX.dat "$FWDIR/"
ls -l "$FWDIR"

# ------------------------------------------------------------ DKMS 模块 --
PKG="$(grep -oP '^PACKAGE_NAME=\K.*' "${SRC}/dkms.conf" | tr -d '"')"
VER="$(grep -oP '^PACKAGE_VERSION=\K.*' "${SRC}/dkms.conf" | tr -d '"')"
DKMS_SRC="/usr/src/${PKG}-${VER}"

# 若 DKMS 已登记过，先清掉，避免 "already installed" 冲突
if dkms status | grep -q "^${PKG}"; then
	echo "==> 移除旧的 DKMS 安装"
	dkms remove -m "$PKG" --all || true
fi

echo "==> 准备 DKMS 源码目录 ${DKMS_SRC}"
rm -rf "$DKMS_SRC"
mkdir -p "$DKMS_SRC"
cp -a "$SRC"/. "$DKMS_SRC/"
# 清掉可能带过来的构建产物
rm -f "$DKMS_SRC"/*.o "$DKMS_SRC"/*.ko "$DKMS_SRC"/*.mod "$DKMS_SRC"/*.mod.c
rm -rf "$DKMS_SRC"/.tmp_versions

echo "==> DKMS 构建 (${PKG} ${VER} / kernel ${KVER})"
dkms build -m "$PKG" -v "$VER" -k "$KVER"

echo "==> DKMS 安装"
dkms install -m "$PKG" -v "$VER" -k "$KVER"

# ---------------------------------------------------------------- 加载 --
echo "==> 配置开机自动加载"
# PCI modalias 已经能让 udev 自动加载（modprobe --resolve-alias 验证过），
# 这里再加一份 modules-load.d 兼底，避免设备枚举顺序导致的时序问题。
echo "facetimehd" > /etc/modules-load.d/facetimehd.conf

echo "==> 加载模块"
modprobe -r facetimehd 2>/dev/null || true
modprobe facetimehd || true

sleep 1

echo
echo "==> 状态检查"
if lsmod | grep -q '^facetimehd'; then
	echo "  模块已加载"
else
	echo "  !! 模块未加载，查看 dmesg 了解原因"
fi

if [ -e /dev/video0 ]; then
	echo "  视频设备: $(ls /dev/video* 2>/dev/null | tr '\n' ' ')"
else
	echo "  !! 没有出现 /dev/video*，查看 dmesg | grep -i facetime"
fi

echo
echo "诊断信息:"
dmesg | grep -iE 'facetime|fthd|14e4|1570' | tail -30
