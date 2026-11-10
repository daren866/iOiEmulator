#!/usr/bin/env bash
#
# trim-utm.sh  <DEST_DIR>
# ---------------------------------------------------------------------------
# 1) 经代理克隆 UTM（绕过 github 直连不稳），默认分支 master。
# 2) 把 QEMU 的 TARGET_LIST 裁剪为只保留：
#       arm-softmmu      -> arm32 客户机（对应安卓 armeabi-v7a）
#       aarch64-softmmu  -> arm64 客户机
#    删去 x86 / ppc / riscv / m68k 等无关架构（"-p ios-tci -a arm64" 走的就是这一行）。
#
# 注：UTM-SE 走 ios-tci（TCG 解释执行，无 JIT，可无签名侧载），我们只需 arm 客户机。
set -euo pipefail

UTM_REPO="${UTM_REPO:-https://github.com/utmapp/UTM.git}"
UTM_PROXY="${UTM_PROXY:-https://v4.gh-proxy.org}"
BRANCH="${UTM_BRANCH:-master}"
DEST="${1:-$(cd "$(dirname "$0")/.." && pwd)/UTM}"

echo "== 克隆 UTM: $UTM_REPO @ $BRANCH -> $DEST =="
if [ -d "$DEST/.git" ]; then
  echo "已存在，跳过克隆"
else
  if ! git clone --depth 1 --branch "$BRANCH" "$UTM_REPO" "$DEST" 2>/dev/null; then
    echo "直连失败，改用代理：$UTM_PROXY/$UTM_REPO"
    git clone --depth 1 --branch "$BRANCH" "$UTM_PROXY/$UTM_REPO" "$DEST"
  fi
fi

echo "== 裁剪 QEMU TARGET_LIST -> arm-softmmu,aarch64-softmmu =="
SCRIPT="$DEST/scripts/build_dependencies.sh"
if grep -q "target-list=aarch64-softmmu,i386-softmmu,ppc-softmmu,ppc64-softmmu,riscv64-softmmu,x86_64-softmmu,m68k-softmmu" "$SCRIPT"; then
  sed -i.bak -E 's/--target-list=aarch64-softmmu,i386-softmmu,ppc-softmmu,ppc64-softmmu,riscv64-softmmu,x86_64-softmmu,m68k-softmmu/--target-list=arm-softmmu,aarch64-softmmu/' "$SCRIPT"
  rm -f "$SCRIPT.bak"
  echo "已替换为：arm-softmmu,aarch64-softmmu"
else
  echo "::warning::未找到目标 TARGET_LIST 行，可能 UTM 版本已变，请手动检查 $SCRIPT"
fi

echo "== 完成。下一步：scripts/build-android-utm.sh =="
