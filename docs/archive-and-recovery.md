# 存档与恢复：这份东西会不会失传

一个很实际的问题：**如果 Apple 关掉 CDN，这套东西是不是就永久失传了？**

答案分三层，逐层看。

---

## 结论速览

| 组成 | 会失传吗 | 依据 |
|---|---|---|
| **驱动源码** | ❌ 不会 | Software Heritage 已长期存档多个副本 + 本机 DKMS |
| **固件二进制** | ❌ 不会 | 不是唯一副本，可从 9 个独立 Apple/Boot Camp 发行版提取 |
| **提取方法（知识）** | ❌ 不会 | 本文档 + `tools/extract-firmware.py` 描述了完整可复现算法 |
| **提取脚本里的 URL** | ⚠️ **会** | 这正是本仓库已经修掉的部分 |

---

## 1. 驱动源码：已经进了长期存档

`patjak/facetimehd` 及其衍生的多个 fork 已被
[Software Heritage](https://archive.softwareheritage.org/) 收录，包括：

- `CtrlC-Root/facetimehd`
- `codyphobe/facetimehd-firmware`
- `P0cket-Sevens/FaceTimeHD-dat-files`（连 11 个标定文件的独立仓库都有）
- `robberphex/facetimehd-dkms`
- openSUSE 的 `facetimehd` 打包

Software Heritage 是法国 INRIA 运营的**永久性**软件档案馆，有法律地位的保存承诺，
不依赖 GitHub 的商业存续。仓库地址失效、作者删库都不影响它。

另外本机通过 DKMS 安装了模块源码（`/usr/src/facetimehd-0.7.0.1`），
每次内核升级自动重建。

---

## 2. 固件：不是唯一副本

关键认识：**ISP 固件不是 Apple 的"原创作品"，而是从 Apple 自己的 kext 里提取出来的
一段 gzip 流**。同一个 kext 被打包进了**很多个** Apple 发行版：

| 来源 | 固件版本 |
|---|---|
| Windows Boot Camp 5.1.5722 | 1.05 |
| Windows Boot Camp Update (2015-07-29) | 1.38 |
| OS X 10.11.0 El Capitan | 1.40 |
| OS X 10.11.2 / 10.11.3 / 10.11.5 | 1.43 |
| macOS 10.12.6 Sierra | 5.60 |

上游 [patjak/facetimehd-firmware](https://github.com/patjak/facetimehd-firmware)
记录了**全部 9 个**驱动版本的 kext 哈希与固件哈希。任何一个来源活着，
固件就能重获。

更重要的是：**这些 kext 不是稀有的**。每一个 Mac 的恢复分区里都有一份，
实体安装盘上有，各镜像站也有。

---

## 3. 提取方法：内容寻址，不依赖位置

### 为什么固定偏移是脆弱的

早期版本的提取脚本硬编码了两样东西：

```bash
DRV_RANGE1="699186570-703316225"   # kext 在 DMG 里的字节区间
FW_OFFSET=81920                     # gzip 流在 kext 里的偏移
```

这两样都**只对某一个特定镜像成立**。Apple 一旦重组镜像结构或撤下链接，
工具立刻失效——而且是静默失效还是报错失效，取决于实现。

### 本仓库的做法：按内容找

[`tools/extract-firmware.py`](../tools/extract-firmware.py) 不认位置，只认哈希：

**固件**：扫描 kext 里所有 gzip 流，逐个解压，用 sha256 认版本

```python
GZIP_MAGIC = b'\x1f\x8b'
# 扫描 -> 解压 -> sha256 比对已知版本表
```

**标定文件**：每个文件的头 2 字节（小端）就是传感器号，正好等于文件名里的数字

```
1871_01XX.dat  ->  18 71 01 07 ...   (0x1871 小端 = 6257)
1675_01XX.dat  ->  16 75 01 07 ...
```

于是定位逻辑是「找 LE16 == 传感器号的地方」，再由 sha256 确认，
**完全不依赖偏移**。任何一个版本的 kext 丢进来都能提取。

实测（用 macOS 10.12.6 的 kext）：

```console
$ python3 tools/extract-firmware.py firmware artifacts/apple-camera-interface /tmp/ct
固件版本 : macOS 10.12.6 (Sierra)
sha256   : 240ef2e991f1d089d8228ce11d92b66bfa4b3d7289ec4fee228b64a713024330
大小     : 1417220 字节
```

产物与 CDN 路径取到的**逐字节相同**。

### 拿到 kext 的途径

CDN 死了以后，kext 依然有这些来源：

**途径 A —— 任意 macOS 安装介质（Linux 上用 7z）**

```bash
# macOS 10.12.6 组合更新包等都是 UDIF 镜像，内含 HFS+ 卷
7z l macOSUpdCombo10.12.6.dmg          # 列出内容
7z x macOSUpdCombo10.12.6.dmg -o./x    # 解出 .pkg
# .pkg 里的 Payload 是 pbzx 包装的 cpio，pbzx 里每块都是完整 xz 流
7z x macOSUpdCombo10.12.6.pkg -o./y     # 取出 Payload
# Payload 里逐块 xz 解压 + cpio 解包，得到 kext
```

**途径 B —— 在 Mac 上（原生工具链）**

```bash
hdiutil attach macOSUpdCombo10.12.6.dmg
pbzx OSXUpd*.pkg/Payload > /dev/null
cat Payload.part*.xz | xz --decompress | cpio -id
# 得到 System/Library/Extensions/AppleCameraInterface.kext/Contents/MacOS/AppleCameraInterface
```

**途径 C —— Software Heritage / 其它镜像**

已存档的 fork 仓库里通常也带着提取出的固件与标定文件。

拿到 kext 后：

```bash
python3 tools/extract-firmware.py firmware <AppleCameraInterface> firmware/
python3 tools/extract-firmware.py setfiles <AppleCameraAssistant> firmware/
```

---

## 4. 冗余设计总结

```
        驱动源码                        ISP 固件
           │                              │
    ┌──────┴───────┐              ┌───────┴────────┐
    │ 本机 DKMS     │              │ 9 个 Apple 发行版 │
    │ Software      │              │ 任意 Mac 恢复分区│
    │  Heritage     │              │ 镜像站           │
    │ 多个 fork     │              │ 内容寻址提取器   │
    └──────┬───────┘              └───────┬────────┘
           │                              │
           └──────────┬───────────────────┘
                      │
              内容寻址（sha256 确认）
                      │
                  本仓库工具链
```

两层冗余：**载体层**（多个存档点）+ **方法层**（不依赖位置，只依赖内容）。

---

## 5. 仍然存在的风险（诚实列出）

| 风险 | 影响 | 缓解 |
|---|---|---|
| 所有 macOS 发行版与镜像站同时消失 | 固件无法重获 | 概率极低；且 Software Heritage 已有标定文件副本 |
| 已知固件哈希表不完整，新版本无法识别 | 无法识别新 kext | `extract-firmware.py identify` 会报出实际 sha256，提交给上游即可扩充 |
| Apple 修改 kext 内部格式 | 内容寻址失效 | 工具会明确报错而非静默产出错文件；需按新格式调整扫描规则 |
| 上游仓库整体消失 | 无新功能/无修复 | 源码已被 Software Heritage 存档，本仓库本身就是一份可维护的副本 |

**最坏情况下**，这套东西的"失传"形态是：驱动源码还在（多处存档），
固件需要重新从某个 macOS 介质里挖——而这个动作本身是可复现的，
因为提取算法和校验值都写在了本仓库里。
