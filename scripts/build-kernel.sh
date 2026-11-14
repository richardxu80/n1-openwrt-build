#!/usr/bin/env bash
# ============================================================
# 自编内核 6.12.y（Phicomm N1 / Amlogic GXL）
#   源码：ophub/linux-6.12.y（unifreq 内核，主线 + amlogic 支持）
#   配置：本仓库 kernel/config-6.12（phonub 官方 config 的 vendor 副本）
#   产物：boot-<ver>.tar.gz / dtb-amlogic-<ver>.tar.gz / modules-<ver>.tar.gz
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/pins.env"

OUT="${OUT:-$HERE/out/kernel}"
WORK="${WORK:-$PWD/work-kernel}"
ARCH=arm64
XC=aarch64-linux-gnu-
JOBS="${JOBS:-$(nproc)}"

mkdir -p "$OUT" "$WORK"
step() { echo; echo "==== $* ===="; }

step "1/6 拉源码 $KSRC_REPO @ $KSRC_REF"
if [ ! -d "$WORK/linux/.git" ]; then
    git init -q "$WORK/linux"
    cd "$WORK/linux"
    git remote add origin "$KSRC_REPO"
    # GitHub 不一定允许按 sha 浅取；失败就退回 main 最新
    if git fetch -q --depth=1 origin "$KSRC_REF" 2>/dev/null; then
        git checkout -q FETCH_HEAD
        echo "已锁定到 $KSRC_REF"
    else
        git fetch -q --depth=1 origin main
        git checkout -q FETCH_HEAD
        echo "⚠ 无法按 sha 取到 $KSRC_REF，退回 main HEAD：$(git rev-parse HEAD)"
    fi
else
    cd "$WORK/linux"
fi
KVER_SHORT=$(make -s kernelversion 2>/dev/null || true)
echo "源码版本: $KVER_SHORT ($(git rev-parse --short HEAD))"

step "2/6 装配置并打上我们的标记"
cp -f "$HERE/kernel/config-6.12" .config
# 清掉可能残留的 LOCALVERSION，加上我们自己的后缀，产物可辨识
sed -i 's|^CONFIG_LOCALVERSION=.*|CONFIG_LOCALVERSION="-n1"|' .config
# 确保 btrfs/以太网内建（N1 单臂 btrfs 根，不能靠 initrd）
for opt in CONFIG_BTRFS_FS CONFIG_BTRFS_FS_POSIX_ACL CONFIG_DWMAC_MESON CONFIG_STMMAC_ETH \
           CONFIG_ZSTD_COMPRESS CONFIG_ZSTD_DECOMPRESS CONFIG_BLK_DEV_INITRD; do
    grep -q "^${opt}=y$" .config || echo "${opt}=y" >> .config
done
# 不允许模块签名强制（否则我们编的模块在设备上加载不了）
sed -i 's|^CONFIG_MODULE_SIG_FORCE=.*|# CONFIG_MODULE_SIG_FORCE is not set|' .config
sed -i 's|^CONFIG_INITRAMFS_SOURCE=.*|CONFIG_INITRAMFS_SOURCE=""|' .config

step "3/6 olddefconfig 收敛配置"
make ARCH=$ARCH CROSS_COMPILE=$XC olddefconfig >/dev/null

KREL=$(make -s ARCH=$ARCH CROSS_COMPILE=$XC kernelrelease)
echo "内核 release: $KREL"

step "4/6 编译 Image + modules + dtbs (jobs=$JOBS)"
make -j"$JOBS" ARCH=$ARCH CROSS_COMPILE=$XC Image modules dtbs

step "5/6 安装模块到 staging + strip + depmod"
rm -rf "$WORK/staging"
make ARCH=$ARCH CROSS_COMPILE=$XC INSTALL_MOD_PATH="$WORK/staging" modules_install
find "$WORK/staging/lib/modules/$KREL" -name '*.ko' -exec ${XC}strip --strip-unneeded {} + 2>/dev/null || true
rm -f "$WORK/staging/lib/modules/$KREL"/{build,source} 2>/dev/null || true
depmod -b "$WORK/staging" "$KREL" 2>/dev/null || true

step "6/6 打包"
KDIR="$WORK/pkg"; rm -rf "$KDIR"; mkdir -p "$KDIR/boot" "$KDIR/dtb" "$KDIR/empty"

# boot: vmlinuz / config / System.map
cp -f arch/$ARCH/boot/Image "$KDIR/boot/vmlinuz-$KREL"
cp -f .config                    "$KDIR/boot/config-$KREL"
cp -f System.map                 "$KDIR/boot/System.map-$KREL"
# 空 uInitrd：booti 需要一个 ramdisk 参数，btrfs/以太网都是内建，空 cpio 即可
( cd "$KDIR/empty" && find . | cpio -o -H newc --quiet | gzip -9 > "$KDIR/boot/uInitrd-$KREL" )
# dtb: 全部 amlogic
cp -f arch/$ARCH/boot/dts/amlogic/*.dtb "$KDIR/dtb/"

tar -czf "$OUT/boot-$KREL.tar.gz"        -C "$KDIR/boot" .
tar -czf "$OUT/dtb-amlogic-$KREL.tar.gz" -C "$KDIR/dtb"  .
tar -czf "$OUT/modules-$KREL.tar.gz"     -C "$WORK/staging" lib

cd "$OUT"
sha256sum ./*.tar.gz > sha256sums
echo
echo "==== 产物 ===="
ls -lh "$OUT"
echo
echo "KERNEL_RELEASE=$KREL" | tee "$OUT/release.env"
