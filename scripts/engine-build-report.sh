#!/usr/bin/env bash
# 引擎 ③ 报告：把 configure / 编译 / 依赖状态汇总成 Release 说明与 JSON。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$ROOT/.engine-work}"
MD="$WORK/build-report.md"
JS="$WORK/build-report.json"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
CONFIGURE_ONLY="${CONFIGURE_ONLY:-true}"

python3 - "$WORK" "$MD" "$JS" "$CONFIGURE_ONLY" <<'PY'
import json, pathlib, sys
work, md, js, configure_only = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), sys.argv[4]

def load(p, default):
    try: return json.loads(pathlib.Path(p).read_text())
    except Exception: return default

sysroot = load(work/'sysroot-report.json', {'total':0,'ok':0,'failed':[],'packages':[]})
manifest = load(work/'manifest.json', {})
engine = load(work/'engine-out/ENGINE_MANIFEST.json', None)
clog = work/'configure.log'
configure_ok = (work/'qemu-build/build.ninja').exists()
lib_exists = (work/'engine-out/libqemu-arm.a').exists()
tail = ''
if clog.exists():
    tail = '\n'.join(clog.read_text(errors='replace').splitlines()[-25:])

state = 'engine-linked' if lib_exists else ('configure-ok' if configure_ok else 'configure-failed')
data = {
    'stage': 'qemu-ios-cross-build',
    'state': state,
    'configure_only': configure_only.lower() == 'true',
    'configure_ok': configure_ok,
    'library_built': lib_exists,
    'sysroot_ok': sysroot.get('ok',0),
    'sysroot_total': sysroot.get('total',0),
    'sysroot_failed': sysroot.get('failed',[]),
    'ios_abi_symbols': manifest.get('host_ios_abi',{}).get('abi_symbols'),
    'has_eagl': manifest.get('host_ios_eagl'),
    'engine': engine,
}
js.write_text(json.dumps(data, indent=2, ensure_ascii=False) + '\n')

lines = [
    '## qemu-ios → iOS arm64 交叉编译报告',
    '',
    '| 项 | 值 |',
    '| --- | --- |',
    f'| 状态 | `{state}` |',
    f'| Runner | `macos-15` (Apple Silicon) |',
    f'| configure | {"✅ 通过" if configure_ok else "❌ 失败"} |',
    f'| 依赖 sysroot | {sysroot.get("ok",0)}/{sysroot.get("total",0)} 成功 |',
    f'| 引擎静态库 | {"✅ 已产出" if lib_exists else "未产出（configure_only 或编译失败）"} |',
    f'| TCG 后端 | TCI 解释器（无需 JIT） |',
    f'| iOS 嵌入 ABI | {manifest.get("host_ios_abi",{}).get("abi_symbols","?")} 个 `qemu_ios_*` 符号 |',
    f'| EAGL 后端 | {"源码包已自带" if manifest.get("host_ios_eagl") else "缺失"} |',
    '',
]
if sysroot.get('failed'):
    lines += ['### 未编成的依赖', ''] + [f'- `{n}` — 见 `ios-sysroot` artifact 内 `status/{n}.log`' for n in sysroot['failed']] + ['']
if not configure_ok and tail:
    lines += ['### configure 末段日志', '', '```', tail, '```', '']
lines += [
    '### 边界',
    '',
    '- 引擎为 GPL-2.0；链接后整体须开源，且**不可上架 App Store**（2.5.2 / 4.7、Apple 固件版权）。',
    '- 本产物不含任何 Apple 固件，NAND/NOR 需使用者自行制备。',
    '- 未经真机验证；iOS 侧 UIKit 控件层与 helper 单进程化仍需人工适配。',
    '- 完整流程见 `docs/PORTING.md` 与 `.github/workflows/engine-pipeline.yml`。',
    '',
]
md.write_text('\n'.join(lines))
PY

echo "== 引擎构建报告 ==" | tee -a "$SUMMARY"
python3 -c "import json;d=json.load(open('$JS'));print('  状态:',d['state'],'| configure:',d['configure_ok'],'| 依赖:',str(d['sysroot_ok'])+'/'+str(d['sysroot_total']),'| 库:',d['library_built'])" | tee -a "$SUMMARY"
cat "$MD" | tee -a "$SUMMARY"
