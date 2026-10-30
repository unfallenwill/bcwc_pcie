#!/bin/bash
#
# SPDX-License-Identifier: GPL-2.0-only
#
# fetch-firmware.sh — 获取 Broadcom FaceTime HD (PCI 14e4:1570) 摄像头固件
#
# 三条路径:
#
#   1) 默认: 从 Apple CDN 抓
#      摄像头没有自带可引导固件，ISP 固件藏在 Apple 的
#      AppleCameraInterface.kext 里，而那个 kext 在 1.9GB 的 macOS 镜像中。
#      本路径用 HTTP Range 只取需要的字节区间(约 18MB)，
#      全部 sha256 硬校验。
#
#   2) --from-kext FILE [--assistant FILE]
#      从本地已有的 kext 按**内容**提取 (不依赖偏移，不依赖 CDN)。
#      这是 CDN 失效时的主要恢复手段，见 docs/archive-and-recovery.md
#
#   3) --from-dmg FILE
#      从本地 macOS 安装介质提取 (需要 7z)，再走路径 2
#
# 用法:
#   ./fetch-firmware.sh --dest <dir>
#   ./fetch-firmware.sh --dest <dir> --from-kext AppleCameraInterface [AppleCameraAssistant]
#   ./fetch-firmware.sh --dest <dir> --from-dmg macOSUpdCombo10.12.6.dmg
#
set -euo pipefail

# ---------------------------------------------------------------------------
# 固定常量（来源: patjak/facetimehd-firmware）
# 固件与标定文件的 sha256 全部硬编码；提取时用内容寻址工具复核
# ---------------------------------------------------------------------------
URLS=(
	"https://updates.cdn-apple.com/2019/cert/041-90765-20191011-837e856d-b522-4865-b64c-641048ed77c4/macOSUpdCombo10.12.6.dmg"
)

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
FROM_KEXT=""
FROM_ASSISTANT=""
FROM_DMG=""

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--dest)        DEST="$2"; shift 2 ;;
		--install)     DO_INSTALL=1; shift ;;
		--keep)        KEEP=1; shift ;;
		--from-kext)   FROM_KEXT="$(readlink -f "$2")"; shift 2 ;;
		--assistant)   FROM_ASSISTANT="$(readlink -f "$2")"; shift 2 ;;
		--from-dmg)    FROM_DMG="$(readlink -f "$2")"; shift 2 ;;
		-h|--help)     sed -n '2,30p' "$0"; exit 0 ;;
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

slice() { # slice <infile> <offset> <size> > stdout
	head -c "$(($2 + $3))" "$1" | tail -c "$3"
}

# ===========================================================================
# 路径 2/3: 从本地 kext 按内容提取（不依赖 CDN，不依赖偏移）
# ===========================================================================
if [[ -n "$FROM_DMG" ]]; then
	echo "==> 从 macOS 安装介质提取 kext: ${FROM_DMG}"
	command -v 7z >/dev/null || { echo "需要 7z (p7zip-full)" >&2; exit 1; }
	[[ -f "$FROM_DMG" ]] || { echo "找不到 ${FROM_DMG}" >&2; exit 1; }

	mkdir -p dmg && cd dmg
	7z x -y "$FROM_DMG" >/dev/null 2>&1 || true
	# 在解出的目录里找两个 kext 的可执行文件
	IFACE="$(find . -path '*AppleCameraInterface.kext/Contents/MacOS/AppleCameraInterface' -type f | head -1)"
	ASST="$(find . -path '*AppleCameraAssistant.kext/Contents/MacOS/AppleCameraAssistant' -type f | head -1)"
	cd ..
	if [[ -z "$IFACE" ]]; then
		echo "在 ${FROM_DMG} 里没找到 AppleCameraInterface.kext" >&2
		echo "该介质可能不含摄像头驱动（太老或太新）" >&2
		exit 1
	fi
	FROM_KEXT="$WORKDIR/dmg/${IFACE#./}"
	[[ -n "$ASST" ]] && FROM_ASSISTANT="$WORKDIR/dmg/${ASST#./}"
	echo "    找到 AppleCameraInterface"
fi

if [[ -n "$FROM_KEXT" ]]; then
	[[ -f "$FROM_KEXT" ]] || { echo "找不到 ${FROM_KEXT}" >&2; exit 1; }

	echo "==> 内容寻址提取 ISP 固件"
	python3 "${HERE}/extract-firmware.py" firmware "$FROM_KEXT" "$WORKDIR"

	echo "==> 内容寻址提取传感器标定文件"
	if [[ -n "$FROM_ASSISTANT" ]]; then
		python3 "${HERE}/extract-firmware.py" setfiles "$FROM_ASSISTANT" "$WORKDIR"
	else
		echo "    未提供 AppleCameraAssistant —— 跳过标定文件（不影响出图，颜色会偏灰）"
	fi

	DEST="$(readlink -m "$DEST")"
	mkdir -p "$DEST"
	install -m644 firmware.bin "$DEST/"
	shopt -s nullglob
	for f in ./*_01XX.dat; do install -m644 "$f" "$DEST/"; done
	shopt -u nullglob
	echo "==> 固件已就位: $DEST"
	ls -l "$DEST"
	exit 0
fi

# ===========================================================================
# 路径 1: 从 Apple CDN 抓
# ===========================================================================
URL_COMBO="${URLS[0]}"
DL_OK=0
for u in "${URLS[@]}"; do
	echo "==> 尝试 Apple CDN: ${u}"
	if curl -fsSL --retry 2 --retry-delay 2 -r 1-1024 "$u" -o /dev/null 2>/dev/null; then
		URL_COMBO="$u"
		DL_OK=1
		break
	fi
done
if [[ $DL_OK -eq 0 ]]; then
	echo >&2
	echo "Apple CDN 全部不可用。这不是死路 —— 请改用本地来源:" >&2
	echo "  1) 从任意 macOS 安装介质提取 kext 后用:" >&2
	echo "     ./fetch-firmware.sh --dest DIR --from-kext <AppleCameraInterface>" >&2
	echo "  2) 或直接用本地 DMG:" >&2
	echo "     ./fetch-firmware.sh --dest DIR --from-dmg <macOSUpdCombo.dmg>" >&2
	echo >&2
	echo "详见 docs/archive-and-recovery.md" >&2
	exit 1
fi

fetch_chunk() { # fetch_chunk <range> <outfile>
	curl -fsSL --retry 3 --retry-delay 2 -r "$1" "$URL_COMBO" | xzcat -q 2>/dev/null > "$2"
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
	echo "==> 安装完成，重启或重新加载 facetimehd 模块后生效"
fi
