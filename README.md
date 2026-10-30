# shexiangtou — MacBook Pro 摄像头驱动 (Broadcom FaceTime HD)

给 **2013 年中款 MacBook Pro (Retina, 13"/15")** 在 Linux 上装上摄像头。

这块摄像头是 **Broadcom FaceTime HD (PCI `14e4:1570`)**，走 **PCIe** 而不是 USB，
所以 Linux 内核自带的 `uvcvideo` 完全用不上——上游内核里**没有任何**能驱动它的代码。

---

## 现状

| 项目 | 状态 |
|---|---|
| 硬件识别 | ✅ `02:00.0 Multimedia controller: Broadcom 720p FaceTime HD Camera [14e4:1570]` |
| 驱动源码 | ✅ 已 vendor（GPLv2，上游 patjak/facetimehd） |
| 内核 7.0.0-38 编译 | ✅ **零 error、零 warning** |
| 固件提取 + sha256 校验 | ✅ 12/12 文件全部校验通过 |
| 与 Apple 官方驱动的寄存器交叉审计 | ✅ 覆盖率 77.4%，无冲突 |
| 运行时加载与出图 | ⏳ 需要 root 权限安装（见下） |

---

## 快速开始

```bash
# 1. 只编译（不需要 root）
./scripts/build.sh

# 2. 安装（需要 root：装固件 + DKMS 注册模块 + 加载）
sudo ./scripts/install.sh

# 3. 校验（不需要 root，随时可跑）
./scripts/verify.sh
```

装好后 `/dev/video0` 会出现，用任意 V4L2 应用打开即可：

```bash
ffplay /dev/video0            # 预览
ffmpeg -f v4l2 -i /dev/video0 -frames:v 1 out.png   # 抓一帧
```

---

## 仓库结构

```
kernel/facetimehd/     内核模块源码（out-of-tree，GPLv2）
firmware/              已校验的固件与传感器标定文件（12 个）
tools/
  fetch-firmware.sh    从 Apple CDN 重新抓取并校验固件
  audit-registers.py   用 Apple kext 审计驱动寄存器表
  trace-offsets.py     把寄存器访问定位到具体函数
scripts/
  build.sh             编译
  install.sh           安装（固件 + DKMS + 加载）
  verify.sh            校验固件与寄存器表
docs/
  reverse-engineering.md   逆向笔记：Apple 驱动 ↔ Linux 驱动的对照
  hardware.md              硬件识别与已知机型
artifacts/             审计产物（Apple kext 反汇编、JSON 报告）
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
   镜像，全部 sha256 硬校验，产物入库可离线安装。

详见 [`docs/reverse-engineering.md`](docs/reverse-engineering.md)。

---

## 许可

- `kernel/facetimehd/` — GPLv2，版权归 Patrik Jakobsson，保留原始 `LICENSE`。
  本仓库的修改同样以 GPLv2 发布。
- `firmware/` — 从 Apple 官方 macOS 更新包中提取的二进制，版权归 Apple，
  仅供本机硬件使用。
- `tools/` `scripts/` `docs/` — GPL-2.0-only。
