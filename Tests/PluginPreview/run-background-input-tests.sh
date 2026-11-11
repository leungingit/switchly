#!/bin/bash
# 正式后台入口：独立观察、真实 AX／视图鼠标事件、动作后画面、失败传播与临时目录回收。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
APP="$ROOT/DerivedData/PluginPreview/Build/Products/Debug/SwitchlyPluginPreview.app"
FIXTURE="$ROOT/Tests/PluginPreview/Fixtures/native-input"
PLUGINS_REPO="${1:-$ROOT/../switchly-plugins}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/switchly-background-input.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library "$ROOT/Tests/PluginPreview/BackgroundInputProbe.swift" -o "$WORK/probe"
mkdir "$WORK/private-tmp"
python3 -I - "$FIXTURE" "$WORK" "$PLUGINS_REPO" <<'PY'
import json, pathlib, shutil, sys
fixture, work, plugins = map(pathlib.Path, sys.argv[1:])
base = json.loads((fixture / 'scenario.json').read_text())
cases = {
    'positive': base['steps'],
    'initial': [],
    'go': [{'type':'nativeClick','label':'Go','expectAction':'go'}],
    'disabled': [{'type':'nativeClick','label':'Stop'}],
    'not-disabled': [{'type':'nativeClick','label':'Go','expectDisabled':True}],
    'missing': [{'type':'nativeClick','label':'Absent'}],
    'wrong-action': [{'type':'nativeClick','label':'Go','expectAction':'stop'}],
    'out-of-bounds': [{'type':'nativeClickAt','point':{'x':99999,'y':0}}],
    'unsupported-target': [{'type':'nativeClickAt','point':{'x':10,'y':10}}],
    'worker-error': [{'type':'nativeClick','label':'Go','expectAction':'go'}, {'type':'expectText','contains':'last:go'}],
    'cancel': [{'type':'nativeClick','label':'Go','expectAction':'go'}] * 64,
    'grow': [{'type':'nativeClick','label':'Go','expectAction':'go'}],
}
for name, steps in cases.items():
    (work / (name + '.json')).write_text(json.dumps(dict(base, id=name, steps=steps)))
(work / 'oversized.json').write_text(json.dumps(dict(base, id='oversized', steps=[],
    environment=dict(base['environment'], contentWidthPoints=1000000))))
shutil.copytree(fixture / 'plugin', work / 'throws-plugin')
js = work / 'throws-plugin/main.js'
js.write_text(js.read_text().replace('last = id;', 'throw new Error("synthetic failure");'))
shutil.copytree(fixture / 'plugin', work / 'grows-plugin')
js = work / 'grows-plugin/main.js'
extra = json.dumps([{'type':'text','value':'expanded'}] * 8)
js.write_text(js.read_text().replace('    ] } }];', '    ].concat(last === "go" ? ' + extra + ' : []) } }];'))
media = plugins / 'preview/scenarios/music/fixtures/media-playing.json'
if media.exists() and (plugins / 'plugins/com.switchly.music-controls').is_dir():
    shutil.copy(media, work / 'media.json')
    scene = dict(base, id='scene3d', grants=['media.nowPlaying','media.control','media.library'],
        settings={'ipod3d':True}, fixtures={'media':'media.json'}, steps=[])
    scene['environment'] = dict(base['environment'], contentWidthPoints=300)
    for name, steps in {
        '3d-initial': [],
        '3d-click': [{'type':'nativeClickAt','point':{'x':150,'y':389},'expectAction':'toggle'}],
        '3d-love': [{'type':'nativeClickAt','point':{'x':150,'y':276},'expectAction':'love'}],
        '3d-drag': [{'type':'nativeDrag','from':{'x':150,'y':100},'to':{'x':190,'y':120}}],
    }.items():
        (work / (name + '.json')).write_text(json.dumps(dict(scene, id=name, steps=steps)))
