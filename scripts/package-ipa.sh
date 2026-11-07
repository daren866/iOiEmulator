#!/usr/bin/env bash
# 把 xcodebuild archive 产出的未签名 .app 打成侧载用 .ipa。
# CI 与本地共用同一份逻辑，避免工作流里塞一长串 shell。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-iOiEmulator}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$ROOT/build/iOiEmulator.xcarchive}"
IPA_DIR="${IPA_DIR:-$ROOT/build/ipa}"
SHORT_SHA="$(echo "${GITHUB_SHA:-local}" | cut -c1-7)"
IPA_NAME="${IPA_NAME:-${APP_NAME}_unsigned_arm64_${SHORT_SHA}.ipa}"

echo "== 定位 .app =="
APP_DIR="$ARCHIVE_PATH/Products/Applications"
if [ ! -d "$APP_DIR" ]; then
  echo "ERROR: 找不到 $APP_DIR" >&2
  exit 1
fi
APP_BUNDLE="$(find "$APP_DIR" -maxdepth 1 -name '*.app' -type d | head -n 1)"
if [ -z "$APP_BUNDLE" ]; then
  echo "ERROR: $APP_DIR 中没有 .app" >&2
  exit 1
fi
BUNDLE_BASE="$(basename "$APP_BUNDLE" .app)"
BIN="$APP_BUNDLE/${BUNDLE_BASE}"
if [ ! -f "$BIN" ]; then
  BIN="$APP_BUNDLE/$APP_NAME"
fi
if [ ! -f "$BIN" ]; then
  echo "ERROR: 找不到主可执行文件" >&2
  exit 1
fi
echo "  app : $APP_BUNDLE"
echo "  bin : $BIN"

echo "== 校验架构 =="
lipo -info "$BIN"
if ! lipo -archs "$BIN" | grep -qw arm64; then
  echo "ERROR: 二进制不含 arm64" >&2
  exit 1
fi

echo "== 修复可执行权限 =="
chmod +x "$BIN"

echo "== ad-hoc 伪签名（TrollStore 需要）=="
if command -v ldid >/dev/null 2>&1; then
  if ldid -S "$BIN"; then
    echo "  ldid -S 完成"
  else
    echo "WARN: ldid 失败，产出纯未签名 IPA" >&2
  fi
else
  echo "WARN: 未找到 ldid，产出纯未签名 IPA（可用 AltStore 等重签）" >&2
fi

echo "== 打包 Payload =="
rm -rf "$IPA_DIR/Payload" "$IPA_DIR/$IPA_NAME"
mkdir -p "$IPA_DIR/Payload"
cp -R "$APP_BUNDLE" "$IPA_DIR/Payload/"
find "$IPA_DIR/Payload" -name '.DS_Store' -delete
( cd "$IPA_DIR" && zip -qry "$IPA_NAME" Payload )

echo "== 生成校验值与构建信息 =="
( cd "$IPA_DIR" && shasum -a 256 "$IPA_NAME" > SHA256SUMS )

XCODE_VER="$(xcodebuild -version 2>/dev/null | head -n 1 || echo 'unknown')"
SDK_VER="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo 'unknown')"
cat > "$IPA_DIR/build-info.txt" <<EOF
iOiEmulator unsigned IPA build info
-----------------------------------
ipa            : $IPA_NAME
commit         : ${GITHUB_SHA:-local}
short_sha      : $SHORT_SHA
branch         : ${GITHUB_REF_NAME:-local}
run_number     : ${GITHUB_RUN_NUMBER:-local}
app_name       : $APP_NAME
bundle_id      : com.daren866.iOiEmulator
arch           : arm64
min_os         : 15.0
signing        : none (ad-hoc ldid signature may be present)
xcode          : $XCODE_VER
iphoneos_sdk   : $SDK_VER
engine_linked  : no (qemu-ios port pending, see docs/PORTING.md)
built_at       : $(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

echo "== 产物 =="
ls -lh "$IPA_DIR/$IPA_NAME"
cat "$IPA_DIR/SHA256SUMS"
echo "OK: $IPA_DIR/$IPA_NAME"
