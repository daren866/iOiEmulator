#!/usr/bin/env bash
# =============================================================================
# 引擎 ②：为 iOS arm64 交叉编译 QEMU 的最小依赖集，输出到 sysroot/prefix。
#
# 设计原则：
#   - 只在 macOS + Xcode 上执行（xcrun / iphoneos SDK 是硬前提）
#   - 逐包独立：任一包失败不中断整条流水线，逐包写 status/<name>.json
#   - 全部静态库：iOS 不允许 App 加载任意 dylib，且便于最后合并成单个 .a
#   - 不下载 Apple 固件，不碰 JIT，不依赖 UTM 全家桶
#
# 依据：qemu-ios v0.0.13 contrib/portable/dependencies.json（版本+SHA256 一致）
#       QEMU configure --without-default-features 的实际探测项
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$ROOT/.engine-work}"
MANIFEST="$ROOT/scripts/ios-deps.json"
PREFIX="$WORK/sysroot/prefix"
SRC="$WORK/deps-src"
STATUS="$WORK/sysroot/status"
BIN="$WORK/bin"
JOBS="${LT_JOBS:-3}"
PACKAGES="${PACKAGES:-libffi,pcre2,glib,pixman,proxy-libintl,libgpg-error,libgcrypt}"
MIN_IOS="${IPHONEOS_DEPLOYMENT_TARGET:-15.0}"

mkdir -p "$PREFIX" "$SRC" "$STATUS" "$BIN" "$PREFIX/lib/pkgconfig"

# actions/cache 命中时直接复用，避免重复编译（可用 SKIP_IF_CACHED=0 强制重建）
if [ "${SKIP_IF_CACHED:-0}" = "1" ] \
   && [ -f "$PREFIX/lib/pkgconfig/glib-2.0.pc" ] \
   && [ -f "$PREFIX/lib/libglib-2.0.a" ]; then
  echo "== sysroot 已缓存，跳过依赖编译 =="
  find "$PREFIX" -name '*.a' -type f | sort | head -20
  find "$PREFIX" -name '*.a' -type f | sort > "$WORK/sysroot/deps-libs.txt"
  for n in $(echo "$PACKAGES" | tr ',' ' '); do
    printf '{"name":"%s","ok":true,"stage":"cached","log":"","seconds":0}\n' "$n" \
      > "$STATUS/$n.json"
  done
  exit 0
fi

if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: iOS 交叉编译只能在 macOS 上执行（当前 $(uname -s)）" >&2
  exit 2
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SDKVER="$(xcrun --sdk iphoneos --show-sdk-version)"
HOST_TRIPLE="aarch64-apple-darwin"

echo "== 环境 =="
echo "  macOS     : $(sw_vers -productVersion) / $(uname -m)"
echo "  iphoneos  : $SDKVER"
echo "  SDK       : $SDK"
echo "  min iOS   : $MIN_IOS"
echo "  prefix    : $PREFIX"
echo "  packages  : $PACKAGES"

# ---- 生成工具链 wrapper（autotools 需要单文件命令）--------------------------
cat > "$BIN/ios-clang" <<EOF
#!/bin/sh
exec xcrun --sdk iphoneos clang -arch arm64 -isysroot "$SDK" -miphoneos-version-min=$MIN_IOS "\$@"
EOF
cat > "$BIN/ios-clang++" <<EOF
#!/bin/sh
exec xcrun --sdk iphoneos clang++ -arch arm64 -isysroot "$SDK" -miphoneos-version-min=$MIN_IOS "\$@"
EOF
cat > "$BIN/ios-ar" <<EOF
#!/bin/sh
exec xcrun --sdk iphoneos ar "\$@"
EOF
cat > "$BIN/ios-ranlib" <<EOF
#!/bin/sh
exec xcrun --sdk iphoneos ranlib "\$@"
EOF
PKGBIN="$(command -v pkg-config || echo /usr/local/bin/pkg-config)"
cat > "$BIN/ios-pkg-config" <<EOF
#!/bin/sh
exec "$PKGBIN" --static "\$@"
EOF
chmod +x "$BIN"/ios-*

