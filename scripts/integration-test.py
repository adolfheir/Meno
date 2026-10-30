#!/usr/bin/env python3
"""Run real MCP/CLI against a separately identified App with disposable private data."""
import argparse
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time


def run(options):
    root = pathlib.Path(__file__).resolve().parent.parent
    source = pathlib.Path(options.app).resolve()
    output = pathlib.Path(options.output).resolve()
    output.mkdir(parents=True, exist_ok=True)
    work = pathlib.Path(tempfile.mkdtemp(prefix="meno-it-", dir="/tmp")).resolve()
    app = work / "Meno.app"
    data = work / "data"
    data.mkdir(mode=0o700)
    env = dict(os.environ, MENO_APP_PATH=str(app), MENO_DATA_DIR=str(data))
    cli = app / "Contents/Helpers/meno"
    checks = []
    stopped = False
    try:
        subprocess.run(["ditto", str(source), str(app)], check=True)
        plist = app / "Contents/Info.plist"
        info = plistlib.loads(plist.read_bytes())
        info["CFBundleIdentifier"] = "com.meno.integration." + work.name
        info["CFBundleDisplayName"] = "Meno Integration Test"
        plist.write_bytes(plistlib.dumps(info))
        # Separate notification namespace and LaunchServices identity, even if the user's App is running.
        subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
        # A fresh integration instance must not contend for the user's global hotkey.
        (data / "preferences.json").write_text(json.dumps({"schemaVersion": 1, "enabledPlugins": [], "hotkeyEnabled": False}))
        os.chmod(data / "preferences.json", 0o600)
        for name, extra in [("mcp-smoke", ["--discover-only"]), ("mcp-smoke", []), ("schedule-smoke", []), ("retry-smoke", []), ("runtime-smoke", [])]:
            label = "mcp-discovery" if extra else name
            command = [sys.executable, str(root / "scripts" / (name + ".py")), "--app", str(app), "--output", str(output / (label + ".json")), *extra]
            with (output / (label + ".log")).open("w") as log:
                subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
            if extra:
                assert not (data / "control.sock").exists(), "Discovery unexpectedly launched host"
            checks.append(label)
            print(f"PASS {label}", flush=True)
        # SIGTERM must take the same normal stop path and preserve enabled preference.
        subprocess.run([str(cli), "apps", "enable"], env=env, check=True, capture_output=True)
        import signal
        for _ in range(3):
            pid = host_pid(app)
            assert pid is not None, "Host PID missing"
            os.kill(pid, signal.SIGTERM)
            wait_for_exit(app)
            assert not (data / "control.sock").exists()
            result = subprocess.run([str(cli), "apps", "status"], env=env, text=True, capture_output=True, check=True, timeout=35)
            assert json.loads(result.stdout)["running"] is True
        checks.append("sigterm-and-restart")
        print("PASS sigterm-and-restart (3 cycles)", flush=True)
    except subprocess.CalledProcessError as error:
        # Captured CLI failures must survive cleanup of the isolated test App.
        print(f"FAIL command: {error.cmd}; exit={error.returncode}", file=sys.stderr)
        if error.stdout:
            print(error.stdout, file=sys.stderr)
        if error.stderr:
            print(error.stderr, file=sys.stderr)
        raise
    finally:
        if cli.exists():
            subprocess.run([str(cli), "quit", "--no-launch"], env=env, capture_output=True, timeout=35)
            try:
                wait_for_exit(app)
                stopped = True
            except AssertionError:
                print(f"Test host still running; preserving {work}", file=sys.stderr)
        (output / "summary.json").write_text(json.dumps({"checks": checks, "passed": len(checks) == 6 and stopped, "isolatedBundle": True, "hostStopped": stopped}, indent=2) + "\n")
        if stopped:
            shutil.rmtree(work)
        if not stopped:
            raise RuntimeError("Integration host did not stop normally; inspect preserved test directory")


def host_pid(app):
    result = subprocess.run(["ps", "-axo", "pid=,command="], text=True, capture_output=True, check=True)
    executable = str(app / "Contents/MacOS/Meno")
    for line in result.stdout.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and (parts[1] == executable or parts[1].startswith(executable + " ")):
            return int(parts[0])
    return None


def wait_for_exit(app):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if host_pid(app) is None:
            return
        time.sleep(0.1)
    raise AssertionError("Host did not finish normal exit within 10 seconds")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", default="dist/Meno.app")
    parser.add_argument("--output", default="test-results/integration")
    run(parser.parse_args())
