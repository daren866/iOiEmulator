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

# iOS 原生 EAGL 渲染后端（hw/arm/gles-host.c）在 TARGET_OS_IPHONE 分支
# include <OpenGLES/ES1/gl.h>，但源码里仍引用了一批 desktop OpenGL 常量
# （GL_DEPTH_COMPONENT / GL_TEXTURE_CUBE_MAP / GL_UNPACK_ROW_LENGTH / ...），
# 在 iOS 18 SDK 下报 use of undeclared identifier。上游 build-engine.py
# 只构建 linux / Android，这条 iOS 路径没有官方 CI 覆盖。这里在 ES1 头之后
# 补一个「仅当未定义时才生效」的常量兼容头，保留 EAGL 渲染而不降级到 stub。
GC="$SRC/hw/arm/gl-compat-ios.h"
python3 - "$GC" "$SRC/hw/arm/gles-host.c" <<'PY'
import pathlib, sys
hdr, src = map(pathlib.Path, sys.argv[1:3])
consts = [
    ("GL_DEPTH_COMPONENT",              "0x1902"),
    ("GL_STENCIL_INDEX",                "0x1901"),
    ("GL_UNSIGNED_INT_8_8_8_8",         "0x8035"),
    ("GL_UNSIGNED_INT_8_8_8_8_REV",     "0x8367"),
    ("GL_UNSIGNED_SHORT_4_4_4_4_REV",   "0x8365"),
    ("GL_UNSIGNED_SHORT_1_5_5_5_REV",   "0x8366"),
    ("GL_UNPACK_ROW_LENGTH",            "0x0CF2"),
    ("GL_UNPACK_SKIP_ROWS",             "0x0CF3"),
    ("GL_UNPACK_SKIP_PIXELS",           "0x0CF4"),
    ("GL_UNPACK_IMAGE_HEIGHT",          "0x806E"),
    ("GL_UNPACK_SKIP_IMAGES",           "0x806D"),
    ("GL_PACK_ROW_LENGTH",              "0x0D02"),
    ("GL_PACK_SKIP_ROWS",               "0x0D03"),
    ("GL_PACK_SKIP_PIXELS",             "0x0D04"),
    ("GL_PACK_IMAGE_HEIGHT",            "0x806C"),
    ("GL_PACK_SKIP_IMAGES",             "0x806B"),
    ("GL_MAX_ELEMENTS_VERTICES",        "0x80E8"),
    ("GL_MAX_ELEMENTS_INDICES",         "0x80E9"),
    ("GL_TEXTURE_CUBE_MAP",             "0x8513"),
    ("GL_TEXTURE_CUBE_MAP_POSITIVE_X",  "0x8515"),
    ("GL_TEXTURE_CUBE_MAP_NEGATIVE_X",  "0x8516"),
    ("GL_TEXTURE_CUBE_MAP_POSITIVE_Y",  "0x8517"),
    ("GL_TEXTURE_CUBE_MAP_NEGATIVE_Y",  "0x8518"),
    ("GL_TEXTURE_CUBE_MAP_POSITIVE_Z",  "0x8519"),
    ("GL_TEXTURE_CUBE_MAP_NEGATIVE_Z",  "0x851A"),
    ("GL_TEXTURE_MAX_LEVEL",            "0x813D"),
    ("GL_TEXTURE_BASE_LEVEL",           "0x813C"),
    ("GL_TEXTURE_MIN_LOD",              "0x813A"),
    ("GL_TEXTURE_MAX_LOD",              "0x813B"),
    ("GL_TEXTURE_WRAP_R",               "0x8072"),
    ("GL_TEXTURE_3D",                   "0x806F"),
    ("GL_CLAMP_TO_BORDER",              "0x812D"),
    ("GL_MIRRORED_REPEAT",              "0x8370"),
    ("GL_GENERATE_MIPMAP",              "0x8191"),
    ("GL_RGB8",                         "0x8051"),
    ("GL_RGBA8",                        "0x8058"),
    ("GL_BGR",                          "0x80E0"),
    ("GL_BGRA",                         "0x80E1"),
    ("GL_DEPTH_COMPONENT24",            "0x81A6"),
    ("GL_DEPTH_COMPONENT32",            "0x81A7"),
    ("GL_TEXTURE_RECTANGLE",            "0x84F5"),
    ("GL_TEXTURE_1D",                   "0x0DE0"),
]
lines = ["/* iOS ES1 headers lack these desktop GL enum values.",
         " * Define only when absent so real ES1/OES values win. */",
         "#ifndef GLES_HOST_GL_COMPAT_IOS_H",
         "#define GLES_HOST_GL_COMPAT_IOS_H", ""]
for name, value in consts:
    lines += ["#ifndef " + name, "#define " + name + " " + value, "#endif"]
lines += ["", "#endif"]
hdr.write_text("\n".join(lines) + "\n")

s = src.read_text()
needle = "#include <OpenGLES/ES1/gl.h>\n#include <OpenGLES/ES1/glext.h>\n#endif"
if needle in s and "gl-compat-ios.h" not in s:
    src.write_text(s.replace(
        needle,
        "#include <OpenGLES/ES1/gl.h>\n#include <OpenGLES/ES1/glext.h>\n"
        '#include "gl-compat-ios.h"\n#endif', 1))
    print("  iOS EAGL 分支已补 %d 个 desktop GL 常量" % len(consts))
else:
    print("  iOS EAGL include 结构不符或已打过补丁，跳过")
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
