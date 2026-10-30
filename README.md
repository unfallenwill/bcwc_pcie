# bcwc_pcie

**Broadcom FaceTime HD 摄像头（PCI `14e4:1570`）的 Linux 驱动。**

给 **2013 年中款 MacBook Pro (Retina, 13"/15")** 在 Linux 上装上摄像头。

这块摄像头是 **Broadcom FaceTime HD (PCI `14e4:1570`)**，走 **PCIe** 而不是 USB，
所以 Linux 内核自带的 `uvcvideo` 完全用不上——上游内核里**没有任何**能驱动它的代码。

---

## 为什么叫 `bcwc_pcie`

沿用 Linux 摄像头驱动的传统命名 `<芯片代号>_<总线>`：

| 驱动名 | 含义 | 总线 |
|---|---|---|
| `bdc_pci` | Broadcom Digital Camera（上一代 Broadcom 摄像头，Linux 5.12 移除） | PCI |
| `uvcvideo` | USB Video Class 通用驱动 | USB |
| `cx88` / `saa7134` / `tw6864` | 各家芯片族 + 型号 | PCI |
| **`bcwc_pcie`** | **Broadcom 1570 FaceTime HD Camera** | **PCIe** |

- **BCWC** —— 这颗 Broadcom 摄像头芯片的代号。Apple 自己的内核扩展
  `AppleCameraInterface.kext` 里管它叫 **"S2 Chip"**
  （`AppleCamIn::EnableS2Chip` / `DisableS2Chip` / `acpiControlS2ChipPower`），
  驱动源码里则用 `S2_*` 前缀标识它的寄存器域。
- **pcie** —— 关键区分点：同样的 Broadcom 摄像头在老 Mac 上是 USB（走 `uvcvideo`），
  或者是上一代的 `bdc_pci`；只有 2011 年后的这批是 **PCIe** 且需要私有 ISP 协议。

上游 Linux 社区最早用的就是这个���称（`patjak/bcwc_pcie`，2014），
2015 年才为可搜索性改叫 `facetimehd`。本仓库沿用代号名，
但 **README 标题、模块名、GitHub topics 里都保留 "FaceTime HD" 关键词**，
两边的可搜索性都不丢。

> 内核模块名保持上游的 **`facetimehd`** 不变——改它会偏离上游、影响 DKMS 与
> udev 集成。`bcwc_pcie` 是仓库与项目的名字。

---

## 适用范围

### 硬件

| 项 | 值 |
|---|---|
| PCI ID | `14e4:1570` |
| 厂商 | Broadcom Inc. and subsidiaries |
| 设备名 | 720p FaceTime HD Camera |
| 接口 | **PCIe**（不是 USB） |
| 内核模块 | `facetimehd` |

### 怎么确认你的 Mac 适用

```bash
lspci -nn | grep 14e4:1570
```

有输出 = 适用。典型输出：

```
02:00.0 Multimedia controller [0480]: Broadcom Inc. and subsidiaries 720p FaceTime HD Camera [14e4:1570]
```

**没有输出 = 不适用**（要么是 USB 摄像头，要么是别的型号）。

### 支持的机型

| 机型 | 年份 |
|---|---|
| MacBook Pro 13" / 15" / 17" | 2011 年起 |
| MacBook Air 11" / 13" | 2011 年起（13" Air 2013 起换用此芯片） |
| iMac 21.5" / 27" | 2011 年中起 |
| Thunderbolt Display | — |
| 12 英寸 MacBook (8,1 / 9,1 / 10,1) | 2015–2017（需固件 5.60.0 + `1675_01XX.dat`） |

### 不适用的情形

- **USB 接口的 FaceTime 摄像头**（老款 iSight）——内核自带 `uvcvideo` 即可
- **上一代 Broadcom 摄像头**——老内核里的 `bdc_pci`（Linux 5.12 已移除）
- 非 Mac 平台的 BCWC 硬件——本驱动只针对 Apple 的固件与传感器标定

---

## 现状

**已在真机验证通过 —— 摄像头能出图。**

| 项目 | 状态 |
|---|---|
| 硬件识别 | ✅ `02:00.0 Multimedia controller: Broadcom 720p FaceTime HD Camera [14e4:1570]` |
| 驱动源码 | ✅ 已 vendor（GPLv2，上游 patjak/facetimehd） |
| 内核 7.0.0-38 编译 | ✅ **零 error、零 warning** |
| 固件提取 + sha256 校验 | ✅ 12/12 文件全部校验通过 |
| 与 Apple 官方驱动的寄存器交叉审计 | ✅ 覆盖率 77.4%，无冲突 |
| 驱动加载 + ISP 初始化 | ✅ DDR PHY 标定通过、固件加载成功、7 个 IPC 通道 |
| 实时出图 | ✅ **1280×720 YUYV @ 29.97 fps** |
| 开机自动加载 | ✅ PCI modalias → udev → modprobe 链路验证通过 |
| debugfs 诊断接口 | ✅ 8 个节点可用 |

