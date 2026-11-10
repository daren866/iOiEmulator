#!/usr/bin/env bash
#
# fetch-goldfish-qemu.sh — 基座无关地拉取「带 goldfish/Android 机器」的 QEMU 源码
#
# 这是路线 1（goldfish QEMU → iOS）的通用底座拉取脚本，供 CI（macos-15 runner）
# 与本地 Mac 使用。它不依赖 UTM，直接克隆 AOSP platform/external/qemu，并可选套用
# patches/ios-port/ 下的 iOS 移植补丁。
#
# 用法：
#   QEMU_REF=<ref> bash scripts/fetch-goldfish-qemu.sh [输出目录]
#
# 环境变量：
#   QEMU_REF      必填（或给默认值）。AOSP external/qemu 的标签/分支。
#                 - 1A（原汁原味 boot 4.0 镜像）：android-4.0.4_r2.1   （goldfish QEMU 1.x）
#                 - 1B（更易在 iOS 编译）：        现代标签，如 emu-14.1.5 / android-14.0.0_r1
#   QEMU_REPO     可选，默认 https://android.googlesource.com/platform/external/qemu
#   QEMU_PROXY    可选，给上面 REPO 套一层代理前缀（如 https://v4.gh-proxy.org/https://...）
#   APPLY_IOS_PORT 可选，=1 时套用 patches/ios-port/ 下（*.patch）的补丁
#   DEPTH         可选，默认 1（浅克隆；AOSP qemu 历史极大）
#
set -o pipefail

REF="${QEMU_REF:-android-4.0.4_r2.1}"          # 默认走 1A 基座
REPO="${QEMU_REPO:-https://android.googlesource.com/platform/external/qemu}"
OUT="${1:-${QEMU_OUT_DIR:-$PWD/aosp-qemu}}"
DEPTH="${DEPTH:-1}"
HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH_DIR="$HERE/../patches/ios-port"

[ -n "$QEMU_PROXY" ] && REPO="$QEMU_PROXY$REPO"

echo "== 拉取 AOSP external/qemu =="
echo "  ref : $REF"
echo "  repo: $REPO"
echo "  out : $OUT"

if [ -d "$OUT/.git" ]; then
  echo "  (已存在，跳过克隆)"
else
  rm -rf "$OUT"
  # AOSP qemu 历史极大，浅克隆指定 ref；tag 也可作为 -b 参数（git 会 detached HEAD）
  if ! git clone --depth "$DEPTH" -b "$REF" "$REPO" "$OUT" 2>&1 | tail -20; then
    echo "::error::克隆失败（ref=$REF）。请确认 ref 存在且网络可达（mac runner 上 android.googlesource.com 通常可达）。"
    exit 1
  fi
fi

echo "== 落盘版本信息 =="
( cd "$OUT" && git describe --tags --always 2>/dev/null; git rev-parse HEAD ) > "$OUT/QEMU_SOURCE.txt" 2>/dev/null || true
cat "$OUT/QEMU_SOURCE.txt" 2>/dev/null

# goldfish 机器是否在树内？（不同基座差异巨大，仅做提示）
if [ -d "$OUT/hw/goldfish" ] || [ -d "$OUT/android" ] || grep -rq "goldfish" "$OUT/hw" 2>/dev/null; then
  echo "::notice::检测到 goldfish/Android 机器代码（基座含 goldfish）。"
else
  echo "::warning::未检测到 goldfish 机器代码——该基座可能已删除 goldfish（如现代 ranchu）。走 1B 需另行确认内核兼容性。"
fi

# 可选：套用 iOS 移植补丁
if [ "${APPLY_IOS_PORT:-0}" = "1" ]; then
  if [ -d "$PATCH_DIR" ] && ls "$PATCH_DIR"/*.patch >/dev/null 2>&1; then
    echo "== 套用 iOS 移植补丁（patches/ios-port/）=="
    for p in "$PATCH_DIR"/*.patch; do
      echo "  ↳ $p"
      ( cd "$OUT" && git apply --whitespace=nowarn "$p" ) || \
      ( cd "$OUT" && patch -p1 --batch --fuzz=3 < "$p" ) || \
      echo "    ::warning::补丁 $p 应用失败（基座不匹配或已部分合入），请人工核对。"
    done
  else
    echo "::warning:APPLY_IOS_PORT=1 但未找到 patches/ios-port/*.patch（补丁待按所选基座生成）。"
  fi
fi

echo "== 完成：QEMU 源码位于 $OUT =="
