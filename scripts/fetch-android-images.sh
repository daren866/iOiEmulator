#!/usr/bin/env bash
#
# fetch-android-images.sh
# ---------------------------------------------------------------------------
# 下载并解包「安卓 4.0（API 15, Ice Cream Sandwich）」ARM 镜像包。
# 这两个包来自 Android SDK 仓库（dl.google.com），是官方 AVD 系统镜像：
#
#   1) ARM 系统镜像（核心，启动安卓必需）
#      armeabi-v7a 的 kernel-qemu / system.img / ramdisk.img / userdata.img
#      ~91.8 MB  https://dl.google.com/android/repository/sys-img/android/sysimg_armv7a-15_r03.zip
#
#   2) Platform 包（建 AVD / 写 App 用，启动安卓其实用不到，按需求一并下载）
#      ~42.5 MB  https://dl.google.com/android/repository/android-15_r05.zip
#
# 注：kernel-qemu 是 AOSP goldfish 内核，只能跑在「带 goldfish 机器的 QEMU」上。
#     UTM 用的是上游 QEMU（只有 virt/raspi），无法直接启动该镜像，详见 README。
#     本脚本只负责把镜像下载、校验、解包到统一目录，供后续 QEMU 启动使用。
# ---------------------------------------------------------------------------
set -o pipefail

# ---- 可调参数（环境变量覆盖）-----------------------------------------------
OUT_DIR="${OUT_DIR:-$(cd "$(dirname "$0")/.." && pwd)/Android40}"
CACHE_DIR="${CACHE_DIR:-$(cd "$(dirname "$0")/.." && pwd)/.cache/android-images}"
SYSIMG_URL="${SYSIMG_URL:-https://dl.google.com/android/repository/sys-img/android/sysimg_armv7a-15_r03.zip}"
PLATFORM_URL="${PLATFORM_URL:-https://dl.google.com/android/repository/android-15_r05.zip}"
SYSIMG_NAME="sysimg_armv7a-15_r03.zip"
PLATFORM_NAME="android-15_r05.zip"
SYSIMG_EXPECT=96240395      # 官方内容长度，下载后做大小校验
PLATFORM_EXPECT=44533475

# 多镜像回退（主源失败时尝试代理，避免单点超时）
mirror() {
  local u="$1"
  printf '%s\n' "$u"
  case "$u" in
    https://dl.google.com/*)
      printf '%s\n' "https://gh-proxy.com/$u" "https://v4.gh-proxy.org/$u" "https://mirror.ghproxy.com/$u";;
  esac
}

say() { echo "  $*"; }
die() { echo "::error::$*" >&2; exit 1; }

flsz() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

# 下载单个文件：多镜像回退 + 重试 + 大小校验。成功返回 0。
dl() {
  local expect="$1" out="$2" url="$3"
  local tmp="$out.part" sz u
  rm -f "$tmp"
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    say "↳ $u"
    if curl -fL --retry-all-errors --retry 5 --retry-delay 3 --retry-max-time 300 \
            --connect-timeout 20 --max-time 1200 -o "$tmp" "$u" 2>/dev/null; then
      sz="$(flsz "$tmp")"
      if [ "$sz" -lt 32 ]; then say "  ⚠ 过小($sz B)，视为错误页，换源"; rm -f "$tmp"; continue; fi
      if [ -n "$expect" ] && [ "$sz" != "$expect" ]; then
        say "  ⚠ 大小不符(期望 $expect，实际 $sz)，换源"; rm -f "$tmp"; continue
      fi
      mv -f "$tmp" "$out"
      say "✓ 落盘 $((sz/1024/1024)) MiB"
      return 0
    fi
    say "  ✗ 失败，换源"
  done < <(mirror "$url")
  rm -f "$tmp"
  return 1
}

mkdir -p "$OUT_DIR" "$CACHE_DIR"

# ---- 1) ARM 系统镜像（核心）------------------------------------------------
SYSIMG="$CACHE_DIR/$SYSIMG_NAME"
if [ -f "$SYSIMG" ] && [ "$(flsz "$SYSIMG")" = "$SYSIMG_EXPECT" ]; then
  say "系统镜像已缓存，跳过下载"
else
  say "下载 ARM 系统镜像（期望 $((SYSIMG_EXPECT/1024/1024)) MiB）"
  dl "$SYSIMG_EXPECT" "$SYSIMG" "$SYSIMG_URL" || die "系统镜像下载失败"
fi

# ---- 2) Platform 包（按需求一并下载，启动用不到）---------------------------
PLAT="$CACHE_DIR/$PLATFORM_NAME"
if [ -f "$PLAT" ] && [ "$(flsz "$PLAT")" = "$PLATFORM_EXPECT" ]; then
  say "Platform 包已缓存，跳过下载"
else
  say "下载 Platform 包（期望 $((PLATFORM_EXPECT/1024/1024)) MiB）"
  dl "$PLATFORM_EXPECT" "$PLAT" "$PLATFORM_URL" || die "Platform 包下载失败"
fi

# ---- 解包系统镜像 → OUT_DIR ------------------------------------------------
say "解包系统镜像到 $OUT_DIR"
TMP="$(mktemp -d)"
unzip -q -o "$SYSIMG" -d "$TMP" || die "系统镜像解包失败"
SRC="$(find "$TMP" -type d -name 'armeabi-v7a' | head -n1)"
[ -n "$SRC" ] || die "在系统镜像中找不到 armeabi-v7a 目录"
for f in kernel-qemu system.img ramdisk.img userdata.img; do
  [ -f "$SRC/$f" ] || die "系统镜像缺少 $f"
  cp -f "$SRC/$f" "$OUT_DIR/$f"
done
[ -f "$SRC/build.prop" ] && cp -f "$SRC/build.prop" "$OUT_DIR/build.prop"
[ -f "$SRC/source.properties" ] && cp -f "$SRC/source.properties" "$OUT_DIR/source.properties"
rm -rf "$TMP"

# ---- 解包 Platform 包（仅保留，供参考）-------------------------------------
say "解包 Platform 包到 $OUT_DIR/platform"
mkdir -p "$OUT_DIR/platform"
unzip -q -o "$PLAT" -d "$OUT_DIR/platform" || say "::warning::Platform 包解包失败（不影响启动）"

# ---- 写 manifest -----------------------------------------------------------
cat > "$OUT_DIR/manifest.json" <<EOF
{
  "android_version": "4.0.3",
  "api_level": 15,
  "abi": "armeabi-v7a",
  "kernel": "kernel-qemu",
  "images": ["system.img", "ramdisk.img", "userdata.img"],
  "note": "kernel-qemu 为 AOSP goldfish 内核，需 goldfish 机器的 QEMU 才能启动（UTM 的上游 QEMU 不含 goldfish）。",
  "source": {
    "system_image": "$SYSIMG_URL",
    "platform": "$PLATFORM_URL"
  }
}
EOF

say "完成。镜像位于: $OUT_DIR"
ls -lh "$OUT_DIR" | sed 's/^/    /'
echo "FETCH_OK"
