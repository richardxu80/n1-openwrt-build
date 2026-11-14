#!/usr/bin/env bash
# ============================================================
# 自写打包器：把 rootfs.tar.gz + 自编内核 + u-boot 拼成 N1 可刷镜像
#   N1 启动链：跳过区 4MiB(2015 u-boot) → BOOT(FAT32) → u-boot.ext(mainline)
#              → boot.scr → uEnv.txt → zImage + uInitrd + dtb → booti
#   分区：msdos / p1 FAT32 384MiB BOOT / p2 BTRFS ROOTFS
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/pins.env"

ROOTFS_TGZ="${ROOTFS_TGZ:?需要 ROOTFS_TGZ}"
KERNEL_DIR="${KERNEL_DIR:?需要 KERNEL_DIR（含 boot-/dtb-/modules-*.tar.gz）}"
OUT="${OUT:-$HERE/out/image}"
WORK="${WORK:-$PWD/work-pack}"
BOOTFS_DIR="${BOOTFS_DIR:-$HERE/bootfs}"
ROOTFS_EXTRA="${ROOTFS_EXTRA:-$HERE/rootfs-extra}"

mkdir -p "$OUT" "$WORK"
step() { echo; echo "==== $* ===="; }

# ---------- 0. 取 u-boot（按 pin 的 commit，校验大小） ----------
step "0/8 取 u-boot 二进制"
UB="$WORK/uboot"; mkdir -p "$UB"
fetch_ub() { # $1=仓库内路径 $2=本地名 $3=期望字节数
    if [ ! -s "$UB/$2" ]; then
        curl -fsSL --retry 3 -o "$UB/$2" \
          "https://raw.githubusercontent.com/ophub/u-boot/${UBOOT_REF}/$1"
    fi
    local got; got=$(stat -c%s "$UB/$2")
    [ "$got" = "$3" ] || { echo "❌ $2 大小异常 got=$got want=$3"; exit 1; }
    echo "  ✅ $2 ($got 字节)"
}
fetch_ub "u-boot/amlogic/bootloader/u-boot-2015-phicomm-n1.bin" "u-boot-2015-phicomm-n1.bin" 4194304
fetch_ub "u-boot/amlogic/overload/u-boot-n1.bin"               "u-boot-n1.bin"                702771

# ---------- 1. 定位内核包 ----------
step "1/8 定位内核产物"
BOOT_TGZ=$(ls "$KERNEL_DIR"/boot-*.tar.gz | head -1)
KREL="${BOOT_TGZ##*/boot-}"; KREL="${KREL%.tar.gz}"
DTB_TGZ="$KERNEL_DIR/dtb-amlogic-$KREL.tar.gz"
MOD_TGZ="$KERNEL_DIR/modules-$KREL.tar.gz"
[ -s "$DTB_TGZ" ] || { echo "❌ 缺 $DTB_TGZ"; exit 1; }
[ -s "$MOD_TGZ" ] || { echo "❌ 缺 $MOD_TGZ"; exit 1; }
echo "  内核: $KREL"

# ---------- 2. 造镜像文件与分区 ----------
step "2/8 造镜像 + 分区（skip ${SKIP_MB} / boot ${BOOT_MB} / root ${ROOT_MB} MiB）"
IMG="$WORK/openwrt_n1_${KREL}_$(date +%Y.%m.%d).img"
rm -f "$IMG"
IMG_SIZE=$((SKIP_MB + BOOT_MB + ROOT_MB))
truncate -s ${IMG_SIZE}M "$IMG"
parted -s "$IMG" mklabel msdos
parted -s "$IMG" mkpart primary fat32 $((SKIP_MB))MiB $((SKIP_MB + BOOT_MB - 1))MiB
parted -s "$IMG" mkpart primary btrfs $((SKIP_MB + BOOT_MB))MiB 100%

LOOP=$(losetup -P -f --show "$IMG")
cleanup() {
    sync
    mountpoint -q "$WORK/rootfs" && umount "$WORK/rootfs" || true
    mountpoint -q "$WORK/bootfs" && umount "$WORK/bootfs" || true
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
}
trap cleanup EXIT
echo "  loop=$LOOP"
sleep 1

ROOTFS_UUID=$(cat /proc/sys/kernel/random/uuid)
BOOT_UUID=$(cat /proc/sys/kernel/random/uuid)
mkfs.vfat -F 32 -n BOOT "${LOOP}p1" >/dev/null
mkfs.btrfs -f -U "$ROOTFS_UUID" -L ROOTFS -m single "${LOOP}p2" >/dev/null
echo "  ROOTFS UUID: $ROOTFS_UUID"

