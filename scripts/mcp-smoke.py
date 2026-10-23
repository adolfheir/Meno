#!/usr/bin/env python3
"""Real stdio MCP client. It only cancels IDs created by this run."""
import argparse
import asyncio
import json
import os
import pathlib
import uuid
from datetime import datetime, timezone

from jsonschema import Draft202012Validator
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def run(options):
    app = pathlib.Path(options.app).resolve()
    prefix = 'meno-accept-' + uuid.uuid4().hex
    events = []
    def record(name, value):
        events.append(dict(at=datetime.now(timezone.utc).isoformat(), check=name, result=value))
    parameters = StdioServerParameters(command=str(app / 'Contents/Helpers/meno-mcp'), env=dict(os.environ, MENO_APP_PATH=str(app)))
    async with stdio_client(parameters) as streams:
        async with ClientSession(*streams) as session:
            initialized = await session.initialize()
            record('initialize', dict(protocol=initialized.protocolVersion, server=initialized.serverInfo.model_dump()))
            tools = (await session.list_tools()).tools
            expected = {'reminders_create', 'reminders_list', 'reminders_update', 'reminders_cancel', 'apps_get_status', 'apps_set_enabled'}
            assert {tool.name for tool in tools} == expected
            for tool in tools:
                Draft202012Validator.check_schema(tool.inputSchema)
            record('discover_six_tools_and_validate_schemas', sorted(expected))
            if options.discover_only:
                return events

            async def call(name, arguments, expect_error=False):
                result = await session.call_tool(name, arguments)
                value = result.structuredContent or json.loads(result.content[0].text)
                assert bool(result.isError) == expect_error, (name, value)
                return value

            initial = await call('apps_get_status', {})
            created = []
            try:
                stopped = await call('apps_set_enabled', dict(enabled=False, requestId=prefix + '-off'))
                assert stopped['running'] is False
                for reminder_type in ('system', 'fullscreen'):
                    args = dict(title='[验收] MCP ' + reminder_type, reminderType=reminder_type,
                                schedule=dict(kind='delay', afterSeconds=3600), requestId=prefix + reminder_type)
                    first = await call('reminders_create', args)
                    created.append(first['id'])
                    assert first['saved'] is True and first['armed'] is False and first['reminderType'] == reminder_type
                    retried = await call('reminders_create', args)
                    assert retried['id'] == first['id'] and retried['reminder']['schedule'] == first['reminder']['schedule'] and retried['replayed']
                    conflict = await call('reminders_create', dict(args, title='不同参数'), expect_error=True)
                    assert conflict['error']['code'] == 'idempotency_conflict'
                    record('create_retry_conflict_' + reminder_type, dict(id=first['id'], saved=first['saved'], armed=first['armed']))
                changed = await call('reminders_update', dict(id=created[0], reminderType='fullscreen', note='部分修改保留时间', requestId=prefix + '-edit'))
                assert changed['current']['reminderType'] == 'fullscreen'
                page = await call('reminders_list', dict(reminderType='fullscreen', limit=1))
                assert len(page['items']) == 1
                record('update_and_paginated_query', dict(total=page['total'], nextOffset=page['nextOffset']))
                invalid = await call('reminders_create', dict(title='非法时间', schedule=dict(kind='delay', afterSeconds=0), requestId=prefix + '-bad'), expect_error=True)
                assert invalid['error']['code'] == 'invalid_schedule'
                record('business_error_isError', invalid)
                started = await call('apps_set_enabled', dict(enabled=True, requestId=prefix + '-on'))
                assert started['running'] is True
                replay = await call('reminders_create', dict(title='[验收] MCP fullscreen', reminderType='fullscreen', schedule=dict(kind='delay', afterSeconds=3600), requestId=prefix + 'fullscreen'))
                assert replay['armed'] is True and replay['replayed'] is True
                record('retry_refreshes_current_armed_state', dict(armed=replay['armed']))
                for item in created:
                    cancelled = await call('reminders_cancel', dict(id=item, requestId=prefix + '-cancel-' + item))
                    assert cancelled['saved'] is True and cancelled['armed'] is False
                record('cancel_preserves_history', dict(ids=list(created)))
                created.clear()
                if options.delivery:
                    delivery = await call('reminders_create', dict(title='[验收] MCP 退出后仍独立提醒', reminderType='fullscreen',
                        note='此提醒由真实 MCP 客户端创建；客户端将在触发前断开。', schedule=dict(kind='delay', afterSeconds=8),
                        enablePlugin=True, requestId=prefix + '-delivery'))
                    assert delivery['armed'] is True
                    record('client_disconnecting_before_delivery', delivery)
            finally:
                for item in created:
                    await call('reminders_cancel', dict(id=item, requestId=prefix + '-cleanup-' + item))
                if not options.delivery:
                    await call('apps_set_enabled', dict(enabled=initial['enabled'], requestId=prefix + '-restore'))
    record('stdio_client_closed', True)
    return events


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', default='dist/Meno.app')
    parser.add_argument('--discover-only', action='store_true')
    parser.add_argument('--delivery', action='store_true', help='Leave one fullscreen reminder due 8 seconds after the client disconnects.')
    parser.add_argument('--output')
    options = parser.parse_args()
    events = asyncio.run(run(options))
    text = json.dumps(events, ensure_ascii=False, indent=2) + '\n'
    if options.output:
        pathlib.Path(options.output).write_text(text)
    print(text)
