#!/usr/bin/env python3
"""Verify a packaged App, embedded helpers, licenses, and recorded binary digests."""
import argparse
import hashlib
import json
import pathlib
import plistlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("app", nargs="?", default="dist/Meno.app")
parser.add_argument("--manifest", default="dist/build-info.json")
args = parser.parse_args()
app = pathlib.Path(args.app)
manifest = json.loads(pathlib.Path(args.manifest).read_text())
info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
assert info["CFBundleShortVersionString"] == manifest["version"]
assert info["CFBundleExecutable"] == "Meno" and info["LSUIElement"]
for relative in ("Contents/MacOS/Meno", "Contents/Helpers/meno", "Contents/Helpers/meno-mcp"):
    path = app / relative
    assert path.is_file() and path.stat().st_mode & 0o111, relative
    assert hashlib.sha256(path.read_bytes()).hexdigest() == manifest["binaries"][relative], relative
    subprocess.run(["codesign", "--verify", "--strict", str(path)], check=True)
assert (app / "Contents/Resources/AppIcon.icns").stat().st_size > 0
assert list((app / "Contents/Resources/Licenses").glob("*")), "Dependency licenses missing"
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
version = subprocess.check_output([str(app / "Contents/Helpers/meno"), "--version"], text=True).strip()
assert version == manifest["version"]
print(f"Verified Meno {version}: signature, three binary hashes, version, icon, and licenses.")
