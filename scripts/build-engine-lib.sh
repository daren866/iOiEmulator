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
import json, pathlib, shlex, subprocess, sys, hashlib

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

# 2) 取 ninja 对 qemu-system-arm 的最后一条链接命令，展开 @rsp
link_text = ''
for target in ('qemu-system-arm', 'qemu-system-arm-unsigned'):
    r = subprocess.run(['ninja', '-t', 'commands', target], cwd=build,
                       text=True, capture_output=True)
    if r.returncode == 0 and r.stdout.strip():
        link_text = r.stdout.strip()
        break
if not link_text:
    raise RuntimeError('找不到 qemu-system-arm 的 ninja 链接命令')
lines = link_text.splitlines()
link = shlex.split(lines[-1])
expanded = []
for a in link:
    if a.startswith('@'):
        expanded += shlex.split((build / a[1:]).read_text())
    else:
        expanded.append(a)

# 3) 过滤掉可执行文件专属参数，保留 .o / .a / -l / -L / -framework
objs, archives = [], []
drop_next = False
for a in expanded:
    if drop_next:
        drop_next = False; continue
    if a == '-o':
        drop_next = True; continue
    if a.endswith('system_main.c.o'):
        continue  # 由 qemu-ios-entry.o 取代
    if a in ('-pie', '-Wl,-pie') or a.startswith('-Wl,--dynamic-list=') or a == '-shared':
        continue
    if a.endswith('.o'):
        objs.append(a)
    elif a.endswith('.a'):
        archives.append(a)

# 4) 合并 sysroot 中的依赖静态库
deps = sorted(str(p) for p in (prefix / 'lib').glob('*.a'))
inputs = extra_objs + objs + archives + deps
inputs = [i if pathlib.Path(i).is_absolute() else str(build / i) for i in inputs]
inputs = [i for i in inputs if pathlib.Path(i).is_file()]

print(f'  iOS 入口 objects : {len(extra_objs)}')
print(f'  QEMU objects     : {len(objs)}')
print(f'  链接 .a          : {len(archives)}')
print(f'  sysroot .a       : {len(deps)}')
print(f'  合计归档输入     : {len(inputs)}')

lib = out / 'libqemu-arm.a'
subprocess.run(['libtool', '-static', '-o', str(lib)] + inputs, check=True)
print(f'  -> {lib} ({lib.stat().st_size} bytes)')

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
    'archive_inputs': len(inputs),
    'note': '静态库；链接时需 -framework CoreFoundation/OpenGLES/IOSurface/CoreMedia/Cocoa 及 -lz -liconv',
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
( cd "$OUT" && tar czf qemu-engine.tar.gz libqemu-arm.a include/ ENGINE_MANIFEST.json )
( cd "$OUT" && shasum -a 256 libqemu-arm.a qemu-engine.tar.gz > SHA256SUMS )
cat "$OUT/SHA256SUMS"
echo "OK: 引擎产物已生成"
