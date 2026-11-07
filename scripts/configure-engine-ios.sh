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

CFLAGS_IOS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN_IOS -fPIC -Wno-error=deprecated-declarations -DQEMU_IOS_PORTABLE_CRYPTO -I$PREFIX/include"
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

# meson.build 的构建摘要里有一句
#   meson.get_compiler('c', native: true).cmd_array()
# 当 cross file 的 host_machine 与 build machine 同为 darwin/aarch64 时，
# meson 会判为「未给 build machine 指定 C 编译器」而中止 setup。这一行
# 只用于打印 "Host C compiler"，改用 host 编译器不影响任何实际编译。
MB="$SRC/meson.build"
python3 - "$MB" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
old = "meson.get_compiler('c', native: true)"
if old in s:
    p.write_text(s.replace(old, "meson.get_compiler('c')", 1))
    print("  构建摘要的 native C 编译器引用已改用 host 编译器")
else:
    print("  未找到 native C 编译器引用，跳过")
PY

# iOS 原生 EAGL 渲染后端（hw/arm/gles-host.c）这条分支上游从未真正编译过：
# contrib/portable/build-engine.py 只构建 linux / Android。iOS 18 SDK 实测
# 依次暴露：缺 desktop GL 常量、漏 include ES2/ES3 头（glUseProgram 等被判
# 隐式声明）、glClipPlane 这类 GLES 根本不存在的固定管线函数、以及
# gles-host-queue.c.inc 引用未定义的 gles_contexts。逐个补没有尽头。
#
# 上游在 hw/arm/meson.build 里已为「没有 OpenGL / OpenGLES / EGL 的 host」
# 设计了官方降级路径 gles-host-stub.c：它提供全部 gles_host_* 符号，guest
# 的 GLES HLE probe 会干净失败并回退软件渲染。这里把整段 backend 选择块
# 换成只编 stub，让引擎静态库先真正产出；原生 EAGL 渲染留作后续单独修复。
# 只作用于 CI 解压出的临时源码树，不改仓库、不改上游 release tarball。
HWA="$SRC/hw/arm/meson.build"
python3 - "$HWA" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); s = p.read_text()
marker = "if host_opengl.found() or host_gles.found() or host_egl.found()"
anchor = "if host_os == 'darwin'"
if marker in s and anchor in s and "gles-host-stub (iOS cross)" not in s:
    start = s.index(marker)
    end = s.index(anchor, start)
    block = (
        "# gles-host-stub (iOS cross): upstream EAGL renderer is not CI-built.\n"
        "# The stub exports every gles_host_* symbol; guest GLES HLE falls back\n"
        "# to its software renderer. See scripts/configure-engine-ios.sh.\n"
        "arm_ss.add(when: 'CONFIG_IPOD_TOUCH_2G', if_true: files('gles-host-stub.c'))\n\n"
    )
    p.write_text(s[:start] + block + s[end:])
    print("  GLES backend 选择块已替换为 gles-host-stub.c")
else:
    print("  GLES backend 选择块结构不符或已打过补丁，跳过")
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
  echo "::error::QEMU configure 失败；上面已打印 configure.log 末 40 行，请按其中的 ERROR 定位"
  echo "::notice::常见原因依次为：sysroot 缺少 glib-2.0.pc、meson 依赖探测失败、cross/native machine file 冲突"
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
