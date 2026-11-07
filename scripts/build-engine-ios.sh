#!/usr/bin/env bash
# =============================================================================
# 本地一键入口（macOS 专用）：串起引擎 ② → ③-a → ③-b。
# CI 里的等价流程是 .github/workflows/engine-pipeline.yml，两者共用同一批脚本。
#
#   brew install meson ninja pkg-config autoconf automake libtool gettext bison jq
#   WORK=.engine-work ./scripts/build-engine-ios.sh
#
# 说明：原来这里是「配方草案」，现已替换为真实可执行的交叉编译入口。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WORK="${WORK:-$ROOT/.engine-work}"

[ "$(uname -s)" = "Darwin" ] || {
  echo "ERROR: iOS 交叉编译需要 macOS + Xcode（当前 $(uname -s)）" >&2
  exit 2
}

echo "== ① 源码 =="
mkdir -p "$WORK/tarballs"
ENGINE_DEST="$WORK/tarballs" bash "$ROOT/scripts/fetch-engine.sh"
WORK="$WORK" ENGINE_DEST="$WORK/tarballs" bash "$ROOT/scripts/engine-source-manifest.sh"

echo
echo "== ② iOS 依赖 sysroot =="
WORK="$WORK" PACKAGES="${PACKAGES:-libffi,pcre2,glib,pixman,openssl,proxy-libintl}" \
  bash "$ROOT/scripts/build-ios-deps.sh"
WORK="$WORK" bash "$ROOT/scripts/sysroot-report.sh"

echo
echo "== ③-a QEMU configure =="
mkdir -p "$WORK/qemu-src"
tar xzf "$WORK/tarballs/qemu-ios-v0.0.13-source.tar.gz" -C "$WORK/qemu-src" --strip-components=1
WORK="$WORK" bash "$ROOT/scripts/configure-engine-ios.sh"

echo
echo "== ③-b 编译并归档 libqemu-arm.a =="
WORK="$WORK" bash "$ROOT/scripts/build-engine-lib.sh"
WORK="$WORK" CONFIGURE_ONLY=false bash "$ROOT/scripts/engine-build-report.sh"

echo
echo "== ④ 接入 App =="
mkdir -p "$ROOT/engine/prebuilt"
cp "$WORK/engine-out/libqemu-arm.a" "$ROOT/engine/prebuilt/"
cp -R "$WORK/engine-out/include/." "$ROOT/engine/prebuilt/include/" 2>/dev/null || true
echo "  已写入 engine/prebuilt/；下次 tuist generate 会自动链接引擎。"
echo "OK"
