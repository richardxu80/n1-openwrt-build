#!/usr/bin/env bash
# ============================================================
# 自建 rootfs：OpenWrt 官方 ImageBuilder（只信官方源 + 校验 sha256）
#   产物：rootfs.tar.gz（可直接被 pack-n1.sh 吃掉）
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/pins.env"

OUT="${OUT:-$HERE/out/rootfs}"
WORK="${WORK:-$PWD/work-rootfs}"
B="$OPENWRT_VER"
BASE="https://downloads.openwrt.org/releases/${B}/targets/${OPENWRT_TARGET}"
IB="openwrt-imagebuilder-${B}-armsr-armv8.Linux-x86_64.tar.xz"

step() { echo; echo "==== $* ===="; }
mkdir -p "$OUT" "$WORK"

step "1/5 下载官方 ImageBuilder 并校验 sha256"
cd "$WORK"
if [ ! -f "$IB" ]; then
    curl -fsSL --retry 3 --connect-timeout 15 -O "$BASE/$IB"
fi
curl -fsSL --retry 3 --connect-timeout 15 -o sha256sums "$BASE/sha256sums"
WANT=$(awk -v f="$IB" '$2==f {print $1}' sha256sums)
[ -n "$WANT" ] || { echo "❌ 官方 sha256sums 里找不到 $IB"; exit 1; }
GOT=$(sha256sum "$IB" | awk '{print $1}')
[ "$WANT" = "$GOT" ] || { echo "❌ ImageBuilder 校验失败 want=$WANT got=$GOT"; exit 1; }
echo "✅ ImageBuilder sha256 = $GOT"

step "2/5 解包"
[ -d "${IB%.tar.xz}" ] || tar -xf "$IB"
IBD="$WORK/${IB%.tar.xz}"
cd "$IBD"

step "3/5 放入本地 ipk（luci-app-amlogic，官方 feed 里没有）"
mkdir -p packages
AL_URL="https://github.com/ophub/luci-app-amlogic/releases/download/26.11.0801-js"
for f in luci-app-amlogic_26.11.0801-r2_all.ipk luci-i18n-amlogic-zh-cn_0_all.ipk; do
    if [ ! -s "packages/$f" ]; then
        curl -fsSL --retry 3 --connect-timeout 15 -o "packages/$f" "$AL_URL/$f" || {
            echo "⚠ 下载失败: $f（可去掉该包继续，但会失去 eMMC 安装 UI）"; rm -f "packages/$f"; }
    fi
done
ls -lh packages/ || true

step "4/5 用我们的包清单 + files/ 覆盖层构建镜像"
PKGS=$(grep -vE '^\s*(#|$)' "$HERE/config/packages.txt" | tr '\n' ' ')
# 只把实际下载成功的本地 ipk 拼进去
for f in packages/*.ipk; do [ -s "$f" ] && PKGS="$PKGS $(basename "$f")"; done
echo "包清单: $PKGS"

rm -rf "$IBD/files"
cp -a "$HERE/files" "$IBD/files"

make image PROFILE="" PACKAGES="$PKGS" FILES="files"

step "5/5 收集 rootfs"
RF=$(ls bin/targets/armsr/armv8/*rootfs.tar.gz | head -1)
[ -s "$RF" ] || { echo "❌ 没产出 rootfs"; exit 1; }
cp -f "$RF" "$OUT/rootfs.tar.gz"
cd "$OUT" && sha256sum rootfs.tar.gz > sha256sums
ls -lh "$OUT"
