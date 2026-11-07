#!/usr/bin/env bash
# =============================================================================
# 引擎 ③-b：编译 QEMU 并把 ninja 的链接输入重新归档成 iOS 可用的静态库。
#
# 思路来自源码包自身的两个脚本：
#   contrib/macos-app/make-dylib-macos.sh  —— 替换 system/main.c 为 iOS 入口
#   contrib/portable/make-shared.py        —— 从 ninja 链接命令提取全部 objects
# macOS 用 dylib、Linux/Android 用 ELF .so；iOS 只能静态链接，所以这里用
# libtool -static 把 QEMU objects + 入口 objects + 依赖 .a 合成单个 libqemu-arm.a。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$ROOT/.engine-work}"
SRC="$WORK/qemu-src"
PREFIX="$WORK/sysroot/prefix"
BUILD="$WORK/qemu-build"
OUT="$WORK/engine-out"
JOBS="${LT_JOBS:-3}"

[ -f "$BUILD/build.ninja" ] || { echo "ERROR: 先执行 configure-engine-ios.sh" >&2; exit 2; }
mkdir -p "$OUT/include"

echo "== ninja 编译 qemu-system-arm =="
ninja -C "$BUILD" -j"$JOBS" -d keeprsp qemu-system-arm

echo
echo "== 提取 ninja 链接输入并归档静态库 =="
python3 - "$SRC" "$BUILD" "$PREFIX" "$OUT" <<'PY'
import json, pathlib, shlex, shutil, subprocess, sys, hashlib

src, build, prefix, out = map(pathlib.Path, sys.argv[1:5])

# 1) 用整张 compile_commands 的「并集」编译标志来编译 iOS 嵌入层。
#    仅复用 system/main.c 的参数不够：嵌入层引用 arm target 的头文件，
#    target_page.h 在 -DCOMPILING_PER_TARGET 下才 #include "cpu-param.h"，
#    且该 quote-include 需要 -I <src>/target/arm 才能解析。这些标志只出现在
#    target/arm/*.c 的编译命令里，故对全部命令取并集，保证不漏任何 include
#    路径或 target 宏。
#    关键：每个标志必须保持「原始 token 化」（-I 与路径、-arch 与 arm64 是
#    两个独立 argv）。ios-clang 包裹脚本会自动补 -arch/-isysroot/
#    -miphoneos-version-min，这里不再收集它们，避免重复或与 wrapper 冲突。
ccdb = json.loads((build / 'compile_commands.json').read_text())

compiler = None
seen = set()
base = []
for c in ccdb:
    args = shlex.split(c['command'])
    if compiler is None and args:
        compiler = args[:1]
    i = 0
    while i < len(args):
        a = args[i]
        if a in ('-I', '-iquote', '-isystem', '-idirafter', '-F'):
            if i + 1 < len(args):
                b = args[i + 1]
                key = a + ' ' + b
                if key not in seen:
                    seen.add(key); base += [a, b]
                i += 2; continue
        if a.startswith(('-I', '-iquote', '-isystem', '-idirafter', '-F', '-D')):
            if a not in seen:
                seen.add(a); base.append(a)
        elif a.startswith('-miphoneos-version-min=') or a in (
                '-fPIC', '-fno-pic', '-mno-outline-atomics',
                '-Wno-error=deprecated-declarations'):
            if a not in seen:
                seen.add(a); base.append(a)
        i += 1

base += ['-fPIC', '-I' + str(src / 'contrib/ios-app'),
         '-I' + str(src / 'contrib/macos-app'),
         '-iquote', str(build), '-iquote', str(src)]

extra_sources = [
    src / 'contrib/ios-app/qemu-ios-entry.c',
    src / 'contrib/ios-app/qemu-ios-ui.c',
]
extra_objs = []
for s in extra_sources:
    o = build / (s.stem + '.o')
    subprocess.run(compiler + base + ['-c', str(s), '-o', str(o)], cwd=build, check=True)
    extra_objs.append(str(o))

