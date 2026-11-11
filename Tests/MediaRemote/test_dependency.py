"""固定依赖的完整性回归；只在系统临时目录修改副本。"""
import contextlib
import importlib.util
import io
import json
import plistlib
from unittest import mock
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("mediaremote_dependency", ROOT / "Scripts/mediaremote-adapter.py")
dependency = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dependency)


class DependencyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="switchly-mediaremote-integrity-")
        self.addCleanup(self.temp.cleanup)
        self.vendor = Path(self.temp.name) / "vendor"
        shutil.copytree(dependency.VENDOR, self.vendor)

    def verify(self):
        with contextlib.redirect_stdout(io.StringIO()):
            dependency.verify(self.vendor)

    def test_pinned_inputs_pass(self):
        self.verify()

    def test_modified_source_fails(self):
        path = self.vendor / "upstream/src/adapter/stream.m"
        path.write_bytes(path.read_bytes() + b"\n// changed\n")
        with self.assertRaisesRegex(ValueError, "哈希"):
            self.verify()

    def test_extra_and_missing_files_fail(self):
        path = self.vendor / "upstream/injected.m"
        path.write_text("unexpected")
        with self.assertRaisesRegex(ValueError, "清单"):
            self.verify()
        path.unlink()
        (self.vendor / "upstream/LICENSE").unlink()
        with self.assertRaisesRegex(ValueError, "清单"):
            self.verify()

    def test_extra_top_level_file_fails(self):
        (self.vendor / "injected").write_text("unexpected")
        with self.assertRaisesRegex(ValueError, "未登记"):
            self.verify()

    def test_changed_revision_fails(self):
        path = self.vendor / "source.json"
        lock = json.loads(path.read_text())
        lock["revision"] = "master"
        path.write_text(json.dumps(lock))
        with self.assertRaisesRegex(ValueError, "revision"):
            self.verify()

    def test_symlink_input_fails_even_when_bytes_match(self):
        path = self.vendor / "upstream/LICENSE"
        saved = Path(self.temp.name) / "license"
        shutil.move(path, saved)
        path.symlink_to(saved)
        with self.assertRaisesRegex(ValueError, "符号链接"):
            self.verify()


class CandidateStageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="switchly-mediaremote-stage-")
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / "Input.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/MacOS/Switchly").write_bytes(b"fixture")
        self.info = self.app / "Contents/Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.switchly.app", "CFBundleExecutable": "Switchly"}))
        self.output = Path(self.temp.name) / "Candidate.app"

    def test_preview_and_nested_output_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "输入 App 内"):
            dependency.stage(self.app, self.app / "nested.app")
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.switchly.preview", "CFBundleExecutable": "Switchly"}))
        with self.assertRaisesRegex(ValueError, "Preview"):
            dependency.stage(self.app, self.output)
        self.assertFalse(self.output.exists())

    def test_existing_output_is_preserved(self):
        self.output.mkdir()
        sentinel = self.output / "keep"
        sentinel.write_text("keep")
        with self.assertRaisesRegex(ValueError, "拒绝覆盖"):
            dependency.stage(self.app, self.output)
        self.assertEqual(sentinel.read_text(), "keep")

    def test_embed_rejects_preview_and_symlink_resources(self):
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.switchly.preview", "CFBundleExecutable": "Switchly"}))
        with self.assertRaisesRegex(ValueError, "Preview"):
            dependency.embed(self.app)
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.switchly.app", "CFBundleExecutable": "Switchly"}))
        outside = Path(self.temp.name) / "outside"
        outside.mkdir()
        (self.app / "Contents/Resources").symlink_to(outside)
        with self.assertRaisesRegex(ValueError, "符号链接"):
            dependency.embed(self.app)
        self.assertEqual(list(outside.iterdir()), [])

    def test_embed_build_failure_preserves_existing_dependency(self):
        target = self.app / "Contents/Resources/MediaRemoteAdapter"
        target.mkdir(parents=True)
        (target / "keep").write_text("original")
        with mock.patch.object(dependency, "build", side_effect=ValueError("fixture")):
            with self.assertRaisesRegex(ValueError, "fixture"):
                dependency.embed(self.app)
        self.assertEqual((target / "keep").read_text(), "original")

    def test_framework_signing_failure_preserves_existing_dependency(self):
        target = self.app / "Contents/Resources/MediaRemoteAdapter"
        target.mkdir(parents=True)
        (target / "keep").write_text("original")
        def fake_build(output):
            output.mkdir()
        with mock.patch.object(dependency, "build", side_effect=fake_build), mock.patch.object(
                dependency.subprocess, "run", side_effect=dependency.subprocess.CalledProcessError(1, "codesign")) as sign:
            with self.assertRaises(dependency.subprocess.CalledProcessError):
                dependency.embed(self.app, signing_identity="fixture-identity")
            self.assertEqual(sign.call_args.args[0][:4], ["/usr/bin/codesign", "--force", "--sign", "fixture-identity"])
        self.assertEqual((target / "keep").read_text(), "original")

    def test_stage_replaces_previously_bundled_dependency_without_changing_input(self):
        target = self.app / "Contents/Resources/MediaRemoteAdapter"
        target.mkdir(parents=True)
        (target / "old").write_text("original")
        def fake_build(output):
            output.mkdir()
            (output / "new").write_text("built")
        with mock.patch.object(dependency, "build", side_effect=fake_build), contextlib.redirect_stdout(io.StringIO()):
            dependency.stage(self.app, self.output)
        self.assertEqual((target / "old").read_text(), "original")
        self.assertEqual((self.output / "Contents/Resources/MediaRemoteAdapter/new").read_text(), "built")
        self.assertFalse((self.output / "Contents/Resources/MediaRemoteAdapter/old").exists())

    def test_failed_build_cleans_only_candidate_and_preserves_input_signature(self):
        signature = self.app / "Contents/_CodeSignature"
        signature.mkdir()
        (signature / "CodeResources").write_bytes(b"original")
        with mock.patch.object(dependency, "build", side_effect=ValueError("fixture build failure")):
            with contextlib.redirect_stdout(io.StringIO()), self.assertRaisesRegex(ValueError, "fixture"):
                dependency.stage(self.app, self.output)
        self.assertFalse(self.output.exists())
        self.assertEqual((signature / "CodeResources").read_bytes(), b"original")


if __name__ == "__main__":
    unittest.main()
