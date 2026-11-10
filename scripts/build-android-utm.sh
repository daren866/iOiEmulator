#!/usr/bin/env bash
#
# build-android-utm.sh
# ---------------------------------------------------------------------------
# 在 macOS 上把「裁剪版 UTM（仅 arm 客户机）+ 安卓 4.0 镜像」构建为未签名 IPA。
# 流程：
#   1) 准备 UTM（克隆 + 裁剪 TARGET_LIST）
#   2) build_dependencies.sh -p ios-tci -a arm64   （编译 QEMU 10.0.12-utm + 依赖；
#       patches/sources 会被脚本自动 source，提供 QEMU_SRC 等下载地址）
#   3) build_utm.sh -k iphoneos -s iOS-SE -a "arm64 arm64e"   （UTM-SE = 无 JIT，可无签名侧载）
#   4) package.sh ipa-se UTM.xcarchive .   （产出「UTM SE.ipa」未签名包）
#
# 安卓镜像不在这里下载（按需求在 App 首次启动时由 fetch-android-images.sh 拉取）。
# 如需把镜像内嵌进 IPA 离线可用，取消下面那行注释。
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
UTM_DIR="${UTM_DIR:-$ROOT/UTM}"

echo "========== 1/3 准备 UTM（克隆 + 裁剪）=========="
bash "$HERE/trim-utm.sh" "$UTM_DIR"

cd "$UTM_DIR"
echo "========== 2/3 构建 UTM-SE 依赖（ios-tci, arm64）=========="
# 需要 Xcode / Command Line Tools 与 build_dependencies.sh 要求的 host 工具（bison 等）。
./scripts/build_dependencies.sh -p ios-tci -a arm64

# （可选）内嵌镜像：取消下一行注释会把安卓 4.0 镜像打进 App Bundle 的 Android40/ 目录。
# bash "$HERE/fetch-android-images.sh" OUT_DIR="$UTM_DIR/Platform/Assets/Android40"

echo "========== 3/3 打包未签名 IPA（iOS-SE, arm64 + arm64e）=========="
./scripts/build_utm.sh -k iphoneos -s iOS-SE -a "arm64 arm64e" -o UTM
./scripts/package.sh ipa-se UTM.xcarchive .
echo "完成。产出：UTM SE.ipa （可用 AltStore / 爱思 / TrollStore 等侧载）"
