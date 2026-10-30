#!/usr/bin/env python3
"""Exercise recurring schedules through installed MCP and CLI in an isolated App."""
import argparse
import asyncio
import json
import os
import pathlib
import subprocess
import uuid
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from jsonschema import Draft202012Validator
from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client


async def run(options):
    app = pathlib.Path(options.app).resolve()
    # This script deliberately refuses to write to the daily Meno data directory.
    data = pathlib.Path(os.environ.get("MENO_DATA_DIR", "/missing")).resolve()
    assert app.parent == data.parent and app.parent.name.startswith("meno-it-"), "Run via integration-test.py with isolated App/data"
    cli = app / "Contents/Helpers/meno"
    prefix = "schedule-" + uuid.uuid4().hex
    start = (datetime.now(timezone.utc) + timedelta(days=2)).replace(microsecond=0).isoformat()
    events, created = [], []
    parameters = StdioServerParameters(command=str(app / "Contents/Helpers/meno-mcp"), env=dict(os.environ, MENO_APP_PATH=str(app)))
    async with stdio_client(parameters) as streams:
        async with ClientSession(*streams) as session:
            await session.initialize()
            catalog = {t.name: t for t in (await session.list_tools()).tools}
            validator = Draft202012Validator(catalog["reminders_create"].inputSchema)

            async def call(name, args, error=False):
                response = await session.call_tool(name, args)
                value = response.structuredContent or json.loads(response.content[0].text)
                assert bool(response.isError) == error, value
                return value

            initial = await call("apps_get_status", {})
            try:
                await call("apps_set_enabled", {"enabled": False, "requestId": prefix + "-pause"})
                samples = [
                    {"kind": "weekly", "weekdays": [5, 6, 7], "times": ["10:55", "17:55"], "every": 2},
                    {"kind": "monthly", "monthDays": [1, 15, -1], "time": "09:00"},
                    {"kind": "monthly", "ordinal": -1, "weekday": 5, "time": "09:00"},
                    {"kind": "yearly", "month": 2, "monthDays": [29], "time": "09:00"},
                    {"kind": "yearly", "month": 11, "ordinal": 4, "weekday": 4, "time": "09:00"},
                    {"kind": "daily", "every": 3, "times": ["09:00", "18:00"]},
                    {"kind": "interval", "everySeconds": 7200},
                    {"kind": "weekdays", "time": "09:00"},
                ]
                for index, schedule in enumerate(samples):
                    args = {"title": "[隔离验收] 时间规则", "reminderType": "fullscreen", "schedule": dict(schedule, startAt=start, timeZone="Asia/Shanghai"), "requestId": prefix + str(index)}
                    validator.validate(args)
                    saved = await call("reminders_create", args)
                    created.append(saved["id"])
                    assert saved["saved"] and not saved["armed"] and saved["blockedReason"]
                    retry = await call("reminders_create", args)
                    assert retry["replayed"] and retry["id"] == saved["id"]
                    assert retry["reminder"]["schedule"] == saved["reminder"]["schedule"]
                    upcoming = datetime.fromisoformat(saved["nextTriggerAt"].replace("Z", "+00:00")).astimezone(ZoneInfo("Asia/Shanghai"))
                    if schedule["kind"] == "weekly":
                        assert upcoming.isoweekday() in (5, 6, 7) and upcoming.strftime("%H:%M") in ("10:55", "17:55")
                    if schedule["kind"] == "yearly" and schedule["month"] == 2:
                        assert (upcoming.month, upcoming.day) == (2, 29)
                    events.append({"kind": schedule["kind"], "nextTriggerAt": saved["nextTriggerAt"], "saved": True, "replayed": True})
                # Invalid definitions must fail both advertised schema and business validation.
                for index, schedule in enumerate([
                    {"kind": "weekly", "weekdays": [0], "time": "09:00"},
                    {"kind": "daily", "time": "09:00", "times": ["10:00"]},
                    {"kind": "monthly", "monthDays": [1], "ordinal": 1, "weekday": 1, "time": "09:00"},
                    {"kind": "interval", "everySeconds": 1},
                ]):
                    args = {"title": "[隔离验收] 拒绝非法时间", "schedule": schedule, "requestId": prefix + "-invalid-" + str(index)}
                    assert list(validator.iter_errors(args)), schedule
                    bad = await call("reminders_create", args, error=True)
                    assert bad["error"]["code"] == "invalid_schedule"
                command = [str(cli), "reminders", "add", "--title", "[隔离验收] CLI 周末", "--weekly", "5,6,7", "--times", "10:55,17:55", "--timezone", "Asia/Shanghai", "--start-at", start, "--type", "fullscreen", "--request-id", prefix + "-cli"]
                saved = json.loads(subprocess.run(command, text=True, capture_output=True, check=True, timeout=35).stdout)
                created.append(saved["id"])
                retried = json.loads(subprocess.run(command, text=True, capture_output=True, check=True, timeout=35).stdout)
                assert retried["replayed"] and retried["id"] == saved["id"]
                await call("apps_set_enabled", {"enabled": True, "requestId": prefix + "-enable"})
                page = await call("reminders_list", {"status": "active", "limit": 200})
                ours = [item for item in page["items"] if item["id"] in created]
                assert len(ours) == len(created) and all(item["armed"] and item["blockedReason"] is None for item in ours)
                changed = await call("reminders_update", {"id": saved["id"], "schedule": {"kind": "monthly", "ordinal": -1, "weekday": 5, "times": ["10:55", "17:55"], "startAt": start, "timeZone": "Asia/Shanghai"}, "requestId": prefix + "-update"})
                assert changed["saved"] and changed["armed"] and changed["current"]["schedule"]["rule"] == "monthly"
                events.append({"check": "schema_validation_cli_retry_all_rules_armed_and_update", "count": len(ours), "passed": True})
            finally:
                for item in created:
                    await call("reminders_cancel", {"id": item, "requestId": prefix + "-cancel-" + item})
                await call("apps_set_enabled", {"enabled": initial["enabled"], "requestId": prefix + "-restore"})
    return events


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True)
    parser.add_argument("--output", required=True)
    options = parser.parse_args()
    result = asyncio.run(run(options))
    pathlib.Path(options.output).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print("PASS advanced calendar schedules, schema, CLI/MCP, retries, update and cleanup")
