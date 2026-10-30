#!/bin/bash
#
# SPDX-License-Identifier: GPL-2.0-only
#
# selftest.sh — 运行时自检：确认摄像头真的能出图
#
# 需要 root（要读 dmesg / debugfs）。
#
set -uo pipefail

DEV="${1:-/dev/video0}"
OUT="${OUT_DIR:-/tmp/fthd-selftest}"
FAIL=0

ok()  { echo "  [OK]   $1"; }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "========================================================"
echo " FaceTime HD 运行时自检"
echo "========================================================"

echo
echo "--- 1. 模块 ---"
if lsmod | grep -q '^facetimehd'; then
	ok "模块已加载"
	lsmod | grep facetimehd | head -1 | sed 's/^/       /'
else
	bad "模块未加载"
fi

echo
echo "--- 2. 设备节点 ---"
if [ -e "$DEV" ]; then
	ok "$DEV 存在"
	ls -l "$DEV" | sed 's/^/       /'
else
	bad "$DEV 不存在"
	echo
	echo "结果: 失败 ${FAIL} 项"
	exit 1
fi

echo
echo "--- 3. 驱动信息 ---"
v4l2-ctl -d "$DEV" --all 2>/dev/null | grep -E 'Driver name|Card type|Bus info|Pixel Format|Width/Height|Frames per second' | sed 's/^/  /'

echo
echo "--- 4. 采集 30 帧 ---"
mkdir -p "$OUT"
rm -f "$OUT"/*.raw "$OUT"/*.png
if v4l2-ctl -d "$DEV" --stream-mmap=4 --stream-count=30 --stream-to="$OUT/stream.raw" 2>&1 | tail -2; then
	ok "流式采集完成"
else
	bad "流式采集失败"
fi

if [ -s "$OUT/stream.raw" ]; then
	SZ=$(stat -c%s "$OUT/stream.raw")
	FRAME=$((1280 * 720 * 2))   # YUYV 1280x720
	N=$((SZ / FRAME))
	ok "原始数据 ${SZ} 字节 = ${N} 帧 (${FRAME} B/帧)"
	if [ "$N" -ge 30 ]; then
		ok "帧数达标"
	else
		bad "帧数不足: $N < 30"
	fi
else
	bad "没有产生原始数据"
fi

echo
echo "--- 5. 解码成 PNG ---"
if ffmpeg -hide_banner -loglevel error -f rawvideo -pixel_format yuyv422 \
	-video_size 1280x720 -i "$OUT/stream.raw" -frames:v 1 -y "$OUT/frame.png" 2>&1; then
	if [ -s "$OUT/frame.png" ]; then
		ok "已生成 $OUT/frame.png"
		# 检查是不是纯黑/纯色（说明不是真实画面）
		STAT=$(python3 - "$OUT/frame.png" <<'PY' 2>/dev/null
import sys
try:
    from PIL import Image
    im = Image.open(sys.argv[1]).convert('L')
    px = list(im.getdata())
    print(f"{sum(px)//len(px)} {max(px)-min(px)}")
except Exception:
    print("NA NA")
PY
)
		MEAN=$(echo "$STAT" | cut -d' ' -f1)
		RANGE=$(echo "$STAT" | cut -d' ' -f2)
		if [ "$MEAN" != "NA" ] && [ "$RANGE" -gt 30 ]; then
			ok "画面有内容 (平均灰度 $MEAN, 动态范围 $RANGE)"
		else
			bad "画面可能是空白 (平均灰度 $MEAN, 动态范围 $RANGE)"
		fi
	else
		bad "PNG 生成失败"
	fi
else
	bad "ffmpeg 解码失败"
fi

echo
echo "--- 6. 内核日志中的错误 ---"
ERRS=$(dmesg 2>/dev/null | grep -i facetime | grep -icE 'error|fail|timeout|invalid|warn')
if [ "${ERRS:-0}" -eq 0 ]; then
	ok "无错误"
else
	bad "发现 $ERRS 行错误/警告"
	dmesg | grep -i facetime | grep -iE 'error|fail|timeout|invalid|warn' | tail -10 | sed 's/^/       /'
fi

echo
echo "--- 7. debugfs 诊断接口 ---"
if [ -d /sys/kernel/debug/facetimehd ]; then
	ok "debugfs 可用"
	find /sys/kernel/debug/facetimehd -type f | sed 's/^/       /'
else
	echo "  [--] debugfs 未挂载或模块未创建（可选）"
fi

echo
echo "========================================================"
echo " 结果: 失败 ${FAIL} 项"
echo "========================================================"
[[ $FAIL -eq 0 ]] || exit 1
