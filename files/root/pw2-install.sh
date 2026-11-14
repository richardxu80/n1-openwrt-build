#!/bin/sh
# ============================================================
# PassWall2 一键安装 · N1 / OpenWrt 24.10 / aarch64
#   - 默认走国内 GitHub 镜像，无需代理
#   - 每个请求逐镜像故障转移，断了自动换下一个
#   - 【默认不使用任何代理】只有显式 PW2_PROXY 才走代理
# ============================================================
# 用法:
#   sh /root/pw2-install.sh                    # 自动取最新版，走国内镜像
#   sh /root/pw2-install.sh 26.11.11 1         # 指定版本 + 构建号
#   PW2_DRY=1 sh /root/pw2-install.sh          # 只探测，不下载不安装
#   PW2_PROXY=http://127.0.0.1:1082 sh /root/pw2-install.sh   # 显式走代理
#   PW2_MIRROR=https://gh-proxy.com/ sh /root/pw2-install.sh  # 指定单镜像
# ============================================================
set -u

REPO="Openwrt-Passwall/openwrt-passwall2"
GH="https://github.com/$REPO"
API="https://api.github.com/repos/$REPO/releases/latest"

MIRRORS="https://gh-proxy.com/ https://hk.gh-proxy.com/ https://ghproxy.net/ https://ghfast.top/ https://gh.llkk.cc/"
PROXY="${PW2_PROXY:-}"
C_OPTS="--connect-timeout 6 --speed-limit 4096 --speed-time 30"
RETRY="--retry 2 --retry-delay 1 --retry-all-errors"
TMP=/tmp/pw2-install
SRCFILE=/tmp/pw2.src
GOOD=""

# ---------- 架构检测 ----------
ARCH=$(grep -o "DISTRIB_ARCH='[^']*'" /etc/openwrt_release 2>/dev/null | cut -d"'" -f2)
if [ -z "${ARCH:-}" ]; then
    ARCH=$(opkg print-architecture 2>/dev/null | awk '{print $2}' | grep -E '^(aarch64|arm_|x86)' | tail -1)
fi
[ -z "${ARCH:-}" ] && { echo "❌ 无法识别架构(/etc/openwrt_release 无 DISTRIB_ARCH)"; exit 1; }
echo "▶ 架构: $ARCH"

if [ -n "$PROXY" ]; then
    echo "▶ 通道: 代理直连  $PROXY"
else
    echo "▶ 通道: 国内镜像(逐源故障转移)"
    [ -n "${PW2_MIRROR:-}" ] && MIRRORS="$PW2_MIRROR"
fi

_order() {
    if [ -n "$GOOD" ]; then printf '%s\n' "$GOOD $MIRRORS"; else printf '%s\n' "$MIRRORS"; fi
}

# ---------- 取文本(带故障转移；无隐式代理) ----------
net_text() {
    _u="$1"; _mt="${2:-20}"
    if [ -n "$PROXY" ]; then
        curl -fsL $RETRY $C_OPTS --max-time "$_mt" -x "$PROXY" "$_u" 2>/dev/null && return 0
        return 1
    fi
    for _m in $(_order); do
        if _t=$(curl -fsL $RETRY $C_OPTS --max-time "$_mt" "${_m}${_u}" 2>/dev/null) && [ -n "$_t" ]; then
            GOOD="$_m"; echo "$_m" > "$SRCFILE"; printf '%s' "$_t"; return 0
        fi
    done
    return 1
}

# ---------- 下文件(带故障转移；无隐式代理) ----------
net_file() {
    _u="$1"; _o="$2"; _mt="${3:-300}"; _min="${4:-1024}"
    if [ -n "$PROXY" ]; then
        rm -f "$_o"
        curl -fsSL $RETRY $C_OPTS --max-time "$_mt" -x "$PROXY" -o "$_o" "$_u" 2>/dev/null
        [ -s "$_o" ] && [ "$(wc -c < "$_o")" -ge "$_min" ] && return 0
        rm -f "$_o"; return 1
    fi
    for _m in $(_order); do
        rm -f "$_o"
        if curl -fsSL $RETRY $C_OPTS --max-time "$_mt" -o "$_o" "${_m}${_u}" 2>/dev/null; then
            if [ -s "$_o" ] && [ "$(wc -c < "$_o")" -ge "$_min" ]; then
                GOOD="$_m"; echo "$_m" > "$SRCFILE"; return 0
            fi
        fi
        echo "  · 源失败，换下一个: $_m" >&2
        rm -f "$_o"
    done
    return 1
}

