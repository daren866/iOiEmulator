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
#   include/                —— 引擎头文件（qemu-ios-ui.h / qemu-ios-input.h）
# 本脚本把所有 .a 复制到 engine/prebuilt/，并生成 engine_libflags.txt：
#   -Wl,-force_load,<prebuilt>/libqemu-arm.a -Wl,-start-group -lqemuutil ... -Wl,-end-group
# Project.swift 读取该文件拼进 OTHER_LDFLAGS。
#
# 下载可靠性说明（这是「依旧无法下载依赖」的根因）：
#   GitHub Releases 的直连 CDN（github.com / objects.githubusercontent.com）在
#   macos-15 runner 上偶发超时 / 5xx / 返回错误页，而旧脚本用
#   `curl ... 2>/dev/null` 吞掉了错误、且不做大小校验，导致坏文件被当成下载成功、
#   tar 静默失败、最终退化成外壳 IPA。
#   本版改用：多镜像回退（gh-proxy 等）+ --retry-all-errors + 期望大小校验 +
#   错误页识别（<1KB 即视为失败）+ 全程可见日志。任一源成功即视为成功。
#
# 注意：本脚本「故意不用 set -u」。macOS 自带 /bin/bash 是 bash 3.2，对
#「local var」声明但未赋值、以及含非 ASCII 字符的变量名处理有缺陷，配合
# set -u 会误报 “xxx: unbound variable” 并中断整个 IPA 构建（这正是此前
# “found: unbound variable” 反复出现的根因）。本脚本的设计意图是「引擎缺失
# 就降级成外壳 IPA」而非崩溃，因此用 set -o pipefail 即可，不开 set -u。
set -o pipefail

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

# 人类可读字节数（macOS 无 numfmt，自实现）
num_h() {
  local n="${1:-0}"
  [ -z "${n##*[!0-9]*}" ] && { echo "$n"; return; }
  if [ "$n" -ge 1073741824 ]; then
    awk "BEGIN{printf \"%.1f GiB\", $n/1073741824}"
  elif [ "$n" -ge 1048576 ]; then
    awk "BEGIN{printf \"%.1f MiB\", $n/1048576}"
  elif [ "$n" -ge 1024 ]; then
    awk "BEGIN{printf \"%.1f KiB\", $n/1024}"
  else
    echo "${n} B"
  fi
}

# 文件字节数（兼容 BSD stat -f%z 与 GNU stat -c%s）
flsz() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

MIN_BYTES=32   # 仅用于「无期望大小时」兜底：小于此值视为空响应 / 错误页。
               # 真实完整性主要靠 API 回报的期望大小比对；GitHub 错误页通常 >> 此值。

# 给定主 URL，产出候选下载地址列表：官方优先，随后多个 gh-proxy 镜像兜底。
# macos-15 runner 直连 github Release CDN 不稳，镜像可救场。
mirror_urls() {
  local url="$1"
  printf '%s\n' "$url"
  case "$url" in
    https://github.com/*)
      printf '%s\n' \
        "https://gh-proxy.com/$url" \
        "https://v4.gh-proxy.org/$url" \
        "https://gh-proxy.net/$url" \
        "https://ghproxy.net/$url" \
        "https://mirror.ghproxy.com/$url"
      ;;
    https://objects.githubusercontent.com/*)
      printf '%s\n' \
        "https://gh-proxy.com/$url" \
        "https://v4.gh-proxy.org/$url"
      ;;
  esac
}

# 下载单个文件：多镜像回退 + 重试 + 大小校验 + 错误页识别。
# 用法：dl_file <期望字节数，可为空> <输出路径> <主URL>
# 返回 0 表示成功落下有效文件；1 表示所有源都失败。
# 重试预算刻意收紧：单文件最长 ~ connect-timeout×(镜像数)×重试次数，
# 避免某一个慢源把整条关键路径拖死（实测 gh-proxy 对极小文件也会卡连接）。
dl_file() {
  local expect="$1" out="$2" url="$3"
  local tmp="$out.part"
  rm -f "$tmp"
  local u=""
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    say "    ↳ $u"
    if curl -fL --retry-all-errors --retry 3 --retry-delay 2 \
         --retry-max-time 180 --connect-timeout 15 --max-time 1200 \
         -o "$tmp" "$u" 2>/dev/null; then
      local sz; sz="$(flsz "$tmp")"
      if [ "$sz" -lt "$MIN_BYTES" ]; then
        say "      ⚠ 仅 $(num_h "$sz")（疑似错误页），换源"
        continue
      fi
      if [ -n "$expect" ] && [ "$sz" != "$expect" ]; then
        say "      ⚠ 大小不符（期望 $(num_h "$expect")，实际 $(num_h "$sz")），换源"
        continue
      fi
      mv -f "$tmp" "$out"
      say "      ✓ 落盘 $(num_h "$sz")"
      return 0
    fi
    say "      ✗ 失败，换源"
  done < <(mirror_urls "$url")
  rm -f "$tmp"
  return 1
}

