#!/usr/bin/env bash
# 引擎 → IPA：把 ③ 产出的引擎产物落到 engine/prebuilt/，供 Tuist 条件链接。
# 找不到产物不是错误 —— 照常产出「应用外壳」IPA，并把状态写进 GITHUB_ENV。
#
# 查找顺序：
#   1) 同 run 的 artifact（engine-pipeline.yml 调用时）
#   2) 最近成功的 engine-latest Release（push 自动打包时）
#   3) 本地已有的 engine/prebuilt/
#
# 引擎产物结构（见 scripts/build-engine-lib.sh）：
#   libqemu-arm.a           —— QEMU 显式对象 + 入口对象（链接时用 -force_load 整体拉入）
#   libqemuutil.a 等        —— QEMU 自身工具库（惰性链接）
#   libglib-2.0.a 等        —— sysroot 依赖库（惰性链接）
#   include/                —— 引擎头文件
# 本脚本把所有 .a 复制到 engine/prebuilt/，并生成 engine_libflags.txt：
#   -Wl,-force_load,<prebuilt>/libqemu-arm.a -Wl,-start-group -lqemuutil ... -Wl,-end-group
# Project.swift 读取该文件拼进 OTHER_LDFLAGS。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREBUILT="$ROOT/engine/prebuilt"
CANDIDATE="${ENGINE_ARTIFACT_DIR:-$ROOT/.engine-work/engine-artifact}"
RELEASE_TAG="${ENGINE_RELEASE_TAG:-engine-latest}"

mkdir -p "$PREBUILT"

say() { echo "  $*"; }

