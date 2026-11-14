# N1 OpenWrt 自建流水线

斐讯 N1（Amlogic S905D，2G/8G）单臂旁路由镜像，**全链路自建**：不依赖 ophub 的 `remake` 打包脚本，内核自己编译。

## 为什么自己写

| 环节 | 原方案 | 本仓库 |
|---|---|---|
| rootfs | ophub 的 `imagebuilder.sh` + 91 个包的全家桶 | 官方 ImageBuilder + 我们自己的包清单 |
| 内核 | 下载 ophub 预编译二进制 | **从源码交叉编译**，配置 vendor 在仓内 |
| 打包 | ophub `remake`（1396 行，3 平台数百板型） | 自写 `pack-n1.sh`，只做 N1 |
| 镜像额外内容 | ophub common-files 全套（banner/sysinfo/wifi/regulatory…） | 只留 N1 启动与安装必需 |

## 三段式流水线

```
.github/workflows/build.yml
├─ kernel  job → scripts/build-kernel.sh  → out/kernel/{boot,dtb-amlogic,modules}-<ver>.tar.gz
├─ rootfs  job → scripts/build-rootfs.sh  → out/rootfs/rootfs.tar.gz
└─ image   job → scripts/pack-n1.sh       → out/image/openwrt_n1_<ver>_<date>.img.gz
                 scripts/verify-image.sh  → 挂载镜像逐项断言，任一失败就 fail
```

kernel 最慢（约 40–90 分钟），rootfs 约 8 分钟，打包+自检约 5 分钟。

## 关键事实（有代码/产物依据）

**内核怎么编的**
- 源码 `ophub/linux-6.12.y`（unifreq 的 amlogic 主线内核，分支 `main`），按 `pins.env` 的 commit 锁定
- 配置 `kernel/config-6.12`（vendor 自 `ophub/kernel` 的 `kernel-config/release/stable/config-6.12`，10074 行，不是 defconfig）
- 交叉编译：`ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-`，`make Image modules dtbs`
- 我们的改动：`CONFIG_LOCALVERSION="-n1"`；确保 `BTRFS_FS=y`、`DWMAC_MESON=y`、`ZSTD_*=y` 内建；禁止 `MODULE_SIG_FORCE`
- `uInitrd` 是**空 cpio**：`booti` 必须有 ramdisk 参数，但根文件系统、btrfs、网卡驱动全是内建，不需要真 initramfs

**N1 启动链**（来自 `model_database.conf` id=101 + `remake` 实测）
```
跳过区 4MiB : dd u-boot-2015-phicomm-n1.bin（4194304 字节）
p1 FAT32   : u-boot.ext(=u-boot-n1.bin) ← 2015 u-boot 通过 s905_autoscript 链加载
             boot.scr → uEnv.txt → zImage + uInitrd + dtb → booti
p2 BTRFS   : OpenWrt rootfs，/etc 建 btrfs 子卷，rootflags=compress=zstd:6
```

## 用法

Actions 里点 `Build N1 OpenWrt` → Run workflow。产物在 `n1-openwrt-image` artifact 或自动发的 Release。刷机前先比对 sha256。

## 输入文件

| 路径 | 作用 |
|---|---|
| `pins.env` | 上游 commit / 版本 / N1 板级参数唯一真源 |
| `kernel/config-6.12` | vendored 内核配置 |
| `config/packages.txt` | rootfs 包清单 |
| `files/` | 覆盖进 rootfs 的文件（network/firewall/dhcp/uci-defaults/pw2-install.sh） |
| `bootfs/boot.cmd`、`s905_autoscript.cmd` | u-boot 脚本源（构建时 mkimage 编译成 .scr） |
| `rootfs-extra/` | fstab / inittab / amlogic 配置模板（打包时按实际 UUID 填充） |

## 已知边界

- 只支持 N1（S905D）。换板子要改 `pins.env` 的 `FDTFILE`、u-boot 文件名、分区尺寸。
- u-boot 二进制是唯一仍来自 ophub 的部件（自编收益极低，刷坏要 USB Burning Tool 救）。按 commit 拉取并校验字节数。
- `verify-image.sh` 只能证明**结构正确**，不能证明**能开机**；后者只能实机验证。
