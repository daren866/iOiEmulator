#!/usr/bin/env bash
#
# build-android-virt-kernel.sh — 为「路线 2」交叉编译一个能在 QEMU -machine virt
# （或 vexpress-a15）上启动的 Android 4.0 (Linux 3.0) 内核 + dtb。
# ---------------------------------------------------------------------------
# 为什么需要它：官方包里的 kernel-qemu 是 goldfish 内核，只在 goldfish 机器上跑；
# 路线 2 用 UTM 上游 QEMU 的 virt 机器，必须另编译内核。
#
# 现实约束（务必先读）：
#   - Android 4.0 用 Linux 3.0 内核；QEMU 的 ARCH_VIRT 支持在 3.11+ 才进主线。
#     因此 3.0 + -machine virt 需要把 ARCH_VIRT 反向移植（改动大）。
#   - 更省事的替代：用 -machine vexpress-a15（3.0 的 vexpress_defconfig 原生支持），
#     把下面 CONFIG_ARCH_VIRT 段换成 CONFIG_ARCH_VEXPRESS + CONFIG_MACH_VEXPRESS。
#   - 本脚本需要一套 ARM 交叉工具链（arm-none-eabi 或 aarch64-linux-android 的 32 位变体）。
#     macOS 上可用 brew install arm-linux-gnueabihf-binutils 等；Linux 用 apt 装。
#
# 用法：
#   TOOLCHAIN_PREFIX=arm-linux-gnueabihf- \
#   KERNEL_SRC=/path/to/kernel-3.0-ics \
#   bash scripts/build-android-virt-kernel.sh [OUT_DIR]
#
set -o pipefail

OUT_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)/Android40}"
KERNEL_SRC="${KERNEL_SRC:-$PWD/kernel-3.0-ics}"
PREFIX="${TOOLCHAIN_PREFIX:-arm-linux-gnueabihf-}"

say() { echo "  $*"; }
die() { echo "::error::$*" >&2; exit 1; }

[ -d "$KERNEL_SRC" ] || die "未找到内核源码 KERNEL_SRC=$KERNEL_SRC（请先获取 Android 4.0 的 Linux 3.0 内核树，含 Android 补丁）"
command -v "${PREFIX}gcc" >/dev/null 2>&1 || die "找不到交叉编译器 ${PREFIX}gcc"

cd "$KERNEL_SRC"
export ARCH=arm
export CROSS_COMPILE="$PREFIX"

# —— 内核配置：以 multi_v7 / vexpress 为基础，开启 QEMU virt 所需 + Android 必需 ——
# 若用 vexpress-a15 更稳：make vexpress_defconfig，再打开下面的 Android/虚拟化选项。
make multi_v7_defconfig 2>/dev/null || make vexpress_defconfig || die "生成 defconfig 失败"

# 追加关键开关（用 scripts/config，避免手改 .config）
cfg() { ./scripts/config --enable "$1" 2>/dev/null || true; }
cfg CONFIG_ARCH_VIRT          # QEMU virt 机器（3.0 上可能需反向移植，见上方说明）
cfg CONFIG_VIRTUALIZATION
cfg CONFIG_KVM                # 宿主侧才需要，客户机可关；此处留作参考
cfg CONFIG_ANDROID            # Android 基础支持
cfg CONFIG_ANDROID_BINDER     # binder（Android IPC，必需）
cfg CONFIG_ASHMEM             # ashmem（必需）
cfg CONFIG_STAGING            # 部分 Android 驱动在 staging
cfg CONFIG_VIRTIO
cfg CONFIG_VIRTIO_BLK
cfg CONFIG_VIRTIO_NET
cfg CONFIG_VIRTIO_CONSOLE
cfg CONFIG_VIRTIO_MMIO        # QEMU virt 的 virtio 走 mmio
cfg CONFIG_SERIAL_AMBA_PL011  # virt 的 ttyAMA0
cfg CONFIG_EXT4_FS
cfg CONFIG_TMPFS

make olddefconfig 2>/dev/null || true

say "开始编译内核 + dtb ($(nproc) 并行)"
make -j"$(nproc)" zImage dtbs 2>&1 | tail -25 || die "内核编译失败"

# 取产物
ZIMG="$(find . -name 'zImage' -type f | head -n1)"
DTB="$(find . -name '*.dtb' -type f | head -n1)"
[ -n "$ZIMG" ] || die "未生成 zImage"
mkdir -p "$OUT_DIR"
cp -f "$ZIMG" "$OUT_DIR/zImage"
[ -n "$DTB" ] && cp -f "$DTB" "$OUT_DIR/virt.dtb"
say "已产出：$OUT_DIR/zImage${DTB:+ + $OUT_DIR/virt.dtb}"
echo "KERNEL_OK"