# ---------- 3. 写 2015 引导 ----------
step "3/8 写跳过区引导（u-boot-2015-phicomm-n1.bin）"
dd if="$UB/u-boot-2015-phicomm-n1.bin" of="$LOOP" conv=fsync bs=1   count=444 2>/dev/null
dd if="$UB/u-boot-2015-phicomm-n1.bin" of="$LOOP" conv=fsync bs=512 skip=1 seek=1 2>/dev/null
echo "  ✅ 已写入"

# ---------- 4. 挂载并铺 rootfs ----------
step "4/8 铺 rootfs（btrfs + /etc 子卷）"
mkdir -p "$WORK/rootfs" "$WORK/bootfs"
mount -t btrfs "${LOOP}p2" "$WORK/rootfs"
btrfs subvolume create "$WORK/rootfs/etc" >/dev/null
tar -mxzf "$ROOTFS_TGZ" -C "$WORK/rootfs"
rm -rf "$WORK/rootfs/lib/modules"/* 2>/dev/null || true
mkdir -p "$WORK/rootfs/.reserved" "$WORK/rootfs/boot" "$WORK/rootfs/run"

# ophub 风格的 fstab / inittab / amlogic 配置
[ -d "$ROOTFS_EXTRA" ] && cp -a "$ROOTFS_EXTRA/." "$WORK/rootfs/"
sed -i "s|LABEL=ROOTFS|UUID=${ROOTFS_UUID}|g" "$WORK/rootfs/etc/fstab"
sed -i "s|option amlogic_kernel_tags.*|option amlogic_kernel_tags 'kernel_stable'|g" \
       "$WORK/rootfs/etc/config/amlogic" 2>/dev/null || true
sed -i "s|option amlogic_kernel_branch.*|option amlogic_kernel_branch '6.12'|g" \
       "$WORK/rootfs/etc/config/amlogic" 2>/dev/null || true

# ---------- 5. 装内核模块 ----------
step "5/8 安装内核模块 /lib/modules/$KREL"
tar -mxzf "$MOD_TGZ" -C "$WORK/rootfs"
[ -d "$WORK/rootfs/lib/modules/$KREL" ] || { echo "❌ 模块目录不存在"; exit 1; }
echo "  模块数: $(find "$WORK/rootfs/lib/modules/$KREL" -name '*.ko' | wc -l)"

# ---------- 6. 铺 bootfs ----------
step "6/8 铺 bootfs（FAT32）"
mount -t vfat "${LOOP}p1" "$WORK/bootfs"
tar -mxzf "$BOOT_TGZ" -C "$WORK/bootfs"          # vmlinuz- / uInitrd- / config- / System.map-
mkdir -p "$WORK/bootfs/dtb/amlogic"
tar -mxzf "$DTB_TGZ" -C "$WORK/bootfs/dtb/amlogic"
cp -f "$WORK/bootfs/vmlinuz-$KREL" "$WORK/bootfs/zImage"
cp -f "$WORK/bootfs/uInitrd-$KREL" "$WORK/bootfs/uInitrd"
# mainline u-boot：2015 引导靠 u-boot.ext 链加载，emmc 安装脚本认 u-boot-n1.bin
cp -f "$UB/u-boot-n1.bin" "$WORK/bootfs/u-boot.ext"
cp -f "$UB/u-boot-n1.bin" "$WORK/bootfs/u-boot-n1.bin"

# uEnv.txt —— N1 专用，UUID 直接写死，不需要后续 sed
cat > "$WORK/bootfs/uEnv.txt" <<EOF
LINUX=/zImage
INITRD=/uInitrd
FDT=/dtb/amlogic/${FDTFILE}
APPEND=root=UUID=${ROOTFS_UUID} rootfstype=btrfs rootflags=compress=zstd:6 rw rootwait console=ttyAML0,115200n8 console=tty0 no_console_suspend consoleblank=0 max_loop=128
EOF

# 编译 u-boot 脚本
mkimage -C none -A arm -O linux -T script -d "$BOOTFS_DIR/boot.cmd"            "$WORK/bootfs/boot.scr"        >/dev/null
mkimage -C none -A arm -O linux -T script -d "$BOOTFS_DIR/s905_autoscript.cmd" "$WORK/bootfs/s905_autoscript" >/dev/null
echo "  ✅ bootfs 就绪"
ls "$WORK/bootfs" | tr '\n' ' '; echo

# ---------- 7. 收尾 ----------
step "7/8 卸载 + 压缩"
sync
umount "$WORK/bootfs"; umount "$WORK/rootfs"
losetup -d "$LOOP"; LOOP=""
gzip -9 -f "$IMG"
FINAL="$OUT/$(basename "$IMG").gz"
mv -f "$IMG.gz" "$FINAL"
cd "$OUT" && sha256sum "$(basename "$FINAL")" > "$(basename "$FINAL").sha256"
step "8/8 完成"
ls -lh "$FINAL"
cat "$FINAL.sha256"
