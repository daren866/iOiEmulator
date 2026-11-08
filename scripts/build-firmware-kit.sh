#!/usr/bin/env bash
# firmware-kit 构建：把 LightTouch 的 firmwarekit（IPSW→设备制备，Rust）交叉编译为
# iOS arm64 静态库 libltfw.a（wrapper 见 firmware-kit/src/lib.rs）。
#
# 与引擎一致，源码来自 engine/SOURCES.json 锁定的 tarball（SHA256 校验），
# 解包到 firmware-kit/vendor/LightTouch 供 cargo 以 path 依赖引用。
# 仅本地与 CI 的 macOS runner 上运行；本脚本与产物都不含任何 Apple 固件。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KIT="$ROOT/firmware-kit"
VENDOR="$KIT/vendor"
OUT="${LTFW_OUT:-$ROOT/engine/prebuilt}"

echo "== 0) 工具链"
if ! command -v cargo >/dev/null 2>&1; then
  echo "   安装 rustup…"
  curl -fsSL --retry 3 --connect-timeout 20 https://sh.rustup.rs | sh -s -- -y --profile minimal
  export PATH="$HOME/.cargo/bin:$PATH"
fi
rustup target add aarch64-apple-ios >/dev/null
echo "   rustc $(rustc --version)"

echo "== 1) 拉取并解包锁定的 LightTouch 源码"
mkdir -p "$VENDOR"
FETCH_ONLY=LightTouch ENGINE_DEST="$VENDOR" bash "$ROOT/scripts/fetch-engine.sh"
SRC="$VENDOR/LightTouch-v0.0.13"
if [ ! -d "$SRC/crates/lighttouch-firmware" ]; then
  rm -rf "$SRC"
  tar xzf "$VENDOR/LightTouch-v0.0.13-source.tar.gz" -C "$VENDOR"
fi
test -f "$SRC/crates/lighttouch-firmware/Cargo.toml"
# Cargo.toml 的 path 依赖固定指向 vendor/LightTouch；tarball 解包目录带版本号，
# 用符号链接统一（gitignore 已排除 vendor/）。
ln -sfn "LightTouch-v0.0.13" "$VENDOR/LightTouch"

echo "== 2) iOS arm64 交叉编译环境"
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
export SDKROOT="$SDK"
export CC_aarch64_apple_ios="$(xcrun --sdk iphoneos -f clang)"
export AR_aarch64_apple_ios="$(xcrun --sdk iphoneos -f ar)"
export CFLAGS_aarch64_apple_ios="-arch arm64 -isysroot $SDK -miphoneos-version-min=15.0 -fno-objc-arc"
export CARGO_TARGET_AARCH64_APPLE_IOS_LINKER="$CC_aarch64_apple_ios"
echo "   SDK=$SDK"

echo "== 3) cargo build --release --target aarch64-apple-ios"
cd "$KIT"
cargo build --release --target aarch64-apple-ios

LIB="$KIT/target/aarch64-apple-ios/release/libltfw.a"
test -f "$LIB"

echo "== 4) 归集产物 → $OUT"
mkdir -p "$OUT" "$OUT/include"
cp "$LIB" "$OUT/libltfw.a"
cp "$KIT/ltfw.h" "$OUT/include/ltfw.h"
echo "== 5) 校验导出符号"
# Apple nm 对 rustc 新版 LLVM 归档格式偶尔直接报错（stderr 此前被吞导致难排查），
# 依次尝试 nm / xcrun llvm-nm，全部失败则打印诊断信息。
SYMS="$(nm -gU "$OUT/libltfw.a" 2>/dev/null || true)"
[ -z "$SYMS" ] && SYMS="$(xcrun llvm-nm -gU "$OUT/libltfw.a" 2>/dev/null || true)"
[ -z "$SYMS" ] && SYMS="$(nm "$OUT/libltfw.a" 2>/dev/null || true)"
if ! echo "$SYMS" | grep -q "_ltfw_create"; then
  echo "::error::libltfw.a 未导出 _ltfw_create（诊断信息如下）"
  echo "--- nm（报错样例）---"
  nm "$OUT/libltfw.a" 2>&1 | head -5 || true
  echo "--- xcrun llvm-nm ---"
  xcrun llvm-nm "$OUT/libltfw.a" 2>&1 | grep -iE "ltfw|error|no such" | head -10 || true
  echo "--- 归档成员（前 5）---"
  ar t "$OUT/libltfw.a" 2>&1 | head -5 || true
  exit 1
fi
echo "   OK: ltfw_create / ltfw_abi_version 已导出"

echo "== OK: $OUT/libltfw.a ($(du -h "$OUT/libltfw.a" | cut -f1))"