# 2) 取 ninja 对 qemu-system-arm 的链接命令，展开 @rsp。
#    关键：`ninna -t commands qemu-system-arm` 会连其依赖链一起返回，而
#    qemu-system-arm 的最后一步是「把 qemu-system-arm-unsigned 拷贝/签名成
#    qemu-system-arm」的自定义命令（cp/codesign），若取 lines[-1] 就拿到了这条
#    cp 命令，导致 .o / .a 全部漏收（实测：归档输入里 QEMU objects=0、链接 .a=0）。
#    这里直接针对真正的链接目标 qemu-system-arm-unsigned，并从中挑出「含 -o 输出」
#    的 clang 链接行，避免误用后续的 cp/codesign 命令。
link_text = ''
link_line = ''
for target in ('qemu-system-arm-unsigned', 'qemu-system-arm'):
    r = subprocess.run(['ninja', '-t', 'commands', target], cwd=build,
                       text=True, capture_output=True)
    if r.returncode == 0 and r.stdout.strip():
        link_text = r.stdout.strip()
        for ln in reversed(link_text.splitlines()):
            toks = shlex.split(ln)
            if toks and (toks[0].endswith('clang') or toks[0].endswith('clang++')) \
               and any(t.startswith('-o') for t in toks):
                link_line = ln
                break
        if link_line:
            break
if not link_line:
    raise RuntimeError('找不到 qemu-system-arm 的 clang 链接命令')
link = shlex.split(link_line)
expanded = []
for a in link:
    if a.startswith('@'):
        expanded += shlex.split((build / a[1:]).read_text())
    else:
        expanded.append(a)

# 3) 解析链接命令：提取 QEMU 显式 .o，并把 .a 按路径分为两类：
#      * qemu 工具库（build 目录下，如 libqemuutil.a）
#      * sysroot 依赖库（prefix/lib 下，如 libglib-2.0.a）
#    关键修复（此前 ④ IPA 报 ld: 2312 duplicate symbols）：
#      旧逻辑把「显式 .o + 入口 .o + 全部 .a」平铺进同一个 libqemu-arm.a，
#      再用 -force_load 整体拉入；这会把 QEMU 工具库里「仅按需拉取」的成员
#      （如 pci-stub.o）强制链接，与 msi.o 等冲突。真实 qemu-system-arm 链接
#      靠静态库的惰性解析只拉被引用的成员，因此这里改回：
#        - libqemu-arm.a 只装「显式 .o + 入口 .o」（按 realpath 去重，内部无冲突），
#          仍用 -force_load 整体拉入，避免单遍扫描导致的 Undefined symbols；
#        - QEMU 工具库、sysroot 依赖库保持为独立 .a，由 App 惰性链接。
#    另外同一 .o 可能被链接命令重复列出（@rsp 与显式并存，或 rsp 自身重复），
#    必须按 realpath 去重，否则会出现 gstring.c.o 两份这样的重复成员。
drop_next = False
objs = []
qemu_archives = []
sysroot_archives = []
seen_obj = set()
prefix_lib = prefix / 'lib'


def categorize(p: pathlib.Path):
    try:
        s = str(p.resolve())
    except Exception:
        s = str(p)
    if s.startswith(str(build)):
        return 'qemu'
    if s.startswith(str(prefix_lib)):
        return 'sysroot'
    return None


def resolve_lib(a: str):
    # 把 -lfoo / -l:libfoo.a 解析为磁盘上的 .a 绝对路径（若存在）
    if a.startswith('-l:'):
        name = a[3:]
    elif a.startswith('-l'):
        name = 'lib' + a[2:] + '.a'
    else:
        return None
    for base in (build, prefix_lib):
        cand = base / name
        if cand.exists():
            return str(cand.resolve())
    return None


