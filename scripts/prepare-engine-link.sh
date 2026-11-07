#!/usr/bin/env bash
# 引擎 → IPA：把 ③ 产出的引擎产物落到 engine/prebuilt/，供 Tuist 条件链接。
# 找不到产物不是错误 —— 照常产出「应用外壳」IPA，并把状态写进 GITHUB_ENV。
#
# 查找顺序：
#   1) 同 run 的 artifact（engine-pipeline.yml 调用时）
#   2) 最近成功的 engine-latest Release（push 自动打包时）
#   3) 本地已有的 engine/prebuilt/
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

echo "== 查找引擎产物 =="

# 1) 同 run artifact
if [ -d "$CANDIDATE" ]; then
  LIB=$(find "$CANDIDATE" -name 'libqemu-arm.a' -type f 2>/dev/null | head -n 1)
  if [ -n "$LIB" ]; then
    say "来源：同 run artifact → $LIB"
    cp "$LIB" "$PREBUILT/libqemu-arm.a"
    HDR_DIR=$(dirname "$LIB")/include
    [ -d "$HDR_DIR" ] && cp -R "$HDR_DIR/." "$PREBUILT/include/" 2>/dev/null || mkdir -p "$PREBUILT/include"
    cp "$(dirname "$LIB")/qemu-ios-ui.h" "$PREBUILT/include/" 2>/dev/null || true
    emit true "artifact"
    echo "OK: 引擎已接入"
    exit 0
  fi
fi

# 2) engine-latest Release
if command -v gh >/dev/null 2>&1 && [ -n "${GITHUB_REPOSITORY:-}" ]; then
  TMP=$(mktemp -d)
  if gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
       --pattern 'qemu-engine*.tar.gz' --pattern 'libqemu-arm.a' \
       --dir "$TMP" --clobber >/dev/null 2>&1; then
    TAR=$(find "$TMP" -name 'qemu-engine*.tar.gz' -type f 2>/dev/null | head -n 1)
    [ -n "$TAR" ] && tar xzf "$TAR" -C "$TMP" 2>/dev/null || true
    LIB=$(find "$TMP" -name 'libqemu-arm.a' -type f 2>/dev/null | head -n 1)
    if [ -n "$LIB" ]; then
      say "来源：Release $RELEASE_TAG → $LIB"
      cp "$LIB" "$PREBUILT/libqemu-arm.a"
      mkdir -p "$PREBUILT/include"
      emit true "release"
      echo "OK: 引擎已接入"
      exit 0
    fi
  fi
  rm -rf "$TMP"
fi

# 3) 本地已存在
if [ -f "$PREBUILT/libqemu-arm.a" ]; then
  say "来源：本地 engine/prebuilt/"
  emit true "local"
  echo "OK: 引擎已接入"
  exit 0
fi

say "未找到 libqemu-arm.a（artifact / $RELEASE_TAG / 本地均无）"
say "本次 IPA 为应用外壳，引擎状态将在 Release 说明中标注"
rm -f "$PREBUILT/libqemu-arm.a"
emit false "no-engine-artifact"
echo "OK: 跳过引擎链接"