# ---------- 解析版本 ----------
if [ -n "${1:-}" ] && [ -n "${2:-}" ]; then
    VER="$1"; REL="$2"
else
    TAG=$(net_text "$API" 15 2>/dev/null | grep -m1 '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/' || true)
    if [ -z "${TAG:-}" ]; then
        TAG=$(net_text "$GH/releases.atom" 15 2>/dev/null | grep -m2 '<title>' | tail -1 \
              | sed -E 's/.*<title>([^<]+)<\/title>.*/\1/' || true)
    fi
    [ -z "${TAG:-}" ] && { echo "❌ 获取最新 tag 失败(镜像不可用)。可: ①PW2_MIRROR=指定镜像 ②PW2_PROXY=走代理 ③手动传版本号"; exit 1; }
    VER="${TAG%-*}"; REL="${TAG#*-}"
fi
echo "▶ 目标版本: $VER  构建: r$REL"

CUR=$(opkg list-installed 2>/dev/null | awk '/^luci-app-passwall2 /{print $3}' || true)
echo "▶ 当前安装: ${CUR:-无}"
[ -n "$GOOD" ] && echo "▶ 当前可用镜像: $GOOD"

F_APP="luci-app-passwall2_${VER}-r${REL}_all.ipk"
F_I18N="luci-i18n-passwall2-zh-cn_${VER}_all.ipk"
F_PKGS="packages_ipk_${ARCH}.zip"
URL="$GH/releases/download/$VER-$REL"

if [ "${PW2_DRY:-0}" = "1" ]; then
    echo "▶ DRY 模式: 仅探测，不下载不安装"
    echo "  下载地址示例: ${GOOD:-$MIRRORS}$URL/$F_PKGS"
    exit 0
fi

mkdir -p "$TMP"; cd "$TMP" || exit 1
rm -f ./*.ipk ./*.zip 2>/dev/null || true

echo "▶ 下载(依赖包约 50MB)..."
net_file "$URL/$F_APP"  "$F_APP"  180 1024    || { echo "❌ luci-app 下载失败(所有源均不可用)"; exit 1; }
echo "  ✓ $F_APP"
net_file "$URL/$F_I18N" "$F_I18N" 180 512     || { echo "❌ 中文语言包下载失败"; exit 1; }
echo "  ✓ $F_I18N"
net_file "$URL/$F_PKGS" "$F_PKGS" 900 1048576 || { echo "❌ 依赖包下载失败(50MB，检查网络或换镜像)"; exit 1; }
echo "  ✓ $F_PKGS ($(wc -c < "$F_PKGS") 字节)"

echo "▶ 完整性校验..."
for f in ./*.ipk; do
    tar tzf "$f" >/dev/null 2>&1 || { echo "❌ $f 损坏(非合法 ipk)"; exit 1; }
done
unzip -tqq "$F_PKGS" >/dev/null 2>&1 || { echo "❌ 依赖包 zip 损坏"; exit 1; }
echo "  ✓ 校验通过"

echo "▶ 解压依赖包..."
unzip -oq "$F_PKGS" || { echo "❌ 解压失败"; exit 1; }

echo "▶ opkg update(拉依赖索引)..."
opkg update >/dev/null 2>&1 || echo "  (opkg update 警告，继续)"

echo "▶ 安装..."
if ! opkg install ./*.ipk; then
    echo "⚠ 常规安装失败，改用 --force-depends 重试"
    opkg install --force-depends ./*.ipk || { echo "❌ 安装失败"; exit 1; }
fi

echo "▶ 清理临时包..."
rm -f ./*.ipk ./*.zip 2>/dev/null || true

echo "▶ 启用并重启 passwall2..."
/etc/init.d/passwall2 enable 2>/dev/null || true
/etc/init.d/passwall2 restart 2>/dev/null || true
sleep 2

NEW=$(opkg list-installed 2>/dev/null | awk '/^luci-app-passwall2 /{print $3}' || true)
echo "✓ 完成，现版本: ${NEW:-未知}"
echo "  下一步: 浏览器 LuCI → 服务 → PassWall2 → 配置节点/订阅，然后开启"
