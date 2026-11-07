#!/usr/bin/env bash
# 拉取并校验 engine/SOURCES.json 中锁定的两份引擎源码 tarball。
# 用法：GH_PROXY=https://v4.gh-proxy.org/ bash scripts/fetch-engine.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${ENGINE_DEST:-$ROOT/engine/vendor}"
PROXY="${GH_PROXY:-https://v4.gh-proxy.org/}"
# 去掉末尾多余的 /，再拼原 URL
PROXY="${PROXY%/}"
BASE="https://github.com/blake-lucas/LightTouch/releases/download/v0.0.13"

mkdir -p "$DEST"

sha256_check() {
  local file="$1" expected="$2"
  local actual
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "$file" | awk '{print $1}')"
  else
    actual="$(shasum -a 256 "$file" | awk '{print $1}')"
  fi
  if [ "$actual" != "$expected" ]; then
    echo "ERROR: SHA256 不匹配: $file" >&2
    echo "  expected: $expected" >&2
    echo "  actual  : $actual" >&2
    return 1
  fi
  echo "  SHA256 OK ($actual)"
}

fetch() {
  local name="$1" expected="$2"
  local target="$DEST/$name"
  if [ -f "$target" ] && sha256_check "$target" "$expected" >/dev/null 2>&1; then
    echo "== $name 已存在且校验通过，跳过下载"
    return 0
  fi
  echo "== 下载 $name"
  curl -fL --retry 3 --retry-delay 2 --connect-timeout 20 \
    -o "$target" "${PROXY}/${BASE}/${name}"
  sha256_check "$target" "$expected"
}

fetch "LightTouch-v0.0.13-source.tar.gz" \
  "668db421f229e7575c2e056a08f672f39f1cf9bf8ffe4efde6331448dfffdb1f"
fetch "qemu-ios-v0.0.13-source.tar.gz" \
  "2a88f42b3d103dc2dfb0f362349079b043b2b3d547068a90b06625079ffae369"

echo
echo "源码已就绪：$DEST"
echo "解包："
echo "  tar xzf '$DEST/qemu-ios-v0.0.13-source.tar.gz' -C engine/vendor"
echo "  tar xzf '$DEST/LightTouch-v0.0.13-source.tar.gz' -C engine/vendor"
