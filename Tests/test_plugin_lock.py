"""预装锁文件制品摘要与离线准备流程回归。运行：python3 Tests/test_plugin_lock.py。"""
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
PREPARE = runpy.run_path(str(ROOT / 'Scripts' / 'prepare-plugins.py'))
inventory = PREPARE['inventory']
content_hash = PREPARE['content_hash']


class PluginLockTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='switchly-plugin-lock-test-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / 'Plugins').mkdir()
        (self.root / 'Scripts').mkdir()
        for name in ('prepare-plugins.py', 'update-plugin-lock.py'):
            shutil.copy2(ROOT / 'Scripts' / name, self.root / 'Scripts' / name)
        self.source = self.root / 'source' / 'Plugins'
        self.plugin = self.source / 'com.example.test'
        self.plugin.mkdir(parents=True)
        self.manifest = {'id': self.plugin.name, 'version': '1.0.0', 'apiVersion': 2}
        (self.plugin / 'manifest.json').write_text(json.dumps(self.manifest))
        (self.plugin / 'main.js').write_text('original')
        self.lock = {'schemaVersion': 2, 'repository': 'example/plugins', 'sourceRevision': 'a' * 40,
                     'plugins': [dict(self.manifest, contentHash=content_hash(inventory(self.plugin)))]}
        self.write_lock()
        self.output = self.root / 'output'
        self.output.mkdir()
        (self.output / 'previous').write_text('保留旧制品')

    def write_lock(self):
        (self.root / 'Plugins' / 'bundled-plugins.lock.json').write_text(json.dumps(self.lock))

    def prepare(self):
        return subprocess.run([sys.executable, str(self.root / 'Scripts' / 'prepare-plugins.py'),
                               '--source', str(self.source), '--output', str(self.output)],
                              capture_output=True, text=True)

    def assert_rejected(self, message):
        result = self.prepare()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertEqual((self.output / 'previous').read_text(), '保留旧制品')

    def test_digest_is_deterministic_and_unambiguous(self):
        # 固定摘要向量避免生成端与校验端同时改变算法却互相通过。
        self.assertEqual(content_hash({}),
                         'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a')
        self.assertEqual(content_hash({'b': '2', 'a': '1'}), content_hash({'a': '1', 'b': '2'}))
        self.assertNotEqual(content_hash({'a\nb': '1'}), content_hash({'a': '1', 'b': '1'}))
        self.assertNotEqual(content_hash({'中文': '1'}), content_hash({'中文': '2'}))

    def test_prepare_copies_locked_content_without_updating_lock(self):
        before = (self.root / 'Plugins' / 'bundled-plugins.lock.json').read_bytes()
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(inventory(self.output / self.plugin.name), inventory(self.plugin))
        self.assertFalse((self.output / 'previous').exists())
        self.assertEqual((self.root / 'Plugins' / 'bundled-plugins.lock.json').read_bytes(), before)

    def test_content_changes_are_rejected(self):
        (self.plugin / 'main.js').write_text('tampered')
        self.assert_rejected('外仓制品与锁文件不符')

    def test_added_files_are_rejected(self):
        (self.plugin / 'extra.js').write_text('extra')
        self.assert_rejected('外仓制品与锁文件不符')

    def test_deleted_files_are_rejected(self):
        (self.plugin / 'main.js').unlink()
        self.assert_rejected('外仓制品与锁文件不符')

    def test_renamed_files_are_rejected(self):
        (self.plugin / 'main.js').rename(self.plugin / 'renamed.js')
        self.assert_rejected('外仓制品与锁文件不符')

    def test_symlinks_are_rejected(self):
        (self.plugin / 'link.js').symlink_to('main.js')
        self.assert_rejected('插件包禁止符号链接')

    def test_special_files_are_rejected(self):
        os.mkfifo(self.plugin / 'pipe')
        self.assert_rejected('插件包包含特殊文件')

    def test_file_count_budget_is_preserved(self):
        for number in range(1022):
            (self.plugin / f'asset-{number}').touch()
        self.assertEqual(len(inventory(self.plugin)), 1024)
        (self.plugin / 'one-too-many').touch()
        self.assert_rejected('插件包超过预算')

    def test_byte_budget_is_preserved(self):
        with (self.plugin / 'oversized').open('wb') as file:
            file.truncate(32 * 1024 * 1024 + 1)
        self.assert_rejected('插件包超过预算')

    def test_old_schema_is_rejected(self):
        self.lock['schemaVersion'] = 1
        self.write_lock()
        self.assert_rejected('不支持的插件锁文件版本')

    def test_changes_during_copy_are_rejected(self):
        copytree = shutil.copytree

        def changed_copy(source, destination, *args, **kwargs):
            result = copytree(source, destination, *args, **kwargs)
            (Path(destination) / 'main.js').write_text('changed while copying')
            return result

        arguments = ['prepare-plugins.py', '--source', str(self.source), '--output', str(self.output)]
        with patch.dict(PREPARE['main'].__globals__, ROOT=self.root), patch.object(sys, 'argv', arguments):
            with patch.object(shutil, 'copytree', side_effect=changed_copy):
                with self.assertRaisesRegex(ValueError, '复制过程中制品发生变化'):
                    PREPARE['main']()
        self.assertEqual((self.output / 'previous').read_text(), '保留旧制品')

    def test_update_generates_v2_lock_and_prepare_accepts_it(self):
        result = subprocess.run([sys.executable, str(self.root / 'Scripts' / 'update-plugin-lock.py'),
                                 '--source', str(self.source)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        lock = json.loads((self.root / 'Plugins' / 'bundled-plugins.lock.json').read_text())
        self.assertEqual(lock['schemaVersion'], 2)
        self.assertIsNone(lock['sourceRevision'])
        self.assertEqual(lock['plugins'], [dict(self.manifest, contentHash=content_hash(inventory(self.plugin)))])
        self.assertNotIn('files', lock['plugins'][0])
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main(verbosity=2)
