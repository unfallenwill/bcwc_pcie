# 逆向笔记：Apple 官方驱动 ↔ Linux 驱动 的交叉验证

本文记录把 **Apple 自己的内核扩展** 当作 ground truth，去审计社区逆向成果的过程与结论。

> 目的不是重复上游的逆向工作，而是回答一个问题：
> **「这套逆向出来的驱动，到底可不可信？」**

---

## 1. Ground truth 从哪来

Apple 的 FaceTime HD 摄像头驱动叫 `AppleCameraInterface.kext`，它打包在 macOS
系统镜像里。macOS 镜像用的是 `pbzx` 压缩格式，每个 chunk 本身是一个**完整的 xz 流**，
因此可以用 HTTP Range 只取回需要的字节区间，不必下载整个 1.9 GB 镜像。

我们用的是 macOS 10.12.6 (Sierra) 的组合更新包：

```
https://updates.cdn-apple.com/2019/cert/041-90765-20191011-837e856d-b522-4865-b64c-641048ed77c4/macOSUpdCombo10.12.6.dmg
```

提取流程（`tools/fetch-firmware.sh` 实现了完整版）：

| 产物 | 来源 | 大小 |
|---|---|---|
| `AppleCameraInterface` | chunk `699186570-703316225` 的尾部 + chunk `703316242-707986973` 的头部 | 757 072 B |
| `AppleCameraAssistant` | chunk `430282546-439105037`，跳过前 7 477 241 B | 515 632 B |
| `firmware.bin` | kext 内偏移 81920 处的 gzip 流 | 1 417 220 B |
| 11 个 `*_01XX.dat` | AppleCameraAssistant 内的传感器标定 set 文件 | 合计 ~230 KB |

全部产物的 sha256 都是硬编码校验的，任何一个字节对不上就中止。

---

## 2. 好消息：kext 没被 strip

`AppleCameraInterface` 是 **Mach-O 64-bit x86_64 kext bundle，未剥离符号**：

```console
$ file drv
drv: Mach-O 64-bit x86_64 kext bundle, flags:<NOUNDEFS|DYLDLINK|TWOLEVEL>

$ nm drv | grep -c 'AppleCamIn'
259
```

259 个 `AppleCamIn::` 方法全部带符号名，包括 `ISP_Init`、`ISP_LoadFirmware`、
`ispInterruptHandler`、`one_shmoo_RE_FIFO`、`s2_pll_init` 这些——正好是逆向时
最需要名字的函数。而且 `.cstring` 段里有大量调试日志字符串，直接描述了
驱动的内部状态机：

```
AppleCamIn::ISP_Init - ISPCPU Ready. About to enable ISP interrupts
AppleCamIn::ISP_Init - Got second int from ISPCPU (channel description table ready)
AppleCamIn::ISP_Init - Found channel %d in the channel table. Type=%d (%s), Source=%d, size: %d
AppleCamIn::ISP_InitialSensorDetection - found sensor on chan %d: 0x%04X
AppleCamIn::ISP_Init - No wake signal from ISPCPU
```

这让"照着 Apple 写"从"猜协议"变成了"读协议"。

---

## 3. 审计方法

### 3.1 难点：区分寄存器与结构体字段

朴素地扫描反汇编里所有 `OFF(%reg)` 会产生大量假阳性——结构体字段访问长得
和寄存器访问一模一样。例如 `this+0x1008` 看着就像个寄存器，其实是对象指针。

解法是**做轻量数据流追踪**。Apple 的设备对象里有两个 MMIO 基址字段：

| 字段 | 域 |
|---|---|
| `this + 0xfd0` | S2 域（DDR PHY / PCIe link） |
| `this + 0xff0` | ISP 域 |

审计器在每个函数内追踪：只有当某个寄存器是通过 `mov 0xfd0(this),%reg` /
`mov 0xff0(this),%reg`（或从这类寄存器拷贝而来）得到时，
经由它访问的 `OFF(%reg)` 才算寄存器访问。

实现见 [`tools/audit-registers.py`](../tools/audit-registers.py)。

### 3.2 过滤规则

- 排除 `%rip` 相对寻址（那是代码/数据地址）
- 排除栈帧访问（`%rsp` / `%rbp`）
- 偏移必须 4 字节对齐
- 偏移必须 ≥ 0x1000

---

## 4. 审计结果

```
Apple kext 访问的寄存器偏移 : 60
Linux 驱动定义的寄存器偏移   : 100
双方重合                     : 41
仅 Apple 使用                 : 19
仅 Linux 定义                 : 59

Apple kext 寄存器访问共 106 次
Linux 驱动已定义其中 82 次 (77.4%)
```

### 4.1 关键印证：位掩码完全一致

Apple 的中断处理器：

```asm
; AppleCamIn::ispInterruptHandler
3323: mov    0x41000(%rax),%r14d     ; 读 ISP_IRQ_STATUS
332a: test   $0xf0,%r14b           ; 测 bit 4..7
332e: je     358e
...
336e: mov    %r14d,0x41024(%rax)     ; 写回 ISP_IRQ_CLEAR
```

Linux 驱动的初始化等待：

```c
/* kernel/facetimehd/fthd_isp.c */
reg = FTHD_ISP_REG_READ(ISP_IRQ_STATUS);
if ((reg & 0xf0) > 0)
        break;
```

**同一个寄存器、同一个掩码 `0xf0`、同样的"读状态 → 写回清除"序列。**

这不是巧合能解释的——逆向者是从硬件/固件行为里独立得出的结论，却和 Apple
的实现逐位吻合。这是对上游逆向工作**忠实性**的有力证据。