本机实测（Ubuntu 26.04.1 LTS / kernel 7.0.0-38）：

```
$ v4l2-ctl -d /dev/video0 --stream-mmap=4 --stream-count=60 --stream-to=/dev/null
<<<<<<<<<<<<<<<<<<<<<<<<<<<<<< 29.97 fps
```

自检全绿：

```
$ sudo ./scripts/selftest.sh
--- 1. 模块 ---        [OK]  模块已加载
--- 2. 设备节点 ---    [OK]  /dev/video0 存在
--- 3. 驱动信息 ---    1280/720  'YUYV'  30.000 fps
--- 4. 采集 30 帧 ---   [OK]  55296000 字节 = 30 帧
--- 5. 解码成 PNG ---   [OK]  画面有内容 (平均灰度 91, 动态范围 255)
--- 6. 内核日志 ---     [OK]  无错误
--- 7. debugfs ---      [OK]  8 个诊断节点
结果: 失败 0 项
```

---

## 快速开始

```bash
# 1. 只编译（不需要 root）
./scripts/build.sh

# 2. 安装（需要 root）
#    固件不在仓库里 —— 若本地没有，install.sh 会自动从 Apple 官方更新包获取
sudo ./scripts/install.sh

# 3. 校验固件与寄存器表（不需要 root，随时可跑）
./scripts/verify.sh

# 4. 运行时自检（需要 root，会真的抓一帧并检查画面内容）
sudo ./scripts/selftest.sh
```

想提前把固件抓好（可离线安装）：

```bash
./tools/fetch-firmware.sh --dest firmware    # 约 18MB，12 个文件全部 sha256 校验
```

装好后 `/dev/video0` 会出现，用任意 V4L2 应用打开即可：

```bash
ffplay /dev/video0            # 预览
ffmpeg -f v4l2 -i /dev/video0 -frames:v 1 -y out.png   # 抓一帧
v4l2-ctl -d /dev/video0 --stream-mmap=4 --stream-count=60 --stream-to=/dev/null
```

> **注意**：用 `ffmpeg` 收尾时可能会看到
> `Some buffers are still owned by the caller on close.` 和
> `ioctl(VIDIOC_QBUF): Bad file descriptor`。
> 这是 **libavdevice 的收尾逻辑**与本驱动的 buffer 状态机不匹配所致，
> **不影响采集结果**（帧已全部正确写出）。用 `v4l2-ctl` 采集则完全无此提示。

---

## 固件从哪来

摄像头没有自带可引导的固件——ISP 固件必须由驱动在加载时从外部灌入。
它藏在 Apple 的 `AppleCameraInterface.kext` 里，而那个 kext 在 1.9GB 的
macOS 更新镜像中。

本仓库**不分发**这些 Apple 专有二进制，而是提供提取工具：

```bash
./tools/fetch-firmware.sh --dest firmware
```

它用 HTTP Range 只取回需要的字节区间（**约 18MB**，不是 1.9GB），
逐个文件用固定的 sha256 校验，任何一个字节对不上就中止。

### 如果 Apple 关掉 CDN

**东西不会失传。** 提取工具还有两条不依赖 CDN 的路径：

```bash
# 路径 2：从本地已有的 kext 按内容提取（不认偏移，只认哈希）
./tools/fetch-firmware.sh --dest firmware \
    --from-kext  <AppleCameraInterface> \
    --assistant  <AppleCameraAssistant>

# 路径 3：从本地 macOS 安装介质提取（需要 7z），再自动走路径 2
./tools/fetch-firmware.sh --dest firmware --from-dmg macOSUpdCombo10.12.6.dmg
```

路径 2 的原理是**内容寻址**：扫描 kext 里所有 gzip 流逐个解压认版本；
标定文件的头 2 字节（大端）就是传感器号，据此定位。完全不依赖字节偏移，
因此**任意版本**的 kext 都能提取。

实测两条路径的产物**逐字节相同**（12/12）。

完整的失传分析、kext 的各种获取途径、以及仍然存在的风险，
见 [`docs/archive-and-recovery.md`](docs/archive-and-recovery.md)。

