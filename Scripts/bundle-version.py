#!/usr/bin/env python3
"""从主应用版本真源同步构建中 plist，或只读校验最终 App。"""
import argparse
from pathlib import Path
import plistlib
import re

SOURCE = Path(__file__).resolve().parent.parent / "Resources/Info.plist"
KEYS = ("CFBundleShortVersionString", "CFBundleVersion")


def process(source, target, sync=False):
    expected = plistlib.loads(source.read_bytes())
    for key, pattern in zip(KEYS, (r"[0-9]+\.[0-9]+\.[0-9]+", r"[1-9][0-9]*")):
        if not isinstance(expected.get(key), str) or not re.fullmatch(pattern, expected[key]):
            raise ValueError(f"版本真源的 {key} 缺失或无效")
    raw = target.read_bytes()
    actual = plistlib.loads(raw)
    if sync:
        actual.update({key: expected[key] for key in KEYS})
        fmt = plistlib.FMT_BINARY if raw.startswith(b"bplist00") else plistlib.FMT_XML
        target.write_bytes(plistlib.dumps(actual, fmt=fmt))
    for key in KEYS:
        if actual.get(key) != expected[key]:
            raise ValueError(f"{target}: {key}={actual.get(key)!r}，预期 {expected[key]!r}")
    print(f"版本校验通过：{target} = {expected[KEYS[0]]} (build {expected[KEYS[1]]})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sync", action="store_true", help="仅构建阶段、签名前同步；默认只读检查")
    parser.add_argument("plists", nargs="+", type=Path)
    args = parser.parse_args()
    try:
        for target in args.plists:
            process(SOURCE, target, args.sync)
    except (ValueError, OSError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"版本校验失败：{error}\n")
