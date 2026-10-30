#!/bin/bash
#
# SPDX-License-Identifier: GPL-2.0-only
#
# verify.sh — 校验固件完整性 + 驱动与 Apple 官方驱动的寄存器交叉审计
#
# 这一步不需要 root，可以随时运行，用来确认：
#   1. 仓库里的固件没有被篡改
#   2. Linux 驱动的寄存器表与 Apple 官方二进制对得上
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE"

PASS=0
FAIL=0
ok()   { echo "  [OK]   $1"; PASS=$((PASS+1)); }
bad()  { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "========================================================"
echo " 1. 固件完整性校验 (sha256)"
echo "========================================================"

# 固件可能来自仓库内的 firmware/ 或已安装的 /usr/lib/firmware/facetimehd
FWCHECK=""
for cand in "${HERE}/firmware" "/usr/lib/firmware/facetimehd" "/lib/firmware/facetimehd"; do
	[[ -f "${cand}/firmware.bin" ]] && { FWCHECK="$cand"; break; }
done
if [[ -z "$FWCHECK" ]]; then
	bad "找不到固件（仓库 firmware/ 或 /usr/lib/firmware/facetimehd）"
	bad "先运行: ./tools/fetch-firmware.sh --dest ${HERE}/firmware"
	FWCHECK="${HERE}/firmware"
else
	echo "  校验目录: ${FWCHECK}"
fi

declare -A HASHES=(
	[firmware.bin]="240ef2e991f1d089d8228ce11d92b66bfa4b3d7289ec4fee228b64a713024330"
	[9112_01XX.dat]="4dd756fa8460d8dc3d78d0d76944b2f92275d1fe9c83181bbc8292c81c005f1a"
	[1771_01XX.dat]="756c2bb7c5e55b395449e43a0be1cb7c40c37dfc6c2b5abfaffb8ae70ff0fc4b"
	[1871_01XX.dat]="bf36fbde0668ab7e44368b584f9fa64b5945b01003d04c6e3c6f22c0be0fd5f3"
	[1874_01XX.dat]="ffde89e7819ac16a9eb1c8f0bc6dba0e980b508b2022507679d901c190f7cef8"
	[1222_01XX.dat]="04a6aa0d67c0353505a56187c573b27dfdef703dfb4b98329b1ee74f59e4ba7e"
	[8221_01XX.dat]="2e041686cf2484345b08b18207266abe725f41f8869e04d427aa092071d9edde"
	[1571_01XX.dat]="0f73f550b65121115fe0b999f016fb3be3d109057597863df9fe01fd4678c300"
	[1575_01XX.dat]="31068eab65ba25a480fd4d0463e86f8e2807828a2e251a20b6f107499e0f7936"
	[1674_01XX.dat]="32377ac603d764f33f1466b5e4a7e3e08780d7becc50ad5b00292e29e2dd0374"
	[1675_01XX.dat]="b7a38aef2755721bb28c92d84a15654b17e9fb3b0a0f088a384a981fc8fe16d6"
	[1671_01XX.dat]="0b90133936bf0bbcdde4b85df8d3fc18722b58d2f8a1afc2564c6c242b6c57fa"
)

for f in "${!HASHES[@]}"; do
	if [[ ! -f "${FWCHECK}/${f}" ]]; then
		bad "${FWCHECK}/${f} 不存在"
		continue
	fi
	got="$(sha256sum "${FWCHECK}/${f}" | awk '{print $1}')"
	if [[ "$got" == "${HASHES[$f]}" ]]; then
		ok "${f}"
	else
		bad "${f}  sha256 不符"
	fi
done

echo
echo "========================================================"
echo " 2. 本机硬件识别"
echo "========================================================"
if lspci -nn | grep -q '14e4:1570'; then
	ok "检测到 Broadcom FaceTime HD (14e4:1570)"
	lspci -nn | grep '14e4:1570' | sed 's/^/       /'
else
	bad "未检测到 14e4:1570（本机没有这颗摄像头？）"
fi

echo
echo "========================================================"
echo " 3. 驱动寄存器交叉审计（ground truth = Apple kext）"
echo "========================================================"

KE="${FTHD_APPLE_KEXT:-}"
if [[ -z "$KE" ]]; then
	for cand in \
		"$HERE/artifacts/apple-camera-interface" \
		"/tmp/fwdl/drv" \
		"$HOME/.cache/facetimehd/apple-camera-interface"
	do
		[[ -f "$cand" ]] && { KE="$cand"; break; }
	done
fi

if [[ -n "$KE" && -f "$KE" ]]; then
	ok "使用 Apple kext: $KE"
	python3 tools/audit-registers.py \
		--kext "$KE" \
		--linux kernel/facetimehd/fthd_reg.h \
		--json artifacts/register-audit.json
else
	echo "  [跳过] 未找到 Apple kext 二进制。"
	echo "         运行 tools/fetch-firmware.sh --keep 后用"
	echo "         FTHD_APPLE_KEXT=<路径> 重新运行本脚本。"
	echo "         获取方式见 docs/reverse-engineering.md"
fi

echo
echo "========================================================"
echo " 结果: 通过 ${PASS} / 失败 ${FAIL}"
echo "========================================================"
[[ $FAIL -eq 0 ]] || exit 1
