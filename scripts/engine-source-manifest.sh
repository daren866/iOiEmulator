#!/usr/bin/env bash
# 引擎 ①：解包关键文件、核验 iOS 宿主能力、生成可机读清单。
# 在 macOS runner 上执行；不编译，只做校验与盘点。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$ROOT/.engine-work}"
TARBALLS="${ENGINE_DEST:-$WORK/tarballs}"
QEMU_TGZ="$TARBALLS/qemu-ios-v0.0.13-source.tar.gz"

mkdir -p "$WORK/extract"

echo "== 校验源码包存在 =="
test -f "$QEMU_TGZ" || { echo "ERROR: 缺少 $QEMU_TGZ" >&2; exit 1; }
if command -v sha256sum >/dev/null 2>&1; then
  SUM=$(sha256sum "$QEMU_TGZ" | awk '{print $1}')
else
  SUM=$(shasum -a 256 "$QEMU_TGZ" | awk '{print $1}')
fi
echo "  qemu-ios SHA256 = $SUM"
[ "$SUM" = "2a88f42b3d103dc2dfb0f362349079b043b2b3d547068a90b06625079ffae369" ] \
  || { echo "ERROR: qemu-ios 源码包校验失败" >&2; exit 1; }

echo "== 抽取 iOS 宿主关键文件 =="
PREFIX="qemu-ios-lighttouch-v0.0.13"
for f in \
  contrib/ios-app/qemu-ios-ui.h \
  contrib/ios-app/qemu-ios-entry.c \
  contrib/ios-app/qemu-ios-ui.c \
  contrib/ios-app/qemu-ios-input.h \
  hw/arm/gles-host-eagl.c \
  hw/arm/meson.build \
  contrib/macos-app/make-dylib-macos.sh \
  contrib/portable/make-shared.py \
  contrib/portable/dependencies.json \
  meson.build; do
  tar xzf "$QEMU_TGZ" -C "$WORK/extract" "$PREFIX/$f" 2>/dev/null \
    || echo "  WARN: 未找到 $f"
done

SRC="$WORK/extract/$PREFIX"
cp "$SRC/contrib/ios-app/qemu-ios-ui.h" "$WORK/qemu-ios-ui.h"
cp "$SRC/contrib/portable/dependencies.json" "$WORK/dependencies.json"

echo "== 核验 iOS 宿主嵌入层 =="
ABI_HEADER="$SRC/contrib/ios-app/qemu-ios-ui.h"
EAGL="$SRC/hw/arm/gles-host-eagl.c"
MESON_ARM="$SRC/hw/arm/meson.build"
MESON_TOP="$SRC/meson.build"

ABI_COUNT=$(grep -c 'qemu_ios_' "$ABI_HEADER" || true)
HAS_MAIN=$(grep -c 'qemu_ios_main' "$ABI_HEADER" || true)
HAS_FRAME=$(grep -c 'qemu_ios_ui_frame' "$ABI_HEADER" || true)
HAS_TOUCH=$(grep -c 'qemu_ios_ui_touch' "$ABI_HEADER" || true)
HAS_EAGL=$([ -f "$EAGL" ] && echo 1 || echo 0)
HAS_TARGET_IPHONE=$(grep -ci 'TARGET_OS_IPHONE' "$MESON_ARM" || true)
HAS_APPLEFW=$(grep -ci 'appleframeworks' "$MESON_TOP" || true)

echo "  qemu-ios-ui.h ABI 符号数 : $ABI_COUNT"
echo "  qemu_ios_main            : $HAS_MAIN"
echo "  qemu_ios_ui_frame        : $HAS_FRAME"
echo "  qemu_ios_ui_touch        : $HAS_TOUCH"
echo "  gles-host-eagl.c         : $HAS_EAGL"
echo "  TARGET_OS_IPHONE 分支    : $HAS_TARGET_IPHONE"
echo "  appleframeworks 依赖     : $HAS_APPLEFW"

[ "$HAS_MAIN" -ge 1 ] || { echo "ERROR: 缺少 qemu_ios_main，iOS 嵌入层不完整" >&2; exit 1; }

echo "== 统计板级设备模型 =="
BOARD_FILES=$(tar tzf "$QEMU_TGZ" | grep -cE "^$PREFIX/hw/arm/(ipod|ipad|iphone|s5l|gles|guest|host-mic|nand|mrvl|tsl)" || true)
ARM_FILES=$(tar tzf "$QEMU_TGZ" | grep -cE "^$PREFIX/hw/arm/" || true)
echo "  hw/arm 文件数  : $ARM_FILES"
echo "  板级相关文件数 : $BOARD_FILES"

echo "== 生成清单 =="
cat > "$WORK/manifest.json" <<EOF
{
  "release": "v0.0.13",
  "source_sha256": "$SUM",
  "host_ios_abi": {
    "header": "contrib/ios-app/qemu-ios-ui.h",
    "abi_symbols": $ABI_COUNT,
    "qemu_ios_main": $([ "$HAS_MAIN" -ge 1 ] && echo true || echo false),
    "qemu_ios_ui_frame": $([ "$HAS_FRAME" -ge 1 ] && echo true || echo false),
    "qemu_ios_ui_touch": $([ "$HAS_TOUCH" -ge 1 ] && echo true || echo false)
  },
  "host_ios_eagl": $([ "$HAS_EAGL" -ge 1 ] && echo true || echo false),
  "target_os_iphone_branches": $HAS_TARGET_IPHONE,
  "appleframeworks_refs": $HAS_APPLEFW,
  "board_model_files": $BOARD_FILES,
  "hw_arm_files": $ARM_FILES,
  "entry_source": "contrib/ios-app/qemu-ios-entry.c",
  "ui_source": "contrib/ios-app/qemu-ios-ui.c",
  "engine_lib_recipe": "contrib/portable/make-shared.py (relink ninja objects, replace system/main.c)",
  "note": "源码包自带 iOS 宿主嵌入层；缺的是 iOS 交叉编译链与 App 链接，均由本仓库 workflows 提供"
}
EOF

echo "  清单：$WORK/manifest.json"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "path=$WORK/manifest.json" >> "$GITHUB_OUTPUT"
fi
echo "OK"
