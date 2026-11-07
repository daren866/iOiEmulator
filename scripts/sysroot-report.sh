#!/usr/bin/env bash
# 引擎 ② 报告：汇总逐包构建结果，写 JSON + Actions Step Summary。
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="${WORK:-$ROOT/.engine-work}"
STATUS="$WORK/sysroot/status"
REPORT="$WORK/sysroot-report.json"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

python3 - "$STATUS" "$REPORT" "$WORK/sysroot/prefix" <<'PY'
import json, pathlib, sys
status = pathlib.Path(sys.argv[1]); report = pathlib.Path(sys.argv[2]); prefix = pathlib.Path(sys.argv[3])
items = []
for p in sorted(status.glob('*.json')) if status.exists() else []:
    try: items.append(json.loads(p.read_text()))
    except Exception: pass
libs = sorted(str(x) for x in prefix.glob('lib/*.a')) if prefix.exists() else []
pcs  = sorted(str(x.name) for x in prefix.glob('lib/pkgconfig/*.pc')) if prefix.exists() else []
out = {
    'stage': 'ios-sysroot',
    'total': len(items),
    'ok': sum(1 for i in items if i.get('ok')),
    'failed': [i['name'] for i in items if not i.get('ok')],
    'packages': items,
    'static_libraries': libs,
    'pkgconfig_files': pcs,
}
report.write_text(json.dumps(out, indent=2, ensure_ascii=False) + '\n')
PY

echo "== 依赖构建摘要 ==" | tee -a "$SUMMARY"
python3 - "$REPORT" <<'PY' | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
import json,sys
d=json.load(open(sys.argv[1]))
print(f"  成功 {d['ok']}/{d['total']}；失败：{', '.join(d['failed']) or '无'}")
print(f"  静态库 {len(d['static_libraries'])} 个，.pc {len(d['pkgconfig_files'])} 个")
print()
print('  | 包 | 结果 | 阶段 | 耗时 |')
print('  | --- | --- | --- | --- |')
for p in d['packages']:
    print(f"  | {p['name']} | {'✅' if p['ok'] else '❌'} | {p['stage']} | {p['seconds']}s |")
PY
echo
echo "  报告：$REPORT"
if [ -f "$REPORT" ]; then
  FAILED=$(python3 -c "import json;print(len(json.load(open('$REPORT'))['failed']))")
  if [ "$FAILED" != "0" ]; then
    echo "::warning::有 $FAILED 个依赖未编成；QEMU configure 大概率会在 glib 探测处失败，详见各 status/*.log"
  fi
fi
