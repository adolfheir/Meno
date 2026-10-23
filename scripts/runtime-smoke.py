#!/usr/bin/env python3
"""Exercise the packaged host through its real CLI. No database writes or mocks."""
import argparse
import json
import os
import pathlib
import re
import subprocess
import time
import uuid
from datetime import datetime, timezone

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', default='dist/Meno.app')
parser.add_argument('--output')
options = parser.parse_args()
app = pathlib.Path(options.app).resolve()
cli = app / 'Contents/Helpers/meno'
env = dict(os.environ, MENO_APP_PATH=str(app))
prefix = 'runtime-' + uuid.uuid4().hex
events = []

def record(name, value):
    events.append(dict(at=datetime.now(timezone.utc).isoformat(), check=name, result=value))

def call(*arguments, ok=True):
    result = subprocess.run([str(cli), *arguments, '--json'], env=env, text=True, capture_output=True, timeout=35)
    if ok:
        assert result.returncode == 0, result.stderr
        return json.loads(result.stdout)
    return result

def raw(command, args):
    return call('call', command, '--arguments', json.dumps(args))

initial = call('apps', 'status')
created = []
try:
    call('apps', 'disable', '--request-id', prefix + '-disable')
    paused = call('reminders', 'add', '--title', '[验收] 停用期间错过不补弹', '--in', '1s', '--type', 'fullscreen', '--request-id', prefix + '-paused')
    created.append(paused['id'])
    assert paused['saved'] and not paused['armed']
    time.sleep(1.5)
    assert call('diagnostics')['overlayScreenCount'] == 0
    enabled = call('apps', 'enable', '--request-id', prefix + '-enable')
    assert enabled['running'] and enabled['overlayScreenCount'] == 0
    history = call('reminders', 'history')['items']
    assert any(item['reminderID'] == paused['id'] and item['state'] == 'missed' for item in history)
    record('disabled_save_and_missed_without_catch_up', dict(saved=paused['saved'], armed=paused['armed'], overlays=enabled['overlayScreenCount']))

    future = call('reminders', 'add', '--title', '[验收] 未来全屏计划', '--in', '1h', '--type', 'fullscreen', '--request-id', prefix + '-future')
    created.append(future['id']); assert future['armed']
    system = call('reminders', 'add', '--title', '[验收] 系统通知条件', '--in', '1h', '--type', 'system', '--request-id', prefix + '-system')
    created.append(system['id'])
    record('type_specific_armed_conditions', dict(fullscreen=future['armed'], system=system['armed'], systemReason=system['blockedReason']))
    changed = call('reminders', 'update', future['id'], '--type', 'system', '--in', '2h', '--request-id', prefix + '-edit')
    assert changed['current']['reminderType'] == 'system'
    paused_item = call('reminders', 'update', future['id'], '--enabled', 'false', '--request-id', prefix + '-pause-item')
    assert not paused_item['armed'] and paused_item['current']['isEnabled'] is False
    record('edit_type_time_and_pause', dict(id=future['id'], armed=paused_item['armed']))

    invalid = call('reminders', 'add', '--title', '非法互斥参数', '--in', '1h', '--daily', '15:00', ok=False)
    assert invalid.returncode != 0 and json.loads(invalid.stderr)['error']['code'] == 'invalid_schedule'
    record('cli_invalid_input_nonzero', invalid.returncode)

    before = call('diagnostics')
    call('quit')
    deadline = time.monotonic() + 6
    pattern = '^' + re.escape(str(app / 'Contents/MacOS/Meno'))
    while time.monotonic() < deadline:
        if subprocess.run(['pgrep', '-f', pattern], capture_output=True).returncode != 0:
            break
        time.sleep(0.1)
    else:
        raise AssertionError('Host did not finish its normal quit within 6 seconds')
    assert call('apps', 'status', '--no-launch', ok=False).returncode != 0
    restarted = call('apps', 'status')
    assert restarted['running'] == before['running'] and restarted['overlayScreenCount'] == 0
    record('normal_quit_process_exit_and_auto_start_restores_preference', dict(before=before['running'], after=restarted['running']))
finally:
    for item in created:
        call('reminders', 'cancel', item, '--request-id', prefix + '-cleanup-' + item)
    call('apps', 'enable' if initial['enabled'] else 'disable', '--request-id', prefix + '-restore')

text = json.dumps(events, ensure_ascii=False, indent=2) + '\n'
if options.output:
    pathlib.Path(options.output).write_text(text)
print(text)