PY
run_case() {
  local name="$1" plugin="$2" expected_exit="$3" status="$4" detail="$5" code=0
  TMPDIR="$WORK/private-tmp" "$WORK/probe" "$WORK/$name-observer.json" "$WORK/$name-result.json" \
    "$APP/Contents/MacOS/SwitchlyPluginPreview" run "$plugin" --scenario "$WORK/$name.json" \
    --out "$WORK/$name" --background --json || code=$?
  if [ "$code" -eq 4 ] && [ "$expected_exit" -ne 4 ]; then cat "$WORK/$name-result.json" >&2; echo "环境不可用，未通过后台验收" >&2; exit 77; fi
  python3 -I - "$WORK" "$name" "$code" "$expected_exit" "$status" "$detail" <<'PY'
import json, pathlib, sys
work, name = pathlib.Path(sys.argv[1]), sys.argv[2]
r = json.loads((work / (name + '-result.json')).read_text())
o = json.loads((work / (name + '-observer.json')).read_text())
assert sys.argv[3] == sys.argv[4], (name, sys.argv[3:], r, o)
assert r['status'] == sys.argv[5], (name, r)
assert o['onScreenSamples'] == o['activeSamples'] == o['activationEvents'] == 0, o
if sys.argv[6] != '-':
    if r['status'] == 'environment-error':
        assert r['error']['code'] == sys.argv[6], r
    else:
        assert r['steps'][0]['detail'] == sys.argv[6], r
        assert all(s['status'] == 'skipped' for s in r['steps'][1:]), r
if r['status'] == 'passed':
    assert all(s['status'] == 'passed' for s in r.get('steps', [])), r
    assert (work / name / 'preview.png').stat().st_size > 0
else:
    assert not (work / name / 'preview.png').exists()
assert not list((work / 'private-tmp').iterdir()), '预览临时文件残留'
print('PASS', name, 'samples='+str(o['samples']), 'visible=0 active=0 activations=0',
      'foregroundChanges='+str(o['foregroundChangedSamples']))
PY
}
run_case initial "$FIXTURE/plugin" 0 passed -
run_case go "$FIXTURE/plugin" 0 passed -
run_case positive "$FIXTURE/plugin" 0 passed -
run_case disabled "$FIXTURE/plugin" 1 failed element-disabled
run_case not-disabled "$FIXTURE/plugin" 1 failed element-not-disabled
run_case missing "$FIXTURE/plugin" 1 failed element-not-found
run_case wrong-action "$FIXTURE/plugin" 1 failed wrong-action-routed
run_case out-of-bounds "$FIXTURE/plugin" 1 failed point-out-of-bounds
run_case unsupported-target "$FIXTURE/plugin" 1 failed pointer-target-unsupported
run_case worker-error "$WORK/throws-plugin" 1 failed step-error
run_case oversized "$FIXTURE/plugin" 4 environment-error background-surface-unavailable
run_case grow "$WORK/grows-plugin" 0 passed -
initial_height="$(sips -g pixelHeight "$WORK/initial/preview.png" | awk '/pixelHeight:/ {print $2}')"
grown_height="$(sips -g pixelHeight "$WORK/grow/preview.png" | awk '/pixelHeight:/ {print $2}')"
[ "$grown_height" -gt "$initial_height" ] || { echo 'FAIL 动作后表面没有增长'; exit 1; }
python3 -I - "$WORK" "$APP" "$FIXTURE/plugin" <<'PY'
import json, os, pathlib, signal, subprocess, sys, time
work, app, plugin = map(pathlib.Path, sys.argv[1:])
probe = subprocess.Popen([str(work/'probe'), str(work/'cancel-observer.json'), str(work/'cancel-result.json'),
    str(app/'Contents/MacOS/SwitchlyPluginPreview'), 'run', str(plugin), '--scenario', str(work/'cancel.json'),
    '--out', str(work/'cancel'), '--background', '--json'], env=dict(os.environ, TMPDIR=str(work/'private-tmp')))