# 从 GitHub Releases 拉取匹配 glob 的资产清单（名称\t期望大小\t下载URL 每行一条），
# 并对每个资产调用 dl_file 下载到「当前目录」。
# 用 curl + Releases API，不依赖 gh CLI（macOS runner 默认未预装 gh）。
# 多镜像 / 重试 / 大小校验在 dl_file 内完成。返回 0 表示至少成功下载一个资产。
fetch_release_assets() {
  local tag="$1"; shift
  local repo="${GITHUB_REPOSITORY:-daren866/iOiEmulator}"
  local api="https://api.github.com/repos/$repo/releases/tags/$tag"
  local H=(-H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28")
  [ -n "${GITHUB_TOKEN:-}" ] && H+=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
  local json=""
  for attempt in 1 2 3; do
    json="$(curl -fsSL "${H[@]}" --connect-timeout 20 --max-time 60 "$api" 2>/dev/null)" && break
    say "    ⚠ Releases API 取清单失败（第 $attempt 次），重试"; sleep 3
  done
  [ -n "$json" ] || { say "    ✗ 无法获取 $tag 资产清单（API 失败）"; return 1; }

  local manifest; manifest="$(mktemp)"
  printf '%s' "$json" | python3 -c "
import sys, json, fnmatch
d = json.load(sys.stdin)
for a in d.get('assets', []):
    if any(fnmatch.fnmatch(a['name'], p) for p in set(sys.argv[1:])):
        print(a['name'] + '\t' + str(a.get('size', 0)) + '\t' + a['browser_download_url'])
" "$@" > "$manifest" 2>/dev/null || { rm -f "$manifest"; return 1; }

  local got=0 aname="" asize="" aurl=""
  while IFS=$'\t' read -r aname asize aurl; do
    [ -n "$aname" ] || continue
    say "下载 $aname（期望 $(num_h "$asize")）"
    if dl_file "$asize" "$aname" "$aurl"; then got=1; fi
  done < "$manifest"
  rm -f "$manifest"
  return $got
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

# 从一个源目录接入引擎：复制全部 .a + include，生成 flags，标记 linked=true。
# 注意：find 找到的 libqemu-arm.a 可能在子目录（如 tar 解压后的 engine-out/），
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
  cp "$SRCDIR"/qemu-ios-input.h "$PREBUILT/include/" 2>/dev/null || true
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
  if [ -z "${found:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ]; then
    local TMP
    TMP="$(mktemp -d)"
    ( cd "$TMP" && fetch_release_assets firmware-kit-latest 'libltfw.a' 'ltfw.h' ) \
      && [ -f "$TMP/libltfw.a" ]
    if [ -f "$TMP/libltfw.a" ]; then
      cp "$TMP/libltfw.a" "$PREBUILT/" 2>/dev/null || true
      mkdir -p "$PREBUILT/include"
      cp "$TMP/ltfw.h" "$PREBUILT/include/" 2>/dev/null || true
      found="release"
    fi
    rm -rf "$TMP"
  fi
  if [ -z "${found:-}" ] && [ -f "$PREBUILT/libltfw.a" ]; then
    found="local"
  fi
  # 注意：用 ${found:-} 而非 $found —— macOS 自带 /bin/bash 是 bash 3.2，对多字节
  # 字符支持弱；若变量名在解析时混入无效字节导致「未绑定」，:- 默认空值可兜底，
  # 避免 set -u 下整段脚本崩溃（固件库缺失本就应按降级处理，而非中断 IPA 构建）。
  local msg
  if [ -n "${found:-}" ]; then
    msg="固件制备库 libltfw.a 已接入，来源： ${found}"
  else
    msg="::warning::未找到 libltfw.a，IPA 将不含固件导入功能"
  fi
  say "$msg"
}

echo "== 查找引擎产物 =="

# 1) 同 run artifact
if [ -d "$CANDIDATE" ] && link_engine_from "$CANDIDATE" "artifact"; then
  exit 0
fi

# 2) engine-latest Release（多镜像 + 重试 + 大小校验，不依赖 gh CLI）
#    关键路径只拉 qemu-engine.tar.gz（内含全部 .a + include/，大小已按 API
#    返回值校验）。SHA256SUMS 仅作最佳努力的完整性复核，失败不阻塞解包。
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  TMP="$(mktemp -d)"
  if ( cd "$TMP" && fetch_release_assets "$RELEASE_TAG" 'qemu-engine*.tar.gz' ) \
     && TAR="$(find "$TMP" -name 'qemu-engine*.tar.gz' -type f 2>/dev/null | head -n 1)" \
     && [ -n "$TAR" ]; then
    # 最佳努力拉 SHA256SUMS 做完整性校验（失败仅告警，不阻塞）
    ( cd "$TMP" && fetch_release_assets "$RELEASE_TAG" 'SHA256SUMS' >/dev/null 2>&1 ) || true
    if [ -f "$TMP/SHA256SUMS" ]; then
      if ( cd "$TMP" && grep -E 'qemu-engine\.tar\.gz$' SHA256SUMS \
            | shasum -a 256 -c - >/dev/null 2>&1 ); then
        say "tar 校验和通过"
      else
        say "::warning::tar 校验和不匹配，仍尝试解包"
      fi
    fi
    EXT="$TMP/extracted"
    mkdir -p "$EXT"
    if tar xzf "$TAR" -C "$EXT" 2>/dev/null; then
      if link_engine_from "$EXT" "release"; then
        rm -rf "$TMP"
        exit 0
      fi
    else
      say "::warning::tar 解包失败"
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
