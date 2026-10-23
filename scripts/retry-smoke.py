#!/usr/bin/env python3
"""Real IPC response loss and two independent MCP client processes."""
import argparse
import asyncio
import json
import os
import pathlib
import socket
import subprocess
import time
import uuid
from datetime import datetime, timezone

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--app', default='dist/Meno.app')
parser.add_argument('--output')
options = parser.parse_args()
app = pathlib.Path(options.app).resolve()
cli = app / 'Contents/Helpers/meno'
environment = dict(os.environ, MENO_APP_PATH=str(app))
prefix = 'retry-' + uuid.uuid4().hex
events = []

def call(command, args):
    result = subprocess.run([str(cli), 'call', command, '--arguments', json.dumps(args)], env=environment, text=True, capture_output=True, timeout=35)
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)

def record(check, result):
    events.append(dict(at=datetime.now(timezone.utc).isoformat(), check=check, result=result))

status = call('apps_get_status', {})
data = pathlib.Path(os.environ.get('MENO_DATA_DIR', pathlib.Path.home() / 'Library/Application Support/Meno'))
arguments = dict(title='[验收] 响应丢失后安全重试', reminderType='fullscreen', schedule=dict(kind='delay', afterSeconds=3600), requestId=prefix + '-lost')
request = dict(version=1, id=uuid.uuid4().hex, command='reminders_create', arguments=arguments, source='cli')
with socket.socket(socket.AF_UNIX) as channel:
    channel.connect(str(data / 'control.sock'))
    channel.sendall(json.dumps(request).encode() + b'\n')
    # Deliberately close before reading a single response byte.
time.sleep(0.3)
first_retry = call('reminders_create', arguments)
assert first_retry['replayed'] and first_retry['saved']
time.sleep(0.3)
second_retry = call('reminders_create', arguments)
assert second_retry['id'] == first_retry['id']
assert second_retry['reminder']['schedule'] == first_retry['reminder']['schedule']
record('real_ipc_response_lost_then_same_id_retry', dict(id=first_retry['id'], replayed=True, originalTime=first_retry['reminder']['schedule']['date']))
call('reminders_cancel', dict(id=first_retry['id'], requestId=prefix + '-lost-cancel'))

async def client_create(arguments):
    params = StdioServerParameters(command=str(app / 'Contents/Helpers/meno-mcp'), env=environment)
    async with stdio_client(params) as streams:
        async with ClientSession(*streams) as client:
            await client.initialize()
            result = await client.call_tool('reminders_create', arguments)
            assert not result.isError
            return result.structuredContent or json.loads(result.content[0].text)

async def concurrent():
    args = dict(title='[验收] 两个 MCP 客户端并发重试', schedule=dict(kind='delay', afterSeconds=3600), reminderType='fullscreen', requestId=prefix + '-multi')
    a, b = await asyncio.gather(client_create(args), client_create(args))
    assert a['id'] == b['id'] and a['reminder']['schedule'] == b['reminder']['schedule']
    assert sorted([a['replayed'], b['replayed']]) == [False, True]
    record('two_independent_mcp_processes_one_transaction', dict(id=a['id'], replayed=[a['replayed'], b['replayed']]))
    call('reminders_cancel', dict(id=a['id'], requestId=prefix + '-multi-cancel'))

asyncio.run(concurrent())
text = json.dumps(events, ensure_ascii=False, indent=2) + '\n'
if options.output:
    pathlib.Path(options.output).write_text(text)
print(text)
