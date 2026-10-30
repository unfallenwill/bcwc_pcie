# 上游来源与致谢

本仓库**不是**从零开始的驱动项目。核心成果来自以下上游项目，
在此明确致谢并说明各自贡献。

---

## 驱动代码

**patjak/facetimehd** — <https://github.com/patjak/facetimehd>

- 作者：Patrik Jakobsson
- 许可：GPLv2（见 `kernel/facetimehd/LICENSE`）
- 内容：Broadcom FaceTime HD (PCI `14e4:1570`) 的 V4L2 驱动实现。
  包含 ISP 命令协议、DDR PHY shmoo 标定、S2/ISP 双域初始化、
  I2C 传感器配置、视频格式与 ISP 参数调优。

本仓库 vendor 的版本：

```
6dc8cd85e87993ff21cb01eb333ff42afb058551  Merge pull request #355 from pschatzmann/fix-buffer-handling
```

该提交已包含 PR #355（PipeWire / 浏览器场景下的 buffer 处理修复）。
在此之前 `pschatzmann/macbook-camera` 的打包脚本指向的是
`pschatzmann/facetimehd` 的 `fix-buffer-handling` 分支；由于上游已合并该 PR，
本仓库直接使用上游 master，不需要额外分支。

**本仓库在该代码之上做的改动：**

- 验证并适配 kernel 7.0.0-38（本机内核），编译零 error 零 warning
- 补充 `dkms.conf` 的安装流程，使其能在 Ubuntu 26.04 上自动重建

## 固件提取

**patjak/facetimehd-firmware** — <https://github.com/patjak/facetimehd-firmware>

- 作者：Patrik Jakobsson
- 许可：GPLv2
- 内容：从 Apple macOS 更新包中提取 ISP 固件与传感器标定 set 文件的脚本，
  含全部偏移量与 sha256 校验值。

**本仓库在此之上做的改动：**

- 重写为 `tools/fetch-firmware.sh`，补充中文注释与参数
- 固件提取物**入库**到 `firmware/`，使安装完全离线可复现
- 保留上游的全部 sha256 硬校验

## 打包安装脚本

**pschatzmann/macbook-camera** — <https://github.com/pschatzmann/macbook-camera>

- 作者：Peter Schatzmann
- 许可：见其仓库
- 内容：把驱动 + 固件打包成一条命令安装流程的参考实现。

**本仓库在此之上做的改动：**

- 重写为 `scripts/install.sh` + `scripts/build.sh` + `scripts/verify.sh`
- 改为从本仓库 `firmware/` 安装（不再依赖运行时下载）

---

## Apple 侧材料

`artifacts/apple-camera-interface` 是从 macOS 10.12.6 官方组合更新包中提取的
`AppleCameraInterface.kext`。它是 **Apple 的专有作品**，版权归 Apple 所有，
在本仓库中仅作为**交叉审计的 ground truth** 使用。

同样的提取产物被放在 `firmware/firmware.bin`（ISP 固件）与
`firmware/*_01XX.dat`（传感器标定）——这些文件是加载驱动所必需的，
版权归 Apple，仅供本机硬件使用。
