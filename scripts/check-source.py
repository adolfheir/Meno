#!/usr/bin/env python3
"""Fast checks which do not build, launch apps, or change user data."""
import ast
import json
import pathlib
import plistlib
import re

root = pathlib.Path(__file__).resolve().parent.parent
for path in (root / "scripts").rglob("*.py"):
    ast.parse(path.read_text(), filename=str(path))
info = plistlib.loads((root / "apps/Meno/Info.plist").read_bytes())
version = info["CFBundleShortVersionString"]
assert re.fullmatch(r"\d+\.\d+\.\d+", version), "Invalid bundle version"
assert info["LSUIElement"] is True
assert info["CFBundleIdentifier"] == "com.meno.app"
for file in ("apps/MenoMCP/Sources/MenoMCP.swift", "packages/MenoCLIKit/Sources/MenoCLIKit/CLIParser.swift"):
    assert f'"{version}"' in (root / file).read_text(), f"Version mismatch: {file}"
pins = json.loads((root / "Package.resolved").read_text())["pins"]
assert len({pin["identity"] for pin in pins}) == len(pins), "Duplicate dependency"
for pin in pins:
    assert re.fullmatch(r"[a-f0-9]{40}", pin["state"]["revision"]), pin["identity"]
sdk = next(pin for pin in pins if pin["identity"] == "swift-sdk")
assert f'exact: "{sdk["state"]["version"]}"' in (root / "Package.swift").read_text()
print(f"Source checks passed; Meno {version}, {len(pins)} locked Swift dependencies.")