export CC="$BIN/ios-clang"
export CXX="$BIN/ios-clang++"
export AR="$BIN/ios-ar"
export RANLIB="$BIN/ios-ranlib"
export PKG_CONFIG="$BIN/ios-pkg-config"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
# 不设 PKG_CONFIG_SYSROOT_DIR：.pc 里的 prefix 已是绝对路径，
# 再加 sysroot 会得到重复的 $PREFIX$PREFIX/include 路径。
export CFLAGS="-fPIC -O2 -D__IPHONE_OS_VERSION_MIN_REQUIRED=150000"
# libgpg-error / libgcrypt 的 autotools 在 cross 模式下要用 build-machine
# 编译器生成并运行 mkheader、gen-posix-lock-obj 等工具，与上游
# contrib/portable/build-crypto-deps.py 的 CC_FOR_BUILD=/usr/bin/cc 一致。
export CC_FOR_BUILD=/usr/bin/cc
export CXXFLAGS="-fPIC -O2"
export LDFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN_IOS"
export PATH="$BIN:$PATH"

# ---- Meson iOS cross file ---------------------------------------------------
# 关键做法来自 UTM scripts/build_dependencies.sh 的 generate_meson_cross()：
#   * host_machine.system 必须是 'ios' 而不是 'darwin'，否则 meson 走 macOS 分支
#   * 显式提供 build-machine 工具（glib-mkenums / glib-compile-resources / python），
#     否则 meson 会尝试运行 iOS 版工具，在 cross 模式下直接失败
#   * 预置 has_function_pipe2/dup3 = false：新版 SDK 里 meson 的 has_function()
#     自声明原型，绕过可用性标注，会误判为存在，留下旧系统上的弱导入 NULL
HOST_GLIB_MKENUMS="$(command -v glib-mkenums || true)"
HOST_GLIB_RESOURCES="$(command -v glib-compile-resources || true)"
HOST_PYTHON="$(command -v python3 || true)"
cat > "$WORK/sysroot/ios-cross.ini" <<EOF
[binaries]
c        = ['$BIN/ios-clang']
cpp      = ['$BIN/ios-clang++']
objc     = ['$BIN/ios-clang']
ar       = ['$BIN/ios-ar']
ranlib   = ['$BIN/ios-ranlib']
strip    = ['xcrun', '--sdk', 'iphoneos', 'strip', '-x']
pkgconfig = ['$BIN/ios-pkg-config']
python   = ['$HOST_PYTHON']
$([ -n "$HOST_GLIB_MKENUMS" ] && echo "glib-mkenums = ['$HOST_GLIB_MKENUMS']")
$([ -n "$HOST_GLIB_RESOURCES" ] && echo "glib-compile-resources = ['$HOST_GLIB_RESOURCES']")

[built-in options]
c_args      = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS', '-fPIC']
cpp_args    = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS', '-fPIC']
objc_args   = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS', '-fPIC']
c_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS']
cpp_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS']
objc_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS']

[host_machine]
system     = 'ios'
cpu_family = 'aarch64'
cpu        = 'arm64'
endian     = 'little'

[properties]
needs_exe_wrapper = true
has_function_pipe2 = false
has_function_dup3 = false
EOF
# 去掉条件行留下的空行，避免 meson 解析到空条目
grep -v '^$' "$WORK/sysroot/ios-cross.ini" > "$WORK/sysroot/ios-cross.ini.tmp" \
  && mv "$WORK/sysroot/ios-cross.ini.tmp" "$WORK/sysroot/ios-cross.ini"
echo "  cross file: $WORK/sysroot/ios-cross.ini"
echo "  host tools: glib-mkenums=${HOST_GLIB_MKENUMS:-缺失} glib-compile-resources=${HOST_GLIB_RESOURCES:-缺失}"

# ---- 工具函数 ---------------------------------------------------------------
# libgpg-error / libgcrypt 会用 CC_FOR_BUILD 编译并运行 build-machine 工具
# （mkheader / mkerrcodes / gost-s-box）。workflow 级 env 里的
# IPHONEOS_DEPLOYMENT_TARGET=15.0 会被 Apple clang driver 自动读取，把这些
# host 工具也标成 iOS 平台，在 macOS 上运行时直接 Killed: 9（CI 日志里的
# "ld: warning: building for 'iOS'" 就是它）。目标代码由 ios-clang wrapper
# 显式携带 -miphoneos-version-min，MIN_IOS 在脚本开头已固化，unset 不影响。
clean_host_env() {
  unset IPHONEOS_DEPLOYMENT_TARGET SDKROOT \
        TVOS_DEPLOYMENT_TARGET WATCHOS_DEPLOYMENT_TARGET MACOSX_DEPLOYMENT_TARGET
  export LDFLAGS="" LDFLAGS_FOR_BUILD=""
  export CFLAGS="-fPIC -O2" CFLAGS_FOR_BUILD="-O2"
  export CPPFLAGS="" CPPFLAGS_FOR_BUILD=""
  export CXXFLAGS="-fPIC -O2"
  export CC_FOR_BUILD=/usr/bin/cc
  # libgcrypt 的 configure 会在 PATH 找 gpgrt-config / gpg-error-config；
  # runner 上 Homebrew 装了 libgpg-error，必须让本 sysroot 的优先。
  export PATH="$PREFIX/bin:$PATH"
}

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