### 4.2 寄存器表对照

重合的 41 个偏移覆盖了驱动的全部关键路径：

| 偏移 | Linux 名称 | Apple 侧访问次数 | 用途 |
|---|---|---|---|
| `0x41000` | `ISP_IRQ_STATUS` | 4 | 中断状态 |
| `0x41004` | `ISP_IRQ_ENABLE` | 1 | 中断使能 |
| `0x41024` | `ISP_IRQ_CLEAR` | 2 | 中断清除 |
| `0xc3000` | `ISP_FW_CHAN_CTRL` | 6 | IPC 通道数 |
| `0xc3004` | `ISP_FW_QUEUE_CTRL` | 4 | 队列大小 |
| `0xc3008` | `ISP_FW_SIZE` | 3 | 固件长度 |
| `0xc300c` | `ISP_FW_HEAP_SIZE` | 4 | 固件堆大小 |
| `0xc3010` | `ISP_FW_HEAP_ADDR` | 3 | 固件堆地址 |
| `0xc3014` | `ISP_FW_HEAP_SIZE2` | 3 | 固件堆大小 2 |
| `0xc3018` | `ISP_REG_C3018` | 2 | 命令缓冲 |
| `0xc301c` | `ISP_REG_C301C` | 2 | 命令缓冲 2 |
| `0x40004` | `ISP_REG_40004` | 2 | ISP 使能 |
| `0x02018` | `S2_DDR_STATUS_2018` | 6 | DDR 状态 |
| `0x0284c` | `S2_DDR40_PHY_VDL_STATUS` | 6 | PHY 电压检测 |
| `0x0d120`–`0x0d12c` | `S2_PCIE_LINK_D1xx` | 7 | PCIe link 控制 |
| `0x01100`–`0x0111c` | `S2_DDR_REG_110x` | 8 | DDR 初始化 |

### 4.3 发现一：19 个 Apple 独有寄存器

| 偏移 | 使用者 | 性质 |
|---|---|---|
| `0xc0000`–`0xc0024` (10 个) | `ISP_deInit` | 电源门控 |
| `0xc1004`–`0xc1024` (5 个) | `ISP_deInit` | 电源门控 |
| `0x42000` / `0x42008` | `ispInterruptHandler` | 读-清零事件计数器 |
| `0x90068` | `ISP_GetCameraTime` | 时间戳 |
| `0x01040` | `power_on_hardware` | 状态字节 |

**`0x42000` / `0x42008` 的读-清零模式**：

```asm
33ab: mov    0x42000(%rax),%ecx     ; 读
33b1: test   $0x2,%cl              ; 测 bit 1
33b4: je     33dc
33b6: incl   0xcc(%rbx)            ; 软件计数器++
33bc: mov    %ecx,0x42000(%rax)     ; 写回清除
```

这两个寄存器在 Apple 侧只被**递增计数**，从不被读取用于决策。
Linux 驱动不访问它们——**对采集功能没有影响**，属于诊断信息。

**电源门控那 15 个寄存器（`0xc0000`–`0xc0024`、`0xc1004`–`0xc1024`）**
只在 `ISP_deInit` 里用，也就是完整关机流程。Linux 驱动的 deinit 路径更简单，
不做完整门控。**这不影响采集**，但在**挂起/恢复**场景下 Apple 的做法更干净——
如果将来要做 suspend/resume 适配，这是一个明确的改进点。

### 4.4 发现二：59 个 Linux 独有寄存器

几乎全是 DDR PHY 相关（`0x28xx`、`0x2axx`、`0x2bxx`）——例如
`S2_DDR40_PHY_VDL_CTL`、`S2_DDR40_WL_READ_FIFO_CLEAR`、
`S2_DDR40_PHY_ZQ_PVT_COMP_CTL`。

这些**不是** Apple kext 访问不到的寄存器，而是**只有 Linux 驱动才需要**：
它们属于 DDR PHY 的 **shmoo 标定**流程（`one_shmoo_RE_FIFO`、
`save_ddr_phy_regs`、`restore_ddr_phy_regs`），Apple 把这部分工作交给了
固件或一次性标定数据，而 Linux 驱动必须自己扫 PHY 参数。

这解释了为什么 Linux 驱动的寄存器表（100）比 Apple kext 触达的（60）还大。

---

## 5. 结论

| 问题 | 答案 |
|---|---|
| 上游逆向成果可信吗？ | **可信**。关键寄存器的偏移、位掩码、读写时序与 Apple 官方实现逐位吻合。 |
| 有没有功能缺口？ | **对采集没有**。19 个 Apple 独有寄存器集中在关机电源门控和诊断计数器。 |
| 有没有多余/错误定义？ | 59 个 Linux 独有寄存器是 DDR PHY shmoo 所需，属于合理差异。 |
| 缺固件会怎样？ | 加载即失败。ISP 固件 `firmware.bin` + 传感器标定 set 文件缺一不可。 |

---

## 6. 怎么自己复现

```bash
# 抓取 Apple kext 并保留中间文件
./tools/fetch-firmware.sh --keep

# 跑审计
python3 tools/audit-registers.py \
    --kext <AppleCameraInterface 二进制> \
    --linux kernel/facetimehd/fthd_reg.h \
    --json artifacts/register-audit.json \
    --asm-out artifacts/apple-camera-interface.asm

# 把某个偏移的使用点定位到具体函数
python3 tools/trace-offsets.py artifacts/apple-camera-interface.asm 0x42000
```

`artifacts/register-audit.json` 与 `artifacts/apple-camera-interface.asm`
是本仓库已生成的产物，可以直接查看。
