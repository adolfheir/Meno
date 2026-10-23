#!/usr/bin/env python3
import hashlib
import json
import pathlib
import platform
import plistlib
import subprocess
import sys
from datetime import datetime, timezone

app, configuration = pathlib.Path(sys.argv[1]), sys.argv[2]
root = pathlib.Path(__file__).resolve().parent.parent
sources = sorted(p for directory in ('apps', 'packages', 'plugins', 'scripts', '.github') for p in (root / directory).rglob('*') if p.is_file() and not {'.build', '__pycache__', '.swiftpm'}.intersection(p.parts) and p.suffix in ('.swift', '.plist', '.sh', '.py', '.h', '.modulemap', '.txt', '.yml', '.yaml'))
sources += [root / 'Package.swift', root / 'Package.resolved']
digest = hashlib.sha256()
for source in sources:
    digest.update(str(source.relative_to(root)).encode() + b'\0' + source.read_bytes())
revision = subprocess.run(['git', 'rev-parse', '--verify', 'HEAD'], cwd=root, capture_output=True, text=True)
status = subprocess.check_output(['git', 'status', '--porcelain'], cwd=root, text=True)
binaries = {name: hashlib.sha256((app / name).read_bytes()).hexdigest() for name in ('Contents/MacOS/Meno', 'Contents/Helpers/meno', 'Contents/Helpers/meno-mcp')}
result = dict(version=plistlib.loads((app / 'Contents/Info.plist').read_bytes())['CFBundleShortVersionString'], builtAt=datetime.now(timezone.utc).isoformat(), configuration=configuration,
              gitRevision=revision.stdout.strip() or None, gitDirty=bool(status.strip()), binaries=binaries,
              platform=platform.platform(), architecture=platform.machine(), sourceSHA256=digest.hexdigest(),
              swift=subprocess.check_output(['swift', '--version'], text=True).strip(),
              xcode=subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
              dependencies=json.loads((root / 'Package.resolved').read_text())['pins'],
              signing=subprocess.run(['codesign', '-dvv', str(app)], capture_output=True, text=True).stderr)
output = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else root / 'dist' / 'build-info.json'
output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
