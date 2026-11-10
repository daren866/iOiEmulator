#!/usr/bin/env bash
#
# fetch-android-guest.sh — 路线 2 的「首次启动下载」
# ---------------------------------------------------------------------------
# 下载并解包安卓 4.0（API 15, ICS）的【用户空间镜像】（system/ramdisk/userdata），
# 供 UTM 上游 QEMU 的 -machine vexpress-a15（默认）启动使用。
#
# 与路线 1 的区别：
#   - 不再使用官方包里的 kernel-qemu（它是 goldfish 内核，vexpress/virt 上跑不起来）。
#   - 内核必须由 scripts/build-android-virt-kernel.sh 单独产出（默认 vexpress-a15 编译），
#     或放到 KERNEL_URL 指向的预编译产物。本脚本只负责用户空间部分 + 生成 manifest。
#
# 用法：bash scripts/fetch-android-guest.sh [OUT_DIR]
# 环境变量：OUT_DIR / CACHE_DIR / KERNEL_URL（可选，预编译 zImage+dtb 的 zip）
set -o pipefail

OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")/.." && pwd)/Android40}"
CACHE_DIR="${CACHE_DIR:-$(cd "$(dirname "$0")/.." && pwd)/.cache/android-images}"
SYSIMG_URL="${SYSIMG_URL:-https://dl.google.com/android/repository/sys-img/android/sysimg_armv7a-15_r03.zip}"
SYSIMG_NAME="sysimg_armv7a-15_r03.zip"
SYSIMG_EXPECT=96240395

mirror() {
  local u="$1"; printf '%s\n' "$u"
  case "$u" in
    https://dl.google.com/*)
      printf '%s\n' "https://gh-proxy.com/$u" "https://v4.gh-proxy.org/$u" "https://mirror.ghproxy.com/$u";;
  esac
}
say() { echo "  $*"; }
die() { echo "::error::$*" >&2; exit 1; }
flsz() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

dl() {
  local expect="$1" out="$2" url="$3" tmp="$out.part" sz u
  rm -f "$tmp"
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    say "↳ $u"
    if curl -fL --retry-all-errors --retry 5 --retry-delay 3 --retry-max-time 300 \
            --connect-timeout 20 --max-time 1200 -o "$tmp" "$u" 2>/dev/null; then
      sz="$(flsz "$tmp")"
      [ "$sz" -lt 32 ] && { say "  ⚠ 过小，换源"; rm -f "$tmp"; continue; }
      [ -n "$expect" ] && [ "$sz" != "$expect" ] && { say "  ⚠ 大小不符，换源"; rm -f "$tmp"; continue; }
      mv -f "$tmp" "$out"; say "✓ 落盘 $((sz/1024/1024)) MiB"; return 0
    fi
    say "  ✗ 失败，换源"
  done < <(mirror "$url")
  rm -f "$tmp"; return 1
}

mkdir -p "$OUT_DIR" "$CACHE_DIR"

SYSIMG="$CACHE_DIR/$SYSIMG_NAME"
if [ -f "$SYSIMG" ] && [ "$(flsz "$SYSIMG")" = "$SYSIMG_EXPECT" ]; then
  say "系统镜像已缓存"
else
  say "下载 ARM 系统镜像（期望 $((SYSIMG_EXPECT/1024/1024)) MiB）"
  dl "$SYSIMG_EXPECT" "$SYSIMG" "$SYSIMG_URL" || die "系统镜像下载失败"
fi

say "解包用户空间到 $OUT_DIR"
TMP="$(mktemp -d)"
unzip -q -o "$SYSIMG" -d "$TMP" || die "解包失败"
SRC="$(find "$TMP" -type d -name 'armeabi-v7a' | head -n1)"
[ -n "$SRC" ] || die "找不到 armeabi-v7a 目录"

# 路线 2：只要用户空间（system/ramdisk/userdata）。kernel-qemu 是 goldfish 的，跳过。
for f in system.img ramdisk.img userdata.img; do
  [ -f "$SRC/$f" ] || die "缺少 $f"
  cp -f "$SRC/$f" "$OUT_DIR/$f"
done
[ -f "$SRC/build.prop" ] && cp -f "$SRC/build.prop" "$OUT_DIR/build.prop"

# 可选：预编译内核 + dtb（若提供 KERNEL_URL）—— 默认 vexpress-a15，QEMU 自带 dtb
if [ -n "${KERNEL_URL:-}" ]; then
  KZ="$CACHE_DIR/android40-vexpress-kernel.zip"
  say "下载预编译 vexpress-a15 内核 ($KERNEL_URL)"
  dl "" "$KZ" "$KERNEL_URL" || say "::warning::内核下载失败，请改用 build-android-virt-kernel.sh 本地编译"
  if [ -f "$KZ" ]; then
    unzip -q -o "$KZ" -d "$OUT_DIR" || true
    say "已放入内核（zImage；vexpress-a15 由 QEMU 自带 dtb）"
  fi
fi
rm -rf "$TMP"

cat > "$OUT_DIR/manifest.json" <<EOF
{
  "android_version": "4.0.3",
  "api_level": 15,
  "abi": "armeabi-v7a",
  "machine": "vexpress-a15 (默认；备选 -machine virt 需 ARCH_VIRT 反向移植)",
  "userspace_images": ["system.img", "ramdisk.img", "userdata.img"],
  "kernel": "由 scripts/build-android-virt-kernel.sh 产出 zImage（vexpress-a15 由 QEMU 自带 dtb；不可用官方 kernel-qemu）",
  "note": "路线2：用 UTM 上游 QEMU 的 -machine vexpress-a15 启动；内核需为 vexpress-a15 单独编译。",
  "source": { "system_image": "$SYSIMG_URL" }
}
EOF

say "完成。用户空间位于: $OUT_DIR"
ls -lh "$OUT_DIR" | sed 's/^/    /'
echo "FETCH_OK"
