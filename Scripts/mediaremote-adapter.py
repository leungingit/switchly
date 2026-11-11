#!/usr/bin/env python3
"""校验／构建固定的宿主媒体依赖；完全离线，不接受或更新新 revision。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
VENDOR = ROOT / "Vendor/MediaRemoteAdapter"
REVISION = "0e82bf1c44ec39554fbfc402ec88a48c6ae2a0fd"
SOURCES = [
    "adapter/env.m", "adapter/get.m", "adapter/globals.m", "adapter/keys.m",
    "adapter/now_playing.m", "adapter/repeat.m", "adapter/seek.m", "adapter/send.m",
    "adapter/shuffle.m", "adapter/speed.m", "adapter/stream.m", "adapter/test.m",
    "private/MediaRemote.m", "utility/Debounce.m", "utility/helpers.m",
]


def verify(vendor=VENDOR):
    if vendor.is_symlink():
        raise ValueError("依赖根目录不允许符号链接")
    if {p.name for p in vendor.iterdir()} != {"upstream", "source.json", "README.md"}:
        raise ValueError("依赖目录存在未登记内容")
    if any(p.is_symlink() for p in vendor.rglob("*")):
        raise ValueError("依赖输入不允许符号链接")
    lock = json.loads((vendor / "source.json").read_text())
    if lock["revision"] != REVISION or lock["repository"] != "https://github.com/ungive/mediaremote-adapter":
        raise ValueError("依赖来源与固定 revision 不符")
    upstream = vendor / "upstream"
    actual = {p.relative_to(upstream).as_posix() for p in upstream.rglob("*") if p.is_file()}
    if actual != set(lock["files"]):
        raise ValueError("依赖文件清单不符（缺失或额外文件）")
    for name, expected in lock["files"].items():
        path = upstream / name
        if path.resolve().parent != upstream.resolve() and upstream.resolve() not in path.resolve().parents:
            raise ValueError("依赖文件路径越界")
        if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError(f"依赖哈希不符：{name}")
    print(f"MediaRemote 离线校验通过：{len(actual)} 个文件，revision={REVISION}")


def build(output):
    verify()
    output = output.resolve()
    framework_name = "MediaRemoteAdapter.framework"
    names = [framework_name, "mediaremote-adapter.pl", "LICENSE", "source.json"]
    output.mkdir(parents=True, exist_ok=True)
    if any((output / name).exists() for name in names):
        raise ValueError("输出已含依赖产物，请选择新的输出目录，避免覆盖既有签名或文件")
    upstream = VENDOR / "upstream"
    sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
    # 临时中间产物始终位于系统临时目录，不进入工作区。
    with tempfile.TemporaryDirectory(prefix="switchly-mediaremote-build-") as temp:
        framework = Path(temp) / framework_name
        version = framework / "Versions/A"
        (version / "Headers").mkdir(parents=True)
        (version / "Resources").mkdir()
        info = {"CFBundleExecutable": "MediaRemoteAdapter", "CFBundleIdentifier": "com.vandenbe.MediaRemoteAdapter",
                "CFBundleName": "MediaRemoteAdapter", "CFBundlePackageType": "FMWK",
                "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "0.1.0",
                "LSMinimumSystemVersion": "12.0"}
        (version / "Resources/Info.plist").write_bytes(plistlib.dumps(info))
        shutil.copy2(upstream / "include/MediaRemoteAdapter.h", version / "Headers")
        subprocess.run(["xcrun", "clang", "-dynamiclib", "-arch", "arm64", "-arch", "x86_64",
                        "-mmacosx-version-min=12.0", "-isysroot", sdk, "-fobjc-arc", "-O2",
                        "-fvisibility=default", "-I", str(upstream / "include"), "-I", str(upstream / "src"),
                        "-install_name", "@rpath/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter",
                        "-framework", "Foundation", "-framework", "AppKit", "-framework", "UniformTypeIdentifiers",
                        *[str(upstream / "src" / name) for name in SOURCES],
                        "-o", str(version / "MediaRemoteAdapter")], check=True)
        (framework / "Versions/Current").symlink_to("A")
        for name in ["MediaRemoteAdapter", "Headers", "Resources"]:
            (framework / name).symlink_to(f"Versions/Current/{name}")
        shutil.copytree(framework, output / framework_name, symlinks=True)
    shutil.copy2(upstream / "bin/mediaremote-adapter.pl", output)
    shutil.copy2(upstream / "LICENSE", output)
    shutil.copy2(VENDOR / "source.json", output)
    print(f"MediaRemote 离线构建完成：{output}")


def validate_app(app):
    if app.is_symlink() or not app.is_dir():
        raise ValueError("输入必须是实际宿主 App 目录")
    app = app.resolve()
    if any((app / name).is_symlink() for name in ["Contents", "Contents/Resources", "Contents/Resources/MediaRemoteAdapter"]):
        raise ValueError("候选资源路径不允许符号链接")
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    if info.get("CFBundleIdentifier") != "com.switchly.app" or info.get("CFBundleExecutable") != "Switchly":
        raise ValueError("只允许宿主 App；不得给 Preview 或 Worker 打包真实媒体依赖")
    if not (app / "Contents/MacOS/Switchly").is_file():
        raise ValueError("宿主可执行文件缺失")
    return app


def embed(app, signing_identity=None):
    """主 App 最终签名前使用；编译成功后才替换固定资源目录。"""
    app = validate_app(app)
    destination = app / "Contents/Resources/MediaRemoteAdapter"
    with tempfile.TemporaryDirectory(prefix="switchly-mediaremote-embed-") as temp:
        artifacts = Path(temp) / "MediaRemoteAdapter"
        build(artifacts)
        if signing_identity:
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", signing_identity,
                            "--timestamp=none", str(artifacts / "MediaRemoteAdapter.framework")], check=True)
        if destination.exists():
            shutil.rmtree(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(artifacts, destination, symlinks=True)
    print("MediaRemote 离线依赖已打包到宿主资源目录")


def stage(app, output):
    """生成需后续签名验收的候选副本；从不修改输入 App。"""
    output = output.absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("候选输出已存在，拒绝覆盖")
    app = app.resolve() if not app.is_symlink() else app
    if app == output.resolve() or app in output.resolve().parents:
        raise ValueError("候选输出不能位于输入 App 内")
    app = validate_app(app)
    verify()
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.copytree(app, output, symlinks=True)
        signature = output / "Contents/_CodeSignature"
        if signature.is_symlink():
            signature.unlink()
        elif signature.exists():
            shutil.rmtree(signature)
        embed(output)
        print(f"MediaRemote 候选 App 已生成（未签名验收）：{output}")
    except Exception:
        # 只清理本次新建且事前不存在的候选副本。
        if output.exists():
            shutil.rmtree(output)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["verify", "build", "stage", "embed"])
    parser.add_argument("--output", type=Path)
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    if args.command == "embed":
        if args.app is None:
            parser.error("embed 必须指定 --app")
        identity = os.environ.get("EXPANDED_CODE_SIGN_IDENTITY") if os.environ.get("CODE_SIGNING_ALLOWED") != "NO" else None
        embed(args.app, signing_identity=identity)
    elif args.command == "stage":
        if args.output is None or args.app is None:
            parser.error("stage 必须显式指定 --app 和 --output")
        stage(args.app, args.output)
    elif args.command == "build":
        if args.output is None:
            parser.error("build 必须显式指定 --output")
        build(args.output)
    else:
        verify()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        print(f"MediaRemote 依赖失败：{error}", file=sys.stderr)
        sys.exit(1)
