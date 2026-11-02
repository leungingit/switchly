#!/usr/bin/env python3
"""校验外仓固定制品并准备 Xcode 资源；不联网、不执行插件或外部脚本。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def inventory(directory):
    result = {}
    total = 0
    for file in sorted(directory.rglob('*')):
        if file.is_symlink():
            raise ValueError('插件包禁止符号链接')
        if file.is_dir():
            continue
        if not file.is_file():
            raise ValueError('插件包包含特殊文件')
        total += file.stat().st_size
        if total > 32 * 1024 * 1024 or len(result) >= 1024:
            raise ValueError('插件包超过预算')
        result[file.relative_to(directory).as_posix()] = hashlib.sha256(file.read_bytes()).hexdigest()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(os.environ.get('SWITCHLY_PLUGIN_SOURCE', ROOT.parent / 'switchly-plugins' / 'dist' / 'Plugins')))
    parser.add_argument('--output', type=Path, default=ROOT / '.build' / 'Plugins')
    parser.add_argument('--empty', action='store_true', help='仅供明确的无预装开发验证')
    args = parser.parse_args()
    lock = json.loads((ROOT / 'distribution' / 'bundled-plugins.lock.json').read_text())
    selected = [] if args.empty else lock['plugins']
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='switchly-plugins-') as temporary:
        staged = Path(temporary) / 'Plugins'
        staged.mkdir()
        for item in selected:
            plugin_id = item['id']
            if '/' in plugin_id or plugin_id.startswith('.') or '\\' in plugin_id:
                raise ValueError('锁文件包含非法插件 ID')
            source = args.source / plugin_id
            if source.is_symlink() or not source.is_dir():
                raise ValueError('缺少外仓制品；先在 switchly-plugins 执行 npm run build，或指定 SWITCHLY_PLUGIN_SOURCE')
            if inventory(source) != item['files']:
                raise ValueError('外仓制品与锁文件不符：' + plugin_id)
            manifest = json.loads((source / 'manifest.json').read_text())
            if manifest['id'] != plugin_id or manifest['version'] != item['version']:
                raise ValueError('制品身份或版本不符')
            shutil.copytree(source, staged / plugin_id)
            if inventory(staged / plugin_id) != item['files']:
                raise ValueError('复制过程中制品发生变化')
        # 目标只接受本任务的生成目录，防止误删任意路径。
        output = args.output.resolve()
        temporary_root = Path(tempfile.gettempdir()).resolve()
        default_output = ROOT / '.build' / 'Plugins'
        in_temporary = output != temporary_root and temporary_root in output.parents
        if output != default_output and not in_temporary:
            raise ValueError('生成目录必须是 .build/Plugins 或系统临时目录下的任务子目录')
        if output == args.source.resolve() or output in args.source.resolve().parents:
            raise ValueError('生成目录不能覆盖制品来源')
        if args.output.is_symlink():
            raise ValueError('生成目录不能是符号链接')
        if args.output.exists():
            shutil.rmtree(args.output)
        shutil.copytree(staged, args.output)
    print('预装制品校验通过：' + str(len(selected)) + ' 个插件')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit('插件准备失败：' + str(error))
