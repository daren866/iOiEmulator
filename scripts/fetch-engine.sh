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
  # FETCH_ONLY="LightTouch"：只拉取文件名含该子串的包（firmware-kit 只需要 App
  # 源码，不必下载 55MB 的引擎源码；留空则拉全部）。
  if [ -n "${FETCH_ONLY:-}" ] && [[ "$name" != *"${FETCH_ONLY}"* ]]; then
    return 0
  fi
  local target="$DEST/$name"
  if [ -f "$target" ] && sha256_check "$target" "$expected" >/dev/null 2>&1; then
    echo "== $name 已存在且校验通过，跳过下载"
    return 0
  fi
  echo "== 下载 $name"

  # 三种下载路径，任一成功即可：
  #   1) gh release download —— 走 API 认证直连，对大文件最稳（优先）
  #   2) curl 直连 github.com —— runner 本地网络通常最稳
  #   3) curl 走 gh-proxy 镜像 —— 仅本地直连不通时回退（镜像偶发 500）
  # FORCE_PROXY=1 时跳过前两种，直接走镜像（本地网络环境调试用）。
  download_via_gh() {
    [ -n "${FORCE_PROXY:-}" ] && return 1
    command -v gh >/dev/null 2>&1 || return 1
    echo "   尝试 gh release download（API 认证直连）"
    gh release download v0.0.13 --repo blake-lucas/LightTouch \
      --pattern "$name" --dir "$DEST" --clobber >/dev/null 2>&1 \
      && [ -f "$target" ]
  }
  download_via_curl_direct() {
    [ -n "${FORCE_PROXY:-}" ] && return 1
    echo "   尝试 curl 直连 github.com"
    curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 --max-time 900 \
      -o "$target" "${BASE}/${name}"
  }
  download_via_proxy() {
    echo "   尝试镜像 $PROXY"
    curl -fL --retry 5 --retry-delay 3 --connect-timeout 30 --max-time 900 \
      -o "$target" "${PROXY}/${BASE}/${name}"
  }

  local ok=0
  if download_via_gh; then ok=1
  elif download_via_curl_direct; then ok=1
  elif download_via_proxy; then ok=1
  fi
  if [ "$ok" -ne 1 ] || [ ! -f "$target" ]; then
    echo "ERROR: 所有下载方式均失败: $name" >&2
    rm -f "$target"
    return 1
  fi
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