fetch_archive() {
  local url="$1" dest="$2" expected="$3"
  if [ -f "$dest" ] && [ "$(sha_of "$dest")" = "$expected" ]; then
    echo "    已缓存且校验通过"; return 0
  fi
  local urls=("$url")
  case "$url" in
    https://github.com/*) urls+=("https://v4.gh-proxy.org/$url") ;;
  esac
  for u in "${urls[@]}"; do
    echo "    下载 $u"
    if curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 600 -o "$dest" "$u"; then
      if [ "$(sha_of "$dest")" = "$expected" ]; then echo "    SHA256 OK"; return 0; fi
      echo "    SHA256 不匹配，尝试下一个源" >&2
    fi
  done
  return 1
}

record() {
  local name="$1" ok="$2" stage="$3" log="$4" secs="$5"
  printf '{"name":"%s","ok":%s,"stage":"%s","log":"%s","seconds":%s}\n' \
    "$name" "$ok" "$stage" "$log" "$secs" > "$STATUS/$name.json"
  # 变量名必须用 ${}，否则紧随其后的中文全角标点会被 bash 吞进变量名
  if [ "$ok" = "true" ]; then
    echo "  [OK]   ${name} (${secs} s)"
  else
    echo "  [FAIL] ${name} — ${stage}，日志：${log}"
    # 直接把失败原因打进 CI 日志，省去下载 artifact 才能诊断
    if [ -f "$log" ]; then
      echo "  ---- ${name} 失败日志末 20 行 ----"
      tail -20 "$log" | sed 's/^/    /'
      echo "  --------------------------------"
    fi
  fi
}

