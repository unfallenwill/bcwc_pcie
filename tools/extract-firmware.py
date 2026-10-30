#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""
extract-firmware.py — 从 Apple 的 kext 中**按内容**提取 ISP 固件与传感器标定文件

为什么不用固定偏移:
    固定偏移只对某一个 Apple 驱动版本有效。Apple 的 kext 随 macOS 版本演进，
    偏移量与文件大小都会变（上游记录了 9 个不同版本）。一旦 Apple CDN 的
    URL 或镜像结构变化，基于偏移的提取就彻底失效。

    本工具改为**内容寻址**:
      - 固件: 扫描 kext 中所有 gzip 流，解压后用 sha256 认出版本
      - 标定文件: 每个文件头 2 字节就是传感器号（小端），据此定位，
                  再用 sha256 确认
    于是只要手上还有任意版本的 kext，就能提取出对应固件。

用法:
    extract-firmware.py firmware  <AppleCameraInterface> <输出目录>
    extract-firmware.py setfiles  <AppleCameraAssistant>  <输出目录>
    extract-firmware.py identify  <任意 kext 文件>        # 只报版本
"""
import hashlib
import os
import sys
import zlib

# ---- 已知产物的 sha256（来自 patjak/facetimehd-firmware，跨版本累积）--------
KNOWN_FIRMWARE = {
    "504fcf1565bf10d61b31a12511226ae51991fb55d480f82de202a2f7ee9c966e":
        "OS X 10.11.0 (El Capitan)",
    "e3e6034a67dfdaa27672dd547698bbc5b33f47f1fc7f5572a2fb68ea09d32d3d":
        "OS X 10.11.2-10.11.5 (El Capitan)",
    "240ef2e991f1d089d8228ce11d92b66bfa4b3d7289ec4fee228b64a713024330":
        "macOS 10.12.6 (Sierra)",
}

# ---- 传感器标定文件: 名称 -> (大小, sha256) -------------------------------
KNOWN_SETFILES = {
    "9112": (33060, "4dd756fa8460d8dc3d78d0d76944b2f92275d1fe9c83181bbc8292c81c005f1a"),
    "1771": (19040, "756c2bb7c5e55b395449e43a0be1cb7c40c37dfc6c2b5abfaffb8ae70ff0fc4b"),
    "1871": (19040, "bf36fbde0668ab7e44368b584f9fa64b5945b01003d04c6e3c6f22c0be0fd5f3"),
    "1874": (19040, "ffde89e7819ac16a9eb1c8f0bc6dba0e980b508b2022507679d901c190f7cef8"),
    "1222": (20076, "04a6aa0d67c0353505a56187c573b27dfdef703dfb4b98329b1ee74f59e4ba7e"),
    "8221": (30240, "2e041686cf2484345b08b18207266abe725f41f8869e04d427aa092071d9edde"),
    "1571": (18652, "0f73f550b65121115fe0b999f016fb3be3d109057597863df9fe01fd4678c300"),
    "1575": (18652, "31068eab65ba25a480fd4d0463e86f8e2807828a2e251a20b6f107499e0f7936"),
    "1674": (18044, "32377ac603d764f33f1466b5e4a7e3e08780d7becc50ad5b00292e29e2dd0374"),
    "1675": (18044, "b7a38aef2755721bb28c92d84a15654b17e9fb3b0a0f088a384a981fc8fe16d6"),
    "1671": (18044, "0b90133936bf0bbcdde4b85df8d3fc18722b58d2f8a1afc2564c6c242b6c57fa"),
}

GZIP_MAGIC = b'\x1f\x8b'


def sha256(b):
    return hashlib.sha256(b).hexdigest()


def find_firmware(data):
    """扫描所有 gzip 成员，返回 [(版本, 原始压缩流, 解压后内容)]"""
    hits = []
    pos = 0
    while True:
        i = data.find(GZIP_MAGIC, pos)
        if i < 0:
            break
        pos = i + 1
        if i + 10 > len(data):
            break
        try:
            d = zlib.decompressobj(16 + zlib.MAX_WBITS)
            raw = d.decompress(data[i:])
            raw += d.flush()
        except zlib.error:
            continue
        if not raw:
            continue
        h = sha256(raw)
        if h in KNOWN_FIRMWARE:
            hits.append((KNOWN_FIRMWARE[h], h, raw))
    return hits


def find_setfiles(data):
    """按 BE16 传感器号签名定位标定文件，再用 sha256 确认

    标定文件的头 2 字节是大端序的传感器号，与文件名里的数字一致:
        1871_01XX.dat -> 18 71 01 07 ...
        1675_01XX.dat -> 16 75 01 07 ...
    """
    found = {}
    for name, (size, want_hash) in KNOWN_SETFILES.items():
        target = int(name, 16).to_bytes(2, 'big')
        pos = 0
        while True:
            i = data.find(target, pos)
            if i < 0:
                break
            pos = i + 1
            blob = data[i:i + size]
            if len(blob) == size and sha256(blob) == want_hash:
                found[name] = blob
                break
    return found


def cmd_firmware(kext_path, outdir):
    data = open(kext_path, 'rb').read()
    hits = find_firmware(data)
    if not hits:
        print("在 %s 中未找到已知的 ISP 固件" % kext_path, file=sys.stderr)
        print("（该 kext 可能是本工具尚未收录的版本，请把它的 sha256 报给上游）",
              file=sys.stderr)
        return 1
    # 多个版本同时命中时，取最新的一个
    hits.sort(key=lambda h: h[0])
    ver, h, raw = hits[-1]
    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, 'firmware.bin')
    with open(path, 'wb') as f:
        f.write(raw)
    print("固件版本 : %s" % ver)
    print("sha256   : %s" % h)
    print("大小     : %d 字节" % len(raw))
    print("已写出   : %s" % path)
    return 0


def cmd_setfiles(asst_path, outdir):
    data = open(asst_path, 'rb').read()
    found = find_setfiles(data)
    if not found:
        print("在 %s 中未找到已知的传感器标定文件" % asst_path, file=sys.stderr)
        return 1
    os.makedirs(outdir, exist_ok=True)
    for name, blob in sorted(found.items()):
        path = os.path.join(outdir, "%s_01XX.dat" % name)
        with open(path, 'wb') as f:
            f.write(blob)
        print("  %s_01XX.dat  %d 字节" % (name, len(blob)))
    missing = set(KNOWN_SETFILES) - set(found)
    if missing:
        print("未找到 %d 个: %s" % (len(missing), ', '.join(sorted(missing))),
              file=sys.stderr)
    print("共写出 %d 个标定文件" % len(found))
    return 0


def cmd_identify(path):
    data = open(path, 'rb').read()
    hits = find_firmware(data)
    print("文件: %s (%d 字节)" % (path, len(data)))
    if hits:
        for ver, h, raw in hits:
            print("  ISP 固件: %s  sha256=%s  %d 字节" % (ver, h, len(raw)))
    else:
        print("  ISP 固件: 未识别")
    sf = find_setfiles(data)
    if sf:
        print("  内含标定文件: %s" % ', '.join(sorted(sf)))
    return 0


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    cmd = sys.argv[1]
    if cmd == 'firmware' and len(sys.argv) == 4:
        return cmd_firmware(sys.argv[2], sys.argv[3])
    if cmd == 'setfiles' and len(sys.argv) == 4:
        return cmd_setfiles(sys.argv[2], sys.argv[3])
    if cmd == 'identify' and len(sys.argv) == 3:
        return cmd_identify(sys.argv[2])
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main())
