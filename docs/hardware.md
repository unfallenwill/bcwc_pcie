# 硬件识别

## 这块摄像头是什么

| 项目 | 值 |
|---|---|
| PCI ID | `14e4:1570` |
| 厂商 | Broadcom Inc. and subsidiaries |
| 名称 | 720p FaceTime HD Camera |
| 类 | `0480` Multimedia controller |
| 接口 | **PCIe**（不是 USB） |
| 内核模块 | `facetimehd`（out-of-tree） |

## 为什么 uvcvideo 用不了

FaceTime HD 走 PCIe + 私有 ISP 协议，**不是** USB Video Class。
所以：

- `uvcvideo` 不会绑定这个设备
- `/dev/video*` 不会出现
- `lsusb` 里也看不到它（很多人第一反应是去查 USB，结果什么都查不到）

上游 Linux 内核**没有**任何能驱动它的代码。

## 自检命令

```bash
lspci -nn | grep 14e4:1570
```

有输出 = 有这块摄像头。典型输出：

```
02:00.0 Multimedia controller [0480]: Broadcom Inc. and subsidiaries 720p FaceTime HD Camera [14e4:1570]
```

## 资源分布

从 `lspci -v` 看到的 BAR：

| BAR | 地址 | 大小 | 用途 |
|---|---|---|---|
| 0 | `0xb0900000` | 64 KB | S2 域寄存器（DDR PHY / PCIe link） |
| 2 | `0x90000000` | 256 MB | ISP 固件运行内存（prefetchable） |
| 4 | `0xb0800000` | 1 MB | ISP 域寄存器 |

驱动把 BAR0 映射成 MMIO，BAR2 用来跑 ISP 固件（固件通过 IPC 队列和驱动通信）。

## 已知受影响机型（2013–2017 的 Intel Mac）

- MacBook Pro 13" / 15" Retina（2013 年中至 2015 年）
- MacBook Air 13"（2013 年后）
- 12 英寸 MacBook（2015–2017）
- 部分 iMac

传感器型号决定了要加载哪个标定 set 文件。驱动靠 I2C 读出传感器 ID 后自动选择：

| `sensor_id1` | set 文件 |
|---|---|
| `0x9774` | `1671_01XX.dat` / `1674_01XX.dat` / `1675_01XX.dat`（按 `sensor_id0` 细分） |
| `0x9770` | `1871_01XX.dat` / `1874_01XX.dat`；MacBookAir 机型用 `1771_01XX.dat` |
| `0x8830` | `9112_01XX.dat` |
| `0x248` | `1571_01XX.dat` / `1575_01XX.dat` |
| `0x190` | `1222_01XX.dat` |
| `0x164` | `8221_01XX.dat` |

本仓库的 `firmware/` 目录**包含了全部 11 个 set 文件**，
所以不管读出哪个传感器都能正确标定。

`0x9770` 那条分支还带机型判断（`dmi_get_system_info()` 读 `Apple Inc.` +
`MacBookAir`），MacBook Air 会走 `1771_01XX.dat`——因为 Air 的传感器参数
和 Pro 不同。

## 本机

```
MacBookPro 7.0.0-38-generic  (Ubuntu 26.04.1 LTS, kernel 7.0.0-38)
02:00.0 Multimedia controller [0480]: Broadcom Inc. and subsidiaries
                                720p FaceTime HD Camera [14e4:1570]
```

2013 年中款 rMBP（Retina 13"/15"，即 MacBookPro11,3 / 11,5）。
