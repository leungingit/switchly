"""发行版本回归：使用可丢弃 plist，不触碰正式构建或版本真源。"""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("bundle_version", Path(__file__).resolve().parents[1] / "Scripts/bundle-version.py")
version = importlib.util.module_from_spec(spec)
spec.loader.exec_module(version)


class BundleVersionTests(unittest.TestCase):
    def test_sync_and_incremental_version_changes(self):
        with tempfile.TemporaryDirectory() as temp:
            source, target = Path(temp) / "source.plist", Path(temp) / "app.plist"
            for fmt in (plistlib.FMT_XML, plistlib.FMT_BINARY):
                target.write_bytes(plistlib.dumps({"CFBundleIdentifier": "test.preview"}, fmt=fmt))
                for marketing, build in (("1.4.1", "1"), ("1.4.1", "2"), ("1.4.2", "1")):
                    source.write_bytes(plistlib.dumps(dict(zip(version.KEYS, (marketing, build)))))
                    version.process(source, target, sync=True)
                    version.process(source, target)
                    self.assertEqual(plistlib.loads(target.read_bytes())["CFBundleIdentifier"], "test.preview")

    def test_check_rejects_missing_or_mismatched_fields_without_writing(self):
        with tempfile.TemporaryDirectory() as temp:
            source, target = Path(temp) / "source.plist", Path(temp) / "app.plist"
            valid = dict(zip(version.KEYS, ("1.4.1", "1")))
            source.write_bytes(plistlib.dumps(valid))
            for key in version.KEYS:
                for value in (None, "9"):
                    actual = valid.copy()
                    actual.pop(key)
                    if value is not None:
                        actual[key] = value
                    raw = plistlib.dumps(actual)
                    target.write_bytes(raw)
                    with self.assertRaises(ValueError):
                        version.process(source, target)
                    self.assertEqual(target.read_bytes(), raw)

    def test_invalid_source_does_not_modify_target(self):
        with tempfile.TemporaryDirectory() as temp:
            source, target = Path(temp) / "source.plist", Path(temp) / "app.plist"
            raw = plistlib.dumps({"CFBundleIdentifier": "test.preview"})
            target.write_bytes(raw)
            for values in (("1.4", "1"), ("1.4.1", "0"), ("1.4.1", 1), (None, "1")):
                fields = {key: value for key, value in zip(version.KEYS, values) if value is not None}
                source.write_bytes(plistlib.dumps(fields))
                with self.assertRaises(ValueError):
                    version.process(source, target, sync=True)
                self.assertEqual(target.read_bytes(), raw)


if __name__ == "__main__":
    unittest.main()
