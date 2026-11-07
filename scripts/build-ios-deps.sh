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
PACKAGES="${PACKAGES:-libffi,pcre2,glib,pixman,openssl,proxy-libintl}"
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
export CXXFLAGS="-fPIC -O2"
export LDFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=$MIN_IOS"
export PATH="$BIN:$PATH"

# ---- Meson iOS cross file（依赖与 QEMU 共用）--------------------------------
cat > "$WORK/sysroot/ios-cross.ini" <<EOF
[binaries]
c        = ['$BIN/ios-clang']
cpp      = ['$BIN/ios-clang++']
objc     = ['$BIN/ios-clang']
ar       = ['$BIN/ios-ar']
ranlib   = ['$BIN/ios-ranlib']
strip    = ['xcrun', '--sdk', 'iphoneos', 'strip', '-x']
pkg-config = ['$BIN/ios-pkg-config']

[built-in options]
c_args      = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS', '-fPIC']
cpp_args    = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS', '-fPIC']
objc_args   = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS', '-fPIC']
c_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS']
cpp_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$MIN_IOS']

[host_machine]
system     = 'darwin'
cpu_family = 'aarch64'
cpu        = 'arm64'
endian     = 'little'

[properties]
needs_exe_wrapper = true
EOF
echo "  cross file: $WORK/sysroot/ios-cross.ini"

# ---- 工具函数 ---------------------------------------------------------------
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
  if [ "$ok" = "true" ]; then echo "  [OK]   ${name} (${secs} s)"
  else echo "  [FAIL] ${name} — ${stage}，日志：${log}"; fi
}

build_one() {
  local name="$1" archive="$2" dir="$3" url="$4" sha="$5" kind="$6"
  local log="$STATUS/$name.log"
  local t0=$SECONDS
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
          *)      EXTRA="" ;;
        esac
        ./configure --host="$HOST_TRIPLE" --prefix="$PREFIX" \
          --disable-shared --enable-static $EXTRA
        ;;
      meson)
        case "$name" in
          glib)
            EXTRA="-Dtests=false -Dinstalled_tests=false -Dglib_assert=false -Dglib_checks=false -Dxattr=false -Dlibmount=disabled -Dselinux=disabled -Dsysprof=disabled -Dman=false -Dgtk_doc=false -Dbsymbolic_functions=false -Dnls=disabled -Dintrospection=disabled"
            ;;
          pixman)
            EXTRA="-Dtests=disabled -Dgtk=disabled -Dlibpng=disabled -Dopenmp=disabled -Dloongson-mmi=disabled -Dmmx=disabled -Dsse2=disabled -Dssse3=disabled -Dvmx=disabled -Darm-simd=disabled -Dneon=disabled -Da64-neon=disabled"
            ;;
          proxy-libintl)
            EXTRA="-Dtests=false"
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
    case "$kind" in
      openssl) make -j"$JOBS" build_libs ;;
      meson)   ninja -C build -j"$JOBS" ;;
      *)       make -j"$JOBS" ;;
    esac
  ) >>"$log" 2>&1 || { record "$name" false "$stage" "$log" $((SECONDS-t0)); return 0; }

  stage="install"
  (
    cd "$SRC/$dir"
    case "$kind" in
      openssl) make install_dev ;;
      meson)   ninja -C build install ;;
      *)       make install ;;
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