emit() {
  local linked="$1" reason="$2"
  echo "ENGINE_LINKED=$linked" >> "${GITHUB_ENV:-/dev/null}"
  echo "engine_linked=$linked" >> "${GITHUB_OUTPUT:-/dev/null}"
  cat > "$PREBUILT/ENGINE_INFO.json" <<EOF
{
  "linked": $linked,
  "reason": "$reason",
  "artifact_dir": "${CANDIDATE}",
  "release_tag": "${RELEASE_TAG}",
  "commit": "${GITHUB_SHA:-local}",
  "checked_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF
}

# 生成链接标志文件：force_load 核心库 + 其余 .a 惰性链接。
# 注意：Apple 的 ld64 不支持 GNU ld 的 -start-group/-end-group（会报
# "unknown options"）。ld64 对静态库默认惰性搜索并会自动多遍重扫以解决
# 归档间的循环依赖，因此只需依次列出 -l 即可（这恰好也是 ③ 修复 2312 个
# 重复符号的关键：不 force_load 工具库，pci-stub.o 等按需成员就不被硬拉入）。
gen_flags() {
  local dir="$1"
  {
    echo "-Wl,-force_load,$dir/libqemu-arm.a"
    for a in "$dir"/*.a; do
      [ -e "$a" ] || continue
      bn="$(basename "$a")"
      [ "$bn" = "libqemu-arm.a" ] && continue
      nm="${bn#lib}"; nm="${nm%.a}"
      echo "-l$nm"
    done
  } > "$dir/engine_libflags.txt"
  say "已生成 engine_libflags.txt："
  while IFS= read -r l; do say "  $l"; done < "$dir/engine_libflags.txt"
}

# 引擎接好后，尽量把固件制备库 libltfw.a（firmwarekit wrapper）也带上。
# 来源顺序：同 run artifact（下载到 ENGINE_ARTIFACT_DIR/firmware-kit）→
# firmware-kit-latest Release → 本地已有。找不到不报错（制备功能随库缺失降级）。
link_firmware_kit() {
  local found=""
  local dirs=("$CANDIDATE/firmware-kit" "$CANDIDATE")
  for d in "${dirs[@]}"; do
    if [ -f "$d/libltfw.a" ]; then
      cp "$d/libltfw.a" "$PREBUILT/" 2>/dev/null || true
      mkdir -p "$PREBUILT/include"
      cp "$d/ltfw.h" "$PREBUILT/include/" 2>/dev/null || true
      found="artifact"
      break
    fi
  done
  if [ -z "$found" ] && command -v gh >/dev/null 2>&1 && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    local TMP
    TMP="$(mktemp -d)"
    if gh release download firmware-kit-latest --repo "$GITHUB_REPOSITORY" \
         --pattern 'libltfw.a' --pattern 'ltfw.h' --dir "$TMP" --clobber >/dev/null 2>&1 \
         && [ -f "$TMP/libltfw.a" ]; then
      cp "$TMP/libltfw.a" "$PREBUILT/" 2>/dev/null || true
      mkdir -p "$PREBUILT/include"
      cp "$TMP/ltfw.h" "$PREBUILT/include/" 2>/dev/null || true
      found="release"
    fi
    rm -rf "$TMP"
  fi
  if [ -z "$found" ] && [ -f "$PREBUILT/libltfw.a" ]; then
    found="local"
  fi
  if [ -n "$found" ]; then
    say "固件制备库 libltfw.a 已接入（$found）"
  else
    say "::warning::未找到 libltfw.a，IPA 将不含固件导入功能"
  fi
}

# 从一个源目录接入引擎：复制全部 .a + include，生成 flags，标记 linked=true。
# 注意：find 找到的 libqemu-arm.a 可能在子目录（如 artifact 解压后的 engine-out/），
# 因此一律从「实际包含 libqemu-arm.a 的目录」复制，而不是 $src 顶层。
link_engine_from() {
  local src="$1" label="$2"
  local LIB
  LIB="$(find "$src" -name 'libqemu-arm.a' -type f 2>/dev/null | head -n 1)"
  [ -n "$LIB" ] || return 1
  say "来源：$label → $LIB"
  local SRCDIR
  SRCDIR="$(dirname "$LIB")"
  # 复制全部静态库（核心库 + QEMU 工具库 + sysroot 依赖库）
  cp "$SRCDIR"/*.a "$PREBUILT"/ 2>/dev/null || true
  # 复制头文件
  mkdir -p "$PREBUILT/include"
  [ -d "$SRCDIR/include" ] && cp -R "$SRCDIR/include/." "$PREBUILT/include/" 2>/dev/null || true
  cp "$SRCDIR"/qemu-ios-ui.h "$PREBUILT/include/" 2>/dev/null || true
  # 关键校验：核心库必须真的复制到位。否则 engine/prebuilt/libqemu-arm.a 不存在，
  # Project.swift 会判成外壳（编译 -DSHELL_ONLY、不挂 OTHER_LDFLAGS），而本脚本却
  # 误报 linked=true，最终产出「未链接引擎却标注已链接」的假 IPA。复制失败则回退外壳。
  if [ ! -f "$PREBUILT/libqemu-arm.a" ]; then
    say "::warning::核心库未能复制到 engine/prebuilt，放弃引擎链接"
    emit false "libqemu-arm.a-not-copied"
    return 1
  fi
  link_firmware_kit
  gen_flags "$PREBUILT"
  emit true "$label"
  echo "OK: 引擎已接入"
  return 0
}

echo "== 查找引擎产物 =="

# 1) 同 run artifact
if [ -d "$CANDIDATE" ] && link_engine_from "$CANDIDATE" "artifact"; then
  exit 0
fi

# 2) engine-latest Release
if command -v gh >/dev/null 2>&1 && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  TMP="$(mktemp -d)"
  if gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
       --pattern 'qemu-engine*.tar.gz' --pattern 'libqemu-arm.a' \
       --dir "$TMP" --clobber >/dev/null 2>&1; then
    TAR="$(find "$TMP" -name 'qemu-engine*.tar.gz' -type f 2>/dev/null | head -n 1)"
    if [ -n "$TAR" ]; then
      EXT="$TMP/extracted"
      mkdir -p "$EXT"
      tar xzf "$TAR" -C "$EXT" 2>/dev/null || true
      if link_engine_from "$EXT" "release"; then
        rm -rf "$TMP"
        exit 0
      fi
    fi
  fi
  rm -rf "$TMP"
fi

# 3) 本地已存在
if [ -f "$PREBUILT/libqemu-arm.a" ] && link_engine_from "$PREBUILT" "local"; then
  exit 0
fi

say "未找到 libqemu-arm.a（artifact / $RELEASE_TAG / 本地均无）"
say "本次 IPA 为应用外壳，引擎状态将在 Release 说明中标注"
rm -f "$PREBUILT/libqemu-arm.a"
emit false "no-engine-artifact"
echo "OK: 跳过引擎链接"
