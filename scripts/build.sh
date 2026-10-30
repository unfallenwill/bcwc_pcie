#!/bin/bash
#
# SPDX-License-Identifier: GPL-2.0-only
#
# build.sh — 编译 facetimehd 内核模块（out-of-tree）
#
set -euo pipefail

KVER="${1:-$(uname -r)}"
KDIR="/lib/modules/${KVER}/build"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${HERE}/kernel/facetimehd"

if [[ ! -d "$KDIR" ]]; then
	echo "找不到内核构建目录: $KDIR" >&2
	echo "请先安装: sudo apt install linux-headers-${KVER}" >&2
	exit 1
fi

echo "==> 内核    : ${KVER}"
echo "==> 源码    : ${SRC}"
echo "==> 编译中..."

make -C "$KDIR" M="$SRC" modules

echo
echo "==> 产物:"
ls -l "$SRC"/facetimehd.ko
echo
echo "==> 模块信息:"
modinfo "$SRC"/facetimehd.ko | sed -n '1,8p'
echo
echo "编译完成。安装请运行: sudo ./scripts/install.sh"