try:
    time.sleep(1.5)
    children = subprocess.check_output(['pgrep','-P',str(probe.pid)], text=True).split()
    assert len(children) == 1, children
    pid = int(children[0])
    try: owned = subprocess.check_output(['pgrep','-P',str(pid)], text=True).split()
    except subprocess.CalledProcessError: owned = []
    os.kill(pid, signal.SIGTERM)
    code = probe.wait(timeout=10)
    observer = json.loads((work/'cancel-observer.json').read_text())
    assert code == 143, (code, observer, (work/'cancel-result.json').read_text())
    assert not list((work/'private-tmp').iterdir()), '信号退出后临时文件残留'
    for child in owned:
        try: os.kill(int(child), 0)
        except ProcessLookupError: continue
        raise AssertionError('已记录的子进程未回收')
    assert not (work/'cancel-result.json').read_text(), '信号退出不能重写正常步骤失败报告'
    print('PASS SIGTERM exit=143 samples='+str(observer['samples']),
          'visible=0 active=0 activations=0 temporary_entries=0 owned_children_reaped='+str(len(owned)))
finally:
    if probe.poll() is None:
        for child in subprocess.run(['pgrep','-P',str(probe.pid)], capture_output=True, text=True).stdout.split():
            try: os.kill(int(child), signal.SIGTERM)
            except ProcessLookupError: pass
        probe.wait(timeout=10)
PY
"$WORK/probe" --images-differ "$WORK/initial/preview.png" "$WORK/go/preview.png"
"$WORK/probe" --images-differ "$WORK/go/preview.png" "$WORK/positive/preview.png"
python3 -I - "$WORK" <<'PY'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
for name, expected in [('initial','last:none'),('go','last:go'),('positive','last:mute')]:
    assert expected in (work / name / 'ui-tree.json').read_text(), name
PY
if [ -f "$WORK/3d-initial.json" ]; then
  run_case 3d-initial "$PLUGINS_REPO/plugins/com.switchly.music-controls" 0 passed -
  # 这些坐标属于正视、wheel_ring 扇区版夹具，不能套用旧版倾斜独立网格资产。
  # 缺少匹配夹具是未验（77），不将截图成功或 2D 通过冒充 3D 输入通过。
  python3 -I - "$WORK/3d-initial/ui-tree.json" <<'PY'
import json, sys
tree = json.load(open(sys.argv[1]))
def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values(): yield from nodes(child)
    elif isinstance(value, list):
        for child in value: yield from nodes(child)
scenes = [n for n in nodes(tree) if n.get('type') == 'scene3d']
compatible = any(
    any(h.get('id') == 'toggle' and h.get('node') == 'wheel_ring' and h.get('sector') == 'bottom' for h in s.get('hits', []))
    and any(h.get('id') == 'love' and h.get('node') == 'wheel_ring' and h.get('sector') == 'top' for h in s.get('hits', []))
    for s in scenes)
if not compatible:
    print('NOT_TESTED iPod 坐标回归：需要 wheel_ring 扇区版外仓夹具；旧版资产仅截图通过。', file=sys.stderr)
    sys.exit(77)
PY
  for name in 3d-click 3d-love 3d-drag; do
    run_case "$name" "$PLUGINS_REPO/plugins/com.switchly.music-controls" 0 passed -
  done
  for name in 3d-click 3d-love 3d-drag; do
    "$WORK/probe" --images-differ "$WORK/3d-initial/preview.png" "$WORK/$name/preview.png"
  done
  python3 -I - "$WORK" <<'PY'
import json, pathlib, sys
work = pathlib.Path(sys.argv[1])
before = (work / '3d-initial/ui-tree.json').read_text()
after = (work / '3d-click/ui-tree.json').read_text()
assert before.count('pause.fill') == 2 and after.count('play.fill') == 2, '3D 原生 toggle 未更新 worker UI'
PY
else
  echo '未执行 3D：外仓 iPod 与合成媒体夹具缺失'
  exit 77
fi
echo 'SUMMARY background-input passed'
