#!/usr/bin/env bash
# ============================================================
# 产物自检：把镜像挂起来逐项断言，任何一项不合格就 fail
# ============================================================
set -uo pipefail

IMG_GZ="${1:?用法: verify-image.sh <xxx.img.gz>}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/pins.env"

W=$(mktemp -d)
IMG="$W/test.img"
BOOT="$W/boot"; ROOT="$W/root"
mkdir -p "$BOOT" "$ROOT"
FAIL=0
ok()   { echo "  ✅ $*"; }
bad()  { echo "  ❌ $*"; FAIL=$((FAIL+1)); }
chk()  { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

cleanup() {
    mountpoint -q "$BOOT" && umount "$BOOT" || true
    mountpoint -q "$ROOT" && umount "$ROOT" || true
    [ -n "${LOOP:-}" ] && losetup -d "$LOOP" 2>/dev/null || true
    rm -rf "$W"
}
trap cleanup EXIT

echo "==== 解压镜像 ===="
gunzip -c "$IMG_GZ" > "$IMG" || { echo "❌ 解压失败"; exit 1; }
echo "  解压后大小: $(stat -c%s "$IMG" | awk '{printf "%.0f MiB\n", $1/1048576}')"

echo "==== 挂载 ===="
LOOP=$(losetup -P -f --show "$IMG") || { echo "❌ losetup 失败"; exit 1; }
sleep 1
mount -t vfat  "${LOOP}p1" "$BOOT" || { echo "❌ bootfs 挂载失败"; exit 1; }
mount -t btrfs "${LOOP}p2" "$ROOT" || { echo "❌ rootfs 挂载失败"; exit 1; }

echo
echo "==== bootfs 断言 ===="
for f in zImage uInitrd uEnv.txt boot.scr s905_autoscript u-boot.ext "dtb/amlogic/$FDTFILE"; do
    chk "存在 $f" "[ -s '$BOOT/$f' ]"
done
chk "uEnv 的 FDT 指向 N1 dtb" "grep -q 'FDT=/dtb/amlogic/$FDTFILE' '$BOOT/uEnv.txt'"
chk "uEnv 用 UUID 挂根" "grep -q 'root=UUID=' '$BOOT/uEnv.txt'"

echo
echo "==== rootfs 断言 ===="
ROOT_UUID_FSTAB=$(awk '/^UUID=/{print $1}' "$ROOT/etc/fstab" 2>/dev/null | head -1)
ROOT_UUID_UENV=$(sed -n 's/.*root=\(UUID=[^ ]*\).*/\1/p' "$BOOT/uEnv.txt")
chk "fstab 与 uEnv 的根 UUID 一致" "[ -n '$ROOT_UUID_FSTAB' ] && [ '$ROOT_UUID_FSTAB' = '$ROOT_UUID_UENV' ]"
chk "network 只有 wan/dhcp（无 lan 接口）" "! grep -q \"config interface 'lan'\" '$ROOT/etc/config/network' && grep -q \"option proto 'dhcp'\" '$ROOT/etc/config/network'"
chk "firewall WAN 全开" "grep -q \"option forward 'ACCEPT'\" '$ROOT/etc/config/firewall'"
chk "uci-defaults 兜底脚本在" "[ -s '$ROOT/etc/uci-defaults/99-n1-sidecar' ]"
chk "pw2-install.sh 在" "[ -s '$ROOT/root/pw2-install.sh' ]"
chk "内核模块已装入" "[ -d '$ROOT/lib/modules' ] && [ \"\$(ls '$ROOT/lib/modules' | wc -l)\" -ge 1 ]"
chk "modules.dep 存在" "[ -s \"\$(ls -d '$ROOT'/lib/modules/*/modules.dep | head -1)\" ]"
chk "tproxy 模块在（passwall2 依赖）" "find '$ROOT/lib/modules' -name 'nft_tproxy.ko*' | grep -q ."
chk "tun 模块在（passwall2 依赖）" "find '$ROOT/lib/modules' -name 'tun.ko*' | grep -q ."
PKG=$(grep -c '^Package:' "$ROOT/usr/lib/opkg/status" 2>/dev/null || echo 0)
echo "  包数: $PKG"
for p in docker dockerd containerd ttyd; do
    chk "不该有的包 $p 确实没有" "! grep -q '^Package: $p\$' '$ROOT/usr/lib/opkg/status'"
done

echo
echo "==== 结果 ===="
if [ "$FAIL" -eq 0 ]; then
    echo "✅ 全部通过（0 项失败）"
else
    echo "❌ $FAIL 项失败"
    exit 1
fi