### 12 个文件里哪些是必须的

实测（把文件移走、重新加载模块、对比出图与颜色）：

| 文件 | 数量 | 缺失后果 |
|---|---|---|
| `firmware.bin` | 1 | **致命** —— `probe with driver facetimehd failed with error -2`，一帧都出不来 |
| `*_01XX.dat` | 11 | **可选** —— 仍能正常出图，只是少了传感器标定，颜色偏灰 |

实测数据（同一场景对比）：

| 配置 | 平均 RGB | 平均饱和度 | 灰度动态范围 |
|---|---|---|---|
| 全齐（12 个） | (100, 84, 79) | **0.413** | 252 |
| 只有 `firmware.bin` | (74, 76, 74) | 0.324 | 214 |
| 没有 `firmware.bin` | — | **采集失败** | — |

即：11 个标定文件缺失时饱和度下降约 22%，画面偏灰但完全可用。
所以**追求画质就装全 12 个**，只求能用则 `firmware.bin` 即可。

---

## 仓库结构

```
kernel/facetimehd/     内核模块源码（out-of-tree，GPLv2）
tools/
  fetch-firmware.sh    获取并校验固件（3 条路径：CDN / 本地 kext / 本地 DMG）
  extract-firmware.py  内容寻址提取器（按哈希认版本，不依赖偏移）
  audit-registers.py   用 Apple kext 审计驱动寄存器表
  trace-offsets.py     把寄存器访问定位到具体函数
scripts/
  build.sh             编译
  install.sh           安装（固件 + DKMS + 加载 + 开机自启）
  verify.sh            校验固件与寄存器表
  selftest.sh          运行时自检（真的抓一帧并验证画面内容）
docs/
  reverse-engineering.md   逆向笔记：Apple 驱动 ↔ Linux 驱动的对照
  archive-and-recovery.md  存档与失传风险分析（含 CDN 失效的恢复流程）
  hardware.md              硬件识别与已知机型
artifacts/             审计产物（Apple kext 反汇编、JSON 报告）
firmware/              【不入库】固件缓存目录，由 fetch-firmware.sh 填充
```

---

## 这套东西是怎么来的（重要，请先读）

**不是从零写一个驱动。** 主体是上游社区的逆向成果：

- **驱动代码** — [patjak/facetimehd](https://github.com/patjak/facetimehd)（GPLv2），
  Patrik Jakobsson 对 Broadcom ISP 协议的逆向实现。
- **固件提取** — [patjak/facetimehd-firmware](https://github.com/patjak/facetimehd-firmware)。
- **打包安装** — [pschatzmann/macbook-camera](https://github.com/pschatzmann/macbook-camera)。

理由很直接：这块芯片的 ISP 协议是 Apple 私有协议，没有公开文档，
从零逆向需要搞懂 ISP 固件 ABI、DDR PHY shmoo 标定、S2/ISP 双域初始化、
I2C 传感器配置——这是**以月计**的工作量，不是能"今天"做完的事。

**本仓库在这个基础上做的，是三件独立的工作：**

1. **交叉审计** — 把 Apple 自己的内核扩展 `AppleCameraInterface.kext` 抽出来当
   ground truth，反汇编后逐寄存器比对，验证逆向成果是否忠实。
   → 结论：**忠实**。关键位掩码 `0xf0`、寄存器偏移、读写时序完全吻合，
   同时找出了 Linux 驱动未覆盖的 19 个寄存器（详见 `docs/reverse-engineering.md`）。
2. **新内核适配** — 上游驱动写于 4.x/5.x，本机是 7.0.0-38（2026 年）。
   已验证零警告编译通过。
3. **固件供应链** — 自己重写提取工具，用 HTTP Range 只取 ~18MB 而不是 1.9GB
   镜像，全部 sha256 硬校验。**Apple 专有二进制不入库**，由安装时现取。

详见 [`docs/reverse-engineering.md`](docs/reverse-engineering.md)。

---

## 许可

- `kernel/facetimehd/` — GPLv2，版权归 Patrik Jakobsson，保留原始 `LICENSE`。
  本仓库的修改同样以 GPLv2 发布。
- `tools/` `scripts/` `docs/` — GPL-2.0-only。
- **固件** — 从 Apple 官方 macOS 更新包中提取的二进制（`firmware.bin` 与 11 个
  传感器标定文件），版权归 Apple。**本仓库不分发这些文件**，
  由 `tools/fetch-firmware.sh` 在使用者本机从 Apple CDN 提取，
  仅供对应硬件使用。
