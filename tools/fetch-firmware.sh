#!/bin/bash
#
# SPDX-License-Identifier: GPL-2.0-only
#
# fetch-firmware.sh — 下载并提取 Broadcom FaceTime HD (PCI 14e4:1570) 摄像头固件
#
# 原理:
#   1. 摄像头 ISP 固件与传感器标定(set)文件都打包在 Apple 的
#      AppleCameraInterface.kext / AppleCameraAssistant.kext 里。
#   2. 这两个 kext 位于 macOS 安装镜像的 pbzx 分块中，每个分块本身是一个
#      完整的 xz 流，所以可以用 HTTP Range 只取回需要的字节区间，
#      无需下载 1.9GB 的完整镜像(实测约 18MB)。
#   3. 提取物全部用固定 sha256 校验，校验失败即中止。
#
# 用法:
#   ./fetch-firmware.sh --dest <dir>          # 只提取到 <dir>，不安装
#   sudo ./fetch-firmware.sh --dest <dir> --install
#
# 选项:
#   --dest DIR     产物输出目录 (默认 /usr/lib/firmware/facetimehd)
#   --install      安装到固件目录并设置权限 (需要 root)
#   --keep         保留中间文件，便于调试
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 固定常量（来源: patjak/facetimehd-firmware, 偏移量针对 Apple CDN 上
# 字节一致的 macOSUpdCombo10.12.6.dmg）
# ---------------------------------------------------------------------------
URL_COMBO="https://updates.cdn-apple.com/2019/cert/041-90765-20191011-837e856d-b522-4865-b64c-641048ed77c4/macOSUpdCombo10.12.6.dmg"

# AppleCameraInterface 跨两个分块
DRV_RANGE1="699186570-703316225"
DRV_TAIL1=249719
DRV_RANGE2="703316242-707986973"
DRV_HEAD2=507353
DRV_HASH="e959244db1e0561f6d5590c8e5000a36816c592e2820bafe89af0bea75556aca"

# 固件是 kext 内部的一段 gzip 流
FW_OFFSET=81920
FW_SIZE=602903
FW_HASH="240ef2e991f1d089d8228ce11d92b66bfa4b3d7289ec4fee228b64a713024330"

# AppleCameraAssistant 携带 11 个传感器标定 set 文件
ASST_RANGE="430282546-439105037"
ASST_SKIP=7477241
ASST_SIZE=515632
ASST_HASH="af6a9de00472657e925f546753c818f9e33636030892b14ca96a1b4817ea58c7"

# name offset size sha256
SETFILES='
9112 217088 33060 4dd756fa8460d8dc3d78d0d76944b2f92275d1fe9c83181bbc8292c81c005f1a
1771 253952 19040 756c2bb7c5e55b395449e43a0be1cb7c40c37dfc6c2b5abfaffb8ae70ff0fc4b
1871 274432 19040 bf36fbde0668ab7e44368b584f9fa64b5945b01003d04c6e3c6f22c0be0fd5f3
1874 294912 19040 ffde89e7819ac16a9eb1c8f0bc6dba0e980b508b2022507679d901c190f7cef8
1222 315392 20076 04a6aa0d67c0353505a56187c573b27dfdef703dfb4b98329b1ee74f59e4ba7e
8221 335872 30240 2e041686cf2484345b08b18207266abe725f41f8869e04d427aa092071d9edde
1571 368640 18652 0f73f550b65121115fe0b999f016fb3be3d109057597863df9fe01fd4678c300
1575 389120 18652 31068eab65ba25a480fd4d0463e86f8e2807828a2e251a20b6f107499e0f7936
1674 409600 18044 32377ac603d764f33f1466b5e4a7e3e08780d7becc50ad5b00292e29e2dd0374
1675 430080 18044 b7a38aef2755721bb28c92d84a15654b17e9fb3b0a0f088a384a981fc8fe16d6
1671 450560 18044 0b90133936bf0bbcdde4b85df8d3fc18722b58d2f8a1afc2564c6c242b6c57fa
'

DEST="/usr/lib/firmware/facetimehd"
DO_INSTALL=0
KEEP=0

while [[ $# -gt 0 ]]; do
	case "$1" in
		--dest)    DEST="$2"; shift 2 ;;
		--install) DO_INSTALL=1; shift ;;
		--keep)    KEEP=1; shift ;;
		-h|--help) sed -n '2,30p' "$0"; exit 0 ;;
		*) echo "未知参数: $1" >&2; exit 1 ;;
	esac
done

WORKDIR="$(mktemp -d)"
cleanup() { [[ $KEEP -eq 1 ]] || rm -rf "$WORKDIR"; }
trap cleanup EXIT
cd "$WORKDIR"

verify() { # verify <file> <sha256>
	local h
	h="$(sha256sum "$1" | awk '{print $1}')"
	if [[ "$h" != "$2" ]]; then
		echo "校验失败: $1" >&2
		echo "  期望 $2" >&2
		echo "  实际 $h" >&2
		exit 1
	fi
}

fetch_chunk() { # fetch_chunk <range> <outfile>
	curl -fsSL --retry 3 --retry-delay 2 -r "$1" "$URL_COMBO" | xzcat -q 2>/dev/null > "$2"
}

slice() { # slice <infile> <offset> <size> > stdout
	head -c "$(($2 + $3))" "$1" | tail -c "$3"
}

echo "==> 下载 AppleCameraInterface（分块 1/2）"
fetch_chunk "$DRV_RANGE1" chunk1
echo "==> 下载 AppleCameraInterface（分块 2/2）"
fetch_chunk "$DRV_RANGE2" chunk2
tail -c "$DRV_TAIL1" chunk1 > drv
head -c "$DRV_HEAD2" chunk2 >> drv
rm -f chunk1 chunk2
verify drv "$DRV_HASH"
echo "    kext 校验通过"

echo "==> 提取 ISP 固件"
slice drv "$FW_OFFSET" "$FW_SIZE" | gzip -dc > firmware.bin
verify firmware.bin "$FW_HASH"
echo "    固件校验通过 ($(stat -c%s firmware.bin) 字节)"
rm -f drv

echo "==> 下载 AppleCameraAssistant（传感器标定）"
fetch_chunk "$ASST_RANGE" chunkA
slice chunkA "$ASST_SKIP" "$ASST_SIZE" > asst
rm -f chunkA
verify asst "$ASST_HASH"
echo "    kext 校验通过"

echo "==> 提取传感器标定 set 文件"
while read -r name offset size hash; do
	[[ -z "$name" ]] && continue
	slice asst "$offset" "$size" > "${name}_01XX.dat"
	verify "${name}_01XX.dat" "$hash"
	echo "    ${name}_01XX.dat  ok"
done <<< "$SETFILES"
rm -f asst

mkdir -p "$DEST"
install -m644 firmware.bin "$DEST/firmware.bin"
install -m644 ./*_01XX.dat "$DEST/"

echo "==> 固件已就位: $DEST"
ls -l "$DEST"

if [[ $DO_INSTALL -eq 1 ]]; then
	# 驱动请求的固件名带 .dat 后缀，实际文件名需与 module 声明一致
	echo "==> 安装完成，重启或重新加载 facetimehd 模块后生效"
fi
