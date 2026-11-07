#!/usr/bin/env bash
# =============================================================================
# qemu-ios → iOS arm64 交叉编译「配方草案」
#
# 状态：DRAFT，未经真机验证。它需要 macOS + Xcode，且必须先完成
#       docs/PORTING.md 第 1 步（把设备模型 rebase 到 utmapp/qemu）。
#       本脚本只做可自动化的准备与配置生成，不伪装成"一键编译成功"。
#
# 依据：
#   - UTM 的 QEMU iOS host 补丁（Joelle van Dyne, qemu-devel 2021-01）
#   - UTM scripts/build_dependencies.sh -p ios-tci -a arm64
#   - qemu-ios docs/research/ipod-touch-2g-on-iphone.md（2026-08-03 可行性研究）
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/engine/ios-build"
ENGINE_TREE="${ENGINE_TREE:-$ROOT/engine/vendor/qemu-ios-lighttouch-v0.0.13}"
SDK="${IOS_SDK:-iphoneos}"
MIN_IOS="${MIN_IOS_VERSION:-15.0}"
TC_BACKEND="${TCG_BACKEND:-tci}"   # tci | tcti | jit(需侧载 JIT 权限)

echo "== 环境检查 =="
if [ "$(uname -s)" != "Darwin" ]; then
  echo "ERROR: 交叉编译 iOS 需要 macOS + Xcode（当前为 $(uname -s)）。" >&2
  echo "       本脚本在 Linux 上只能用于生成配置，请在 Mac 上执行编译阶段。" >&2
  GEN_ONLY=1
else
  GEN_ONLY=0
  xcodebuild -version
fi

SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path 2>/dev/null || echo '/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk')"
echo "  SDKROOT      : $SDKROOT"
echo "  MIN_IOS      : $MIN_IOS"
echo "  TCG backend  : $TC_BACKEND"
echo "  ENGINE_TREE  : $ENGINE_TREE"

mkdir -p "$OUT"

echo
echo "== 生成 Meson iOS 交叉编译配置 =="
cat > "$OUT/ios-cross.txt" <<EOF
[binaries]
c       = ['xcrun', '--sdk', $SDK, 'clang']
cpp     = ['xcrun', '--sdk', $SDK, 'clang++']
objc    = ['xcrun', '--sdk', $SDK, 'clang']
ar      = ['xcrun', '--sdk', $SDK, 'ar']
strip   = ['xcrun', '--sdk', $SDK, 'strip', '-x']
pkg-config = ['pkg-config']

[built-in options]
c_args      = ['-arch', 'arm64', '-isysroot', '$SDKROOT', '-miphoneos-version-min=$MIN_IOS', '-fembed-bitcode-marker']
cpp_args    = ['-arch', 'arm64', '-isysroot', '$SDKROOT', '-miphoneos-version-min=$MIN_IOS']
c_link_args = ['-arch', 'arm64', '-isysroot', '$SDKROOT', '-miphoneos-version-min=$MIN_IOS']

[host_machine]
system     = 'darwin'
cpu_family = 'aarch64'
cpu        = 'arm64'
endian     = 'little'

[properties]
# iOS 不允许 fork/exec、不允许 system()，QEMU 需按 UTM 补丁做特性探测
needs_exe_wrapper = true
EOF
echo "  已写入 $OUT/ios-cross.txt"

echo
echo "== 生成 QEMU configure 配方（供人工执行 / 后续脚本化）=="
case "$TC_BACKEND" in
  tci)  TCG_FLAG="--enable-tcg-interpreter" ;;
  tcti) TCG_FLAG="--enable-tcg-threaded-interpreter" ;;
  jit)  TCG_FLAG="--enable-tcg" ;;
  *) echo "ERROR: 未知 TCG_BACKEND=$TC_BACKEND" >&2; exit 1 ;;
esac

cat > "$OUT/configure-qemu-ios.sh" <<EOF
#!/usr/bin/env bash
# 在 rebase 后的 utmapp/qemu 树上执行
set -euo pipefail
cd "\$1"
mkdir -p build-ios && cd build-ios
../configure \\
  --cross-file="$OUT/ios-cross.txt" \\
  --target-list=arm-softmmu \\
  --disable-cocoa --disable-coreaudio --disable-slirp-smbd \\
  --disable-sdl --disable-gtk --disable-vnc --disable-spice \\
  --enable-ucontext \\
  --disable-tools --disable-docs --disable-tests \\
  $TCG_FLAG \\
  --extra-cflags="-Wno-error=deprecated-declarations"
ninja qemu-system-arm
# 再把同一批 object 重新链成库（参考 qemu-ios contrib/macos-app/make-dylib-macos.sh），
# iOS 上需打包成 .framework 而不是裸 dylib。
EOF
chmod +x "$OUT/configure-qemu-ios.sh"
echo "  已写入 $OUT/configure-qemu-ios.sh"

echo
echo "== 仍需人工完成的步骤（见 docs/PORTING.md）=="
cat <<'STEPS'
  1. rebase：把 qemu-ios (QEMU 8.2.0) 的 hw/arm/ 设备模型迁到 utmapp/qemu 10.0.2
     的 iOS-host 分支。该 fork 的 diff 近乎纯增量（+29657/-214 行），
     tcg/、accel/、target/arm/ 均未修改，风险主要在构建系统。
  2. 依赖 iOS 化：glib、pixman、libslirp、pcre2、openssl、FFmpeg(需 --enable-encoder=aac)、
     libplist/libusbmuxd/libimobiledevice/libtatsu，全部编成静态库并打包为 framework。
     可直接复用 UTM 的 scripts/build_dependencies.sh -p ios-tci -a arm64 产物。
  3. host GL 层：把 hw/arm/gles-host.c 的 CGL 段（~40 行）换成 EAGLContext，
     *EXT FBO 后缀改 *OES。iOS 的 OpenGLES.framework 仍有完整 GLES 1.1 固定功能管线。
  4. 单进程化：iOS 禁止 fork/exec helper，usbmuxd / FirmwareKit / GuestAgent
     必须改为进程内线程 + 静态库调用（这是 App 壳层最大改动）。
  5. 固件制备：IPSW 解密与 NAND 制备不能放进 CI/仓库，需在受控环境完成，
     或由使用者通过 Files App 导入 .itbase；引擎可用 migrate file: 快照跳过启动。
  6. 链接：把 libqemu-arm framework 接入 Tuist/Package.swift，实现
     iOiEmulator/Engine/EmulatorEngine.swift 的 QemuEngineBridge。
STEPS

echo
if [ "$GEN_ONLY" -eq 1 ]; then
  echo "NOTE: 当前非 macOS，仅生成配置，未执行编译。"
else
  echo "NOTE: 配置为草案，请按上面 6 步完成 rebase 与依赖后再执行 $OUT/configure-qemu-ios.sh"
fi
