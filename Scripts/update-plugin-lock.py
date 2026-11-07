#!/usr/bin/env python3
"""显式更新预装策划清单；构建不会自动接受变化的插件制品。"""
import argparse
import json
from pathlib import Path
import runpy
import subprocess

ROOT = Path(__file__).resolve().parent.parent
inventory = runpy.run_path(str(ROOT / 'Scripts' / 'prepare-plugins.py'))['inventory']
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, default=ROOT.parent / 'switchly-plugins' / 'dist-v2' / 'Plugins')
parser.add_argument('--id', action='append', help='只预装指定 ID；可重复，不传则选择全部')
args = parser.parse_args()
items = []
for directory in sorted(args.source.iterdir()):
    if directory.is_symlink() or not directory.is_dir():
        raise SystemExit('制品根目录只能包含插件目录')
    manifest = json.loads((directory / 'manifest.json').read_text())
    if args.id and manifest['id'] not in args.id:
        continue
    if manifest['id'] != directory.name:
        raise SystemExit('插件 ID 与目录名不一致')
    items.append({'id': manifest['id'], 'version': manifest['version'], 'apiVersion': manifest['apiVersion'],
                  'files': inventory(directory)})
if args.id and set(args.id) != {item['id'] for item in items}:
    raise SystemExit('指定的预装插件不存在')
revision = None
source_repository = args.source.parent.parent
head = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=source_repository, capture_output=True, text=True)
dirty = subprocess.run(['git', 'status', '--porcelain'], cwd=source_repository, capture_output=True, text=True)
if head.returncode == 0 and dirty.returncode == 0 and not dirty.stdout.strip():
    revision = head.stdout.strip()
lock = {'schemaVersion': 1, 'repository': 'leungingit/switchly-plugins', 'sourceRevision': revision, 'plugins': items}
(ROOT / 'Plugins' / 'bundled-plugins.lock.json').write_text(json.dumps(lock, ensure_ascii=False, indent=2) + '\n')
print('已显式锁定 ' + str(len(items)) + ' 个预装插件；来源提交：' + (revision or '本地未提交，发布前需重新锁定'))