for a in expanded:
    if a == '-o':
        drop_next = True
        continue
    if drop_next:
        drop_next = False
        continue
    if a.endswith('system_main.c.o'):
        continue  # 由 qemu-ios-entry.o 取代
    if a in ('-pie', '-Wl,-pie') or a.startswith('-Wl,--dynamic-list=') or a == '-shared':
        continue
    if a.endswith('.o'):
        p = pathlib.Path(a) if pathlib.Path(a).is_absolute() else (build / a)
        if not p.exists():
            continue
        rp = str(p.resolve())
        if rp in seen_obj:
            continue
        seen_obj.add(rp)
        objs.append(str(p))
    elif a.endswith('.a'):
        p = pathlib.Path(a) if pathlib.Path(a).is_absolute() else (build / a)
        cat = categorize(p)
        if cat == 'qemu':
            qemu_archives.append(str(p.resolve()))
        elif cat == 'sysroot':
            sysroot_archives.append(str(p.resolve()))
    elif a.startswith('-l'):
        rp = resolve_lib(a)
        if rp:
            if rp.startswith(str(build)):
                qemu_archives.append(rp)
            elif rp.startswith(str(prefix_lib)):
                sysroot_archives.append(rp)

# 4) 组装产物
# libqemu-arm.a = 入口 .o + 去重后的 QEMU 显式 .o（内部无冲突，可安全 -force_load）
lib = out / 'libqemu-arm.a'
subprocess.run(['libtool', '-static', '-o', str(lib)] + extra_objs + objs, check=True)
print(f'  -> {lib} ({lib.stat().st_size} bytes)')

# QEMU 工具库、sysroot 依赖库：保持独立 .a，平铺到 engine-out/ 供 App 惰性链接
def copy_archives(lst):
    n = 0
    for a in sorted(set(lst)):
        src = pathlib.Path(a)
        if src.exists():
            shutil.copy(src, out / src.name)
            n += 1
    return n


n_qemu = copy_archives(qemu_archives)
n_sysroot = copy_archives(sysroot_archives)

print(f'  iOS 入口 objects : {len(extra_objs)}')
print(f'  QEMU objects     : {len(objs)} (去重后)')
print(f'  QEMU 工具库 .a   : {n_qemu}')
print(f'  sysroot 依赖 .a  : {n_sysroot}')
print(f'  libqemu-arm.a 成员: {len(objs) + len(extra_objs)}')

# 5) 头文件与清单
for h in [src / 'contrib/ios-app/qemu-ios-ui.h',
          src / 'contrib/ios-app/qemu-ios-input.h']:
    if h.exists():
        (out / 'include' / h.name).write_bytes(h.read_bytes())

manifest = {
    'schema': 1,
    'library': lib.name,
    'sha256': hashlib.sha256(lib.read_bytes()).hexdigest(),
    'bytes': lib.stat().st_size,
    'target': 'arm64-apple-ios15.0',
    'tcg': 'interpreter (no JIT required)',
    'entry': 'qemu_ios_main',
    'abi_header': 'include/qemu-ios-ui.h',
    'qemu_objects': len(objs) + len(extra_objs),
    'qemu_libs': n_qemu,
    'sysroot_libs': n_sysroot,
    'note': ('libqemu-arm.a 仅含 QEMU 显式对象 + 入口对象（已 -force_load）；'
             'QEMU 工具库与 sysroot 依赖库为独立 .a，由 App 惰性链接'
             '（见 engine_libflags.txt）。需 -framework CoreFoundation/OpenGLES/'
             'IOSurface/CoreMedia 及 -lz -liconv'),
}
(out / 'ENGINE_MANIFEST.json').write_text(json.dumps(manifest, indent=2) + '\n')
PY

echo
echo "== 校验静态库 =="
lipo -info "$OUT/libqemu-arm.a" || true
ar -t "$OUT/libqemu-arm.a" | wc -l | xargs echo "  成员数："
test -s "$OUT/libqemu-arm.a" || { echo "ERROR: libqemu-arm.a 为空" >&2; exit 1; }

echo
echo "== 打包便于 Release 下载 =="
( cd "$OUT" && tar czf qemu-engine.tar.gz --exclude='SHA256SUMS' . )
( cd "$OUT" && shasum -a 256 libqemu-arm.a qemu-engine.tar.gz > SHA256SUMS )
cat "$OUT/SHA256SUMS"
echo "OK: 引擎产物已生成"