build_one() {
  local name="$1" archive="$2" dir="$3" url="$4" sha="$5" kind="$6"
  local log="$STATUS/$name.log"
  local t0=$SECONDS
  # libgpg-error / libgcrypt 的 autotools 会编译并运行 build-machine 工具
  # （mkheader / mkerrcodes / gost-s-box）。它们走 CC_FOR_BUILD，但
  # LDFLAGS_FOR_BUILD 会继承全局 LDFLAGS（含 iPhoneOS sysroot），链接出的
  # iOS 二进制在 macOS 上运行被 Killed: 9。ios-clang wrapper 自带全部 iOS
  # flags，清空 LDFLAGS 不影响目标库；再用 make 变量强制覆盖 host 工具参数。
  local host_build_fix=""
  case "$name" in
    libgpg-error|libgcrypt)
      host_build_fix="CC_FOR_BUILD=/usr/bin/cc LDFLAGS= LDFLAGS_FOR_BUILD= CFLAGS_FOR_BUILD=-O2 CPPFLAGS_FOR_BUILD="
      ;;
  esac
  echo "== 构建 $name ($kind) =="

  if ! fetch_archive "$url" "$SRC/$archive" "$sha" >"$log" 2>&1; then
    record "$name" false download "$log" $((SECONDS-t0)); return 0
  fi
  rm -rf "$SRC/$dir"
  if ! tar xf "$SRC/$archive" -C "$SRC" >>"$log" 2>&1; then
    record "$name" false unpack "$log" $((SECONDS-t0)); return 0
  fi
  if [ ! -d "$SRC/$dir" ]; then
    record "$name" false "unpack-dir-missing" "$log" $((SECONDS-t0)); return 0
  fi

  local stage="configure"
  (
    cd "$SRC/$dir"
    case "$kind" in
      autotools)
        case "$name" in
          libffi) EXTRA="--disable-docs --disable-multi-os-directory" ;;
          pcre2)  EXTRA="--enable-unicode --disable-jit --disable-pcre2grep-jit --disable-pcre2grep-callout" ;;
          libgpg-error) EXTRA="--disable-doc" ;;
          libgcrypt)
            # iOS 便携引擎的 PKE 只用 MPI，纯 C 实现即可；禁用 asm 避免
            # aarch64 汇编在 iphoneos SDK 下挑错架构。必须先编 libgpg-error。
            EXTRA="--with-libgpg-error-prefix=$PREFIX --disable-asm --disable-doc"
            ;;
          *)      EXTRA="" ;;
        esac
        [ -z "$host_build_fix" ] || clean_host_env
        ./configure --host="$HOST_TRIPLE" --prefix="$PREFIX" \
          --disable-shared --enable-static $EXTRA
        ;;
      meson)
        case "$name" in
          glib)
            EXTRA="-Dtests=false -Ddtrace=disabled -Dinstalled_tests=false -Dglib_assert=false -Dglib_checks=false -Dxattr=false -Dlibmount=disabled -Dselinux=disabled -Dsysprof=disabled -Dman=false -Dgtk_doc=false -Dbsymbolic_functions=false -Dnls=disabled -Dintrospection=disabled"
            ;;
          pixman)
            EXTRA="-Dtests=disabled -Dgtk=disabled -Dlibpng=disabled -Dopenmp=disabled -Dloongson-mmi=disabled -Dmmx=disabled -Dsse2=disabled -Dssse3=disabled -Dvmx=disabled -Darm-simd=disabled -Dneon=disabled -Da64-neon=disabled"
            ;;
          proxy-libintl)
            # proxy-libintl 0.4 没有 tests 选项，传 -Dtests 会直接
            # "Unknown option: tests" 导致 meson setup 失败
            EXTRA=""
            ;;
          *) EXTRA="" ;;
        esac
        meson setup build --cross-file="$WORK/sysroot/ios-cross.ini" \
          --prefix="$PREFIX" --default-library=static $EXTRA
        ;;
      openssl)
        # OpenSSL 3.x 的 iOS target 名随版本变化，运行时探测而不是硬编码
        IOS_TARGET=$(perl ./Configure LIST 2>/dev/null | grep -iE '^ios' | head -n 1 || true)
        [ -n "$IOS_TARGET" ] || IOS_TARGET="ios64-xcrun"
        echo "    OpenSSL target = $IOS_TARGET"
        ./Configure "$IOS_TARGET" no-shared no-tests no-async no-module \
          no-engine no-legacy --prefix="$PREFIX" \
          CC="$CC" CFLAGS="$CFLAGS" LDFLAGS="$LDFLAGS"
        ;;
    esac
  ) >>"$log" 2>&1 || { record "$name" false "$stage" "$log" $((SECONDS-t0)); return 0; }

  stage="build"
  (
    cd "$SRC/$dir"
    [ -z "$host_build_fix" ] || clean_host_env
    case "$kind" in
      openssl) make -j"$JOBS" build_libs ;;
      meson)   ninja -C build -j"$JOBS" ;;
      *)       make -j"$JOBS" $host_build_fix ;;
    esac
  ) >>"$log" 2>&1 || { record "$name" false "$stage" "$log" $((SECONDS-t0)); return 0; }

  stage="install"
  (
    cd "$SRC/$dir"
    [ -z "$host_build_fix" ] || clean_host_env
    case "$kind" in
      openssl) make install_dev ;;
      meson)   ninja -C build install ;;
      *)       make install $host_build_fix ;;
    esac
  ) >>"$log" 2>&1 || { record "$name" false "$stage" "$log" $((SECONDS-t0)); return 0; }

  record "$name" true done "$log" $((SECONDS-t0))
  # 源码目录占空间，成功后清掉，只保留 prefix 与日志
  rm -rf "$SRC/$dir"
}

# ---- 主循环 -----------------------------------------------------------------
python3 - "$MANIFEST" "$PACKAGES" > "$WORK/sysroot/plan.tsv" <<'PY'
import json,sys
m=json.load(open(sys.argv[1])); want=[x.strip() for x in sys.argv[2].split(',') if x.strip()]
for p in m['packages']:
    if p['name'] in want:
        print('\t'.join([p['name'],p['archive'],p['directory'],p['url'],p['sha256'],p['build']]))
PY

while IFS=$'\t' read -r name archive dir url sha kind; do
  [ -n "$name" ] || continue
  build_one "$name" "$archive" "$dir" "$url" "$sha" "$kind"
done < "$WORK/sysroot/plan.tsv"

echo
echo "== sysroot 产物 =="
find "$PREFIX" -name '*.a' -type f 2>/dev/null | sort | head -40
echo "  .pc 文件数：$(find "$PREFIX/lib/pkgconfig" -name '*.pc' 2>/dev/null | wc -l | tr -d ' ')"
echo "  静态库数量：$(find "$PREFIX" -name '*.a' -type f 2>/dev/null | wc -l | tr -d ' ')"

# 把静态库清单写给下一步（合并 libqemu-arm.a 时用）
find "$PREFIX" -name '*.a' -type f 2>/dev/null | sort > "$WORK/sysroot/deps-libs.txt"
echo "OK: 依赖阶段结束（逐包结果见 status/）"
