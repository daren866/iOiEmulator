#!/usr/bin/env bash
# =============================================================================
# 引擎 ③-a：在 macOS runner 上为 qemu-ios 生成 iOS arm64 交叉配置并执行 configure。
#
# qemu-ios v0.0.13 的 configure 已针对 iOS 做过改造：
#   - 自动探测「生成的二进制不可在本机运行」并写入 needs_exe_wrapper = true
#   - 同时生成 objc_link_args，避免 .m 源文件导致 sysroot -L 丢失
#   - --cross-prefix= 会强制进入 cross 模式，生成 config-meson.cross
#
# 产物：$WORK/qemu-build/build.ninja（configure_only 模式到此为止）
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$ROOT/.engine-work}"
SRC="$WORK/qemu-src"
PREFIX="$WORK/sysroot/prefix"
BIN="$WORK/bin"
BUILD="$WORK/qemu-build"
LOG="$WORK/configure.log"

[ "$(uname -s)" = "Darwin" ] || { echo "ERROR: 需要 macOS + Xcode" >&2; exit 2; }
[ -f "$SRC/configure" ] || { echo "ERROR: 缺少 QEMU 源码树 $SRC" >&2; exit 2; }

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SDKVER="$(xcrun --sdk iphoneos --show-sdk-version)"
MIN_IOS="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"

echo "== 环境 =="
echo "  macOS     : $(sw_vers -productVersion) / $(uname -m)"
echo "  iphoneos  : $SDKVER"
echo "  SDK       : $SDK"
echo "  source    : $SRC"
echo "  prefix    : $PREFIX"
echo "  build     : $BUILD"
echo "  glib .pc  : $(ls "$PREFIX/lib/pkgconfig"/glib-2.0.pc 2>/dev/null || echo '缺失（configure 预计会在此报错）')"

mkdir -p "$BUILD" "$BIN"

# 工具链 wrapper（若 ② 的产物不在，这里补建，保证单独触发 ③ 也能跑）
if [ ! -x "$BIN/ios-clang" ]; then
  cat > "$BIN/ios-clang" <<EOF
#!/bin/sh
exec xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=$MIN_IOS "\$@"
EOF
  cat > "$BIN/ios-clang++" <<EOF
#!/bin/sh
exec xcrun --sdk iphoneos clang++ -arch arm64 -isysroot "$SDK" -miphoneos-version-min=$MIN_IOS "\$@"
EOF
  chmod +x "$BIN/ios-clang" "$BIN/ios-clang++"
fi
PKGBIN="$(command -v pkg-config || echo /usr/local/bin/pkg-config)"
cat > "$BIN/ios-pkg-config" <<EOF
#!/bin/sh
exec "$PKGBIN" --static "\$@"
EOF
chmod +x "$BIN/ios-pkg-config"

export PKG_CONFIG="$BIN/ios-pkg-config"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
export PATH="$BIN:$PATH"

CFLAGS_IOS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN_IOS -fPIC -Wno-error=deprecated-declarations -DQEMU_IOS_PORTABLE_CRYPTO"
LDFLAGS_IOS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN_IOS -L$PREFIX/lib"

echo
echo "== iOS cross 适配补丁 =="
# QEMU 的 target/meson.build 无条件 subdir() 全部 19 个架构，其中 hexagon 的
# gen_semantics、s390x 的 gen-features 等都是 native:true 的 build-machine
# 可执行程序。在 --cross-prefix= 触发的 cross 模式下，meson 会依次报
# "No build machine compiler" 而中止 setup（CI 实测先后卡在 hexagon、s390x）。
# 只构建 --target-list=arm-softmmu 时，非 arm 的 target 子目录完全用不到：
# 顶层 meson.build 只通过 hw_arch map 引用各架构，不直接依赖这些 *_ss 变量。
# 因此一次性裁剪为只保留 subdir('arm')。补丁只作用于 CI 解压出的临时源码树，
# 不改动仓库，也不改动上游 release tarball。
TM="$SRC/target/meson.build"
python3 - "$TM" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
out, disabled = [], []
for line in p.read_text().splitlines():
    m = re.match(r"^subdir\('([^']+)'\)", line)
    if m and m.group(1) != 'arm':
        disabled.append(m.group(1))
        out.append("# " + line + "  # iOS arm-softmmu cross: only arm target is built")
    else:
        out.append(line)
p.write_text("\n".join(out) + "\n")
print(f"  保留 subdir('arm')，禁用 {len(disabled)} 个非 arm target: {','.join(disabled)}")
PY

echo
echo "== configure =="
cd "$BUILD"
set +e
"$SRC/configure" \
  --cross-prefix= \
  --cpu=aarch64 \
  --cc="$BIN/ios-clang" \
  --cxx="$BIN/ios-clang++" \
  --objcc="$BIN/ios-clang" \
  --host-cc=/usr/bin/clang \
  --target-list=arm-softmmu \
  --without-default-features \
  --without-default-devices \
  --with-devices-arm=portable \
  --enable-tcg \
  -Dtcg_interpreter=true \
  -Dcoroutine_backend=sigaltstack \
  --disable-pixman \
  --disable-gcrypt \
  --disable-slirp \
  --disable-curl \
  --disable-cocoa \
  --disable-coreaudio \
  --disable-sdl \
  --disable-gtk \
  --disable-vnc \
  --disable-spice \
  --disable-containers \
  --disable-docs \
  --disable-tools \
  --disable-werror \
  --disable-pie \
  --audio-drv-list= \
  --python="$(command -v python3)" \
  --ninja="$(command -v ninja)" \
  --extra-cflags="$CFLAGS_IOS" \
  --extra-ldflags="$LDFLAGS_IOS" \
  > "$LOG" 2>&1
RC=$?
set -e

echo "  configure 退出码：$RC"
echo "  日志：$LOG"
echo "  ---- 末 40 行 ----"
tail -40 "$LOG" || true

if [ "$RC" -ne 0 ]; then
  echo "::error::QEMU configure 失败，常见原因：sysroot 中 glib-2.0.pc 缺失（依赖 ② 未成功）"
  exit "$RC"
fi

echo
echo "== 校验产物 =="
test -f "$BUILD/build.ninja" || { echo "ERROR: 未生成 build.ninja" >&2; exit 1; }
if [ -f "$BUILD/config-meson.cross" ]; then
  echo "  config-meson.cross:"
  grep -E "needs_exe_wrapper|^\[|c_args|objc_link_args" "$BUILD/config-meson.cross" | head -20
fi
echo "  ninja targets: $(ninja -C "$BUILD" -t targets 2>/dev/null | wc -l | tr -d ' ')"
echo "OK: configure 完成（未编译；关闭 configure_only 才会执行 ninja）"
