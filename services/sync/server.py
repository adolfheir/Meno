#!/usr/bin/env python3
"""Meno private, single-user reminder synchronization server."""

import argparse
import hmac
import ipaddress
import json
import os
import sqlite3
import ssl
import threading
import uuid
from contextlib import closing
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

MAX_BODY = 8 * 1024 * 1024
EMPTY = {"reminders": [], "actions": [], "clocks": {}}


def connect(path):
    db = sqlite3.connect(path, timeout=10, isolation_level=None)
    db.execute("PRAGMA foreign_keys=ON")
    return db


def initialize(path):
    with closing(connect(path)) as db:
        db.execute("PRAGMA journal_mode=WAL")
        db.executescript("""
            CREATE TABLE IF NOT EXISTS replica (
                singleton INTEGER PRIMARY KEY CHECK (singleton=1), id TEXT NOT NULL,
                version INTEGER NOT NULL, state TEXT NOT NULL
            );
        """)
        db.execute("INSERT OR IGNORE INTO replica VALUES (1, ?, 0, ?)", (str(uuid.uuid4()), encode(EMPTY)))


def validate_state(state):
    if not isinstance(state, dict) or set(state) != {"reminders", "actions", "clocks"}:
        raise ValueError("invalid_state")
    reminder_ids = set()
    for category, field in (("reminders", "id"), ("actions", "occurrence")):
        entries = state[category]
        if not isinstance(entries, list) or len(entries) > 30_000:
            raise ValueError("invalid_state")
        seen = set()
        for entry in entries:
            if not isinstance(entry, dict):
                raise ValueError("invalid_record")
            if category == "reminders":
                record_id = str(uuid.UUID(entry[field])).upper()
                if entry[field] != record_id or not isinstance(entry.get("schedule"), dict):
                    raise ValueError("invalid_reminder")
                if type(entry.get("revision")) is not int or entry["revision"] < 1:
                    raise ValueError("invalid_reminder")
                if not isinstance(entry.get("title"), str) or not entry["title"].strip():
                    raise ValueError("invalid_reminder")
                reminder_ids.add(record_id)
            else:
                occurrence = entry[field]
                record_id = occurrence["id"]
                snooze = entry.get("snooze")
                if (not isinstance(record_id, str) or not 1 <= len(record_id) <= 250
                        or occurrence["reminderID"] not in reminder_ids
                        or occurrence["state"] not in ("acknowledged", "snoozed")
                        or (occurrence["state"] == "snoozed") != (snooze is not None)):
                    raise ValueError("invalid_action")
                if snooze is not None and (
                    snooze["reminderID"] != occurrence["reminderID"] or snooze.get("isSnooze") is not True
                ):
                    raise ValueError("invalid_action")
            if record_id in seen:
                raise ValueError("duplicate_record")
            seen.add(record_id)

    clocks = state["clocks"]
    fields = {"title", "note", "schedule", "delivery", "availability", "cancelled"}
    if not isinstance(clocks, dict) or not set(clocks) <= reminder_ids:
        raise ValueError("invalid_clock")
    for clock in clocks.values():
        edits = clock["edits"]
        if not isinstance(edits, dict) or not set(edits) <= fields:
            raise ValueError("invalid_clock")
        for stamp in edits.values():
            uuid.UUID(stamp["replica"])
            counter = stamp["counter"]
            if type(counter) is not int or not 1 <= counter <= 9_007_199_254_740_990:
                raise ValueError("invalid_clock")


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


class SyncServer(ThreadingHTTPServer):
    request_queue_size = 32

    def __init__(self, address, handler):
        super().__init__(address, handler)
        self.capacity = threading.BoundedSemaphore(24)

    def process_request(self, request, client_address):
        if not self.capacity.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.capacity.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.capacity.release()


class SyncHandler(BaseHTTPRequestHandler):
    # Request logs exclude credentials, payloads, and URLs.
    def log_request(self, code="-", size="-"):
        self.log_message("%s %s", self.command, code)

    def setup(self):
        self.request.settimeout(15)
        super().setup()

    def send_json(self, status, payload):
        body = encode(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self.send_json(200, {"ok": True})
        else:
            self.handle_state()

    def do_PUT(self):
        self.handle_state()

    def handle_state(self):
        if self.path != "/v1/state":
            self.send_json(404, {"error": "not_found"})
            return
        # Reject browser cross-origin writes, including form requests to a LAN
        # endpoint. Native Meno clients do not send an Origin header.
        if self.headers.get("Origin"):
            self.send_json(403, {"error": "unsupported_origin"})
            return
        if self.server.token is not None:
            supplied = self.headers.get("Authorization", "").encode("utf-8")
            if not hmac.compare_digest(supplied, b"Bearer " + self.server.token):
                self.send_json(401, {"error": "unauthorized"})
                return
        with closing(connect(self.server.database)) as db:
            server_id, = db.execute("SELECT id FROM replica WHERE singleton=1").fetchone()
            if self.command == "PUT":
                if self.headers.get_content_type() != "application/json":
                    self.send_json(415, {"error": "unsupported_content_type"})
                    return
                try:
                    length = int(self.headers.get("Content-Length", "0"))
                    if length > MAX_BODY:
                        self.send_json(413, {"error": "state_too_large"})
                        return
                    if length <= 0:
                        raise ValueError("empty_body")
                    request = json.loads(self.rfile.read(length))
                    state, version = request["state"], request["version"]
                    if str(uuid.UUID(request["serverId"])) != server_id:
                        self.send_json(412, {"error": "server_changed"})
                        return
                    if type(version) is not int or not 0 <= version <= 9_007_199_254_740_990:
                        raise ValueError("invalid_version")
                    validate_state(state)
                    stored = encode(state)
                except (ValueError, TypeError, KeyError, AttributeError, RecursionError):
                    self.send_json(400, {"error": "invalid_state"})
                    return
                # Compare-and-swap; a stale snapshot cannot replace a newer one.
                changed = db.execute(
                    "UPDATE replica SET state=?, version=version+1 WHERE singleton=1 AND version=?",
                    (stored, version),
                ).rowcount
                if not changed:
                    self.send_json(409, {"error": "version_conflict"})
                    return
                self.send_json(200, {"serverId": server_id, "version": version + 1, "state": state})
            else:
                version, stored = db.execute("SELECT version, state FROM replica WHERE singleton=1").fetchone()
                self.send_json(200, {"serverId": server_id, "version": version, "state": json.loads(stored)})


def is_private_host(value):
    networks = ("127.0.0.0/8", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10")
    address = ipaddress.IPv4Address(value)
    return any(address in ipaddress.IPv4Network(network) for network in networks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, default=Path(__file__).resolve().parent / "state" / "meno.sqlite")
    parser.add_argument("--host", type=ipaddress.IPv4Address, default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--tls-cert", type=Path)
    parser.add_argument("--tls-key", type=Path)
    parser.add_argument("--token-file", type=Path)
    options = parser.parse_args()
    if any((options.tls_cert, options.tls_key, options.token_file)) and not all((options.tls_cert, options.tls_key, options.token_file)):
        parser.error("provide --tls-cert, --tls-key and --token-file together")
    if not is_private_host(options.host) and not options.tls_cert:
        parser.error("public listeners require TLS and a device token")
    token = options.token_file.read_bytes().strip() if options.token_file else None
    if token is not None and (not 40 <= len(token) <= 200 or not all(
        char in b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-" for char in token
    )):
        parser.error("token file must contain a high-entropy base64url device token")
    context = None
    if options.tls_cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(options.tls_cert, options.tls_key)

    os.umask(0o077)
    options.database.parent.mkdir(parents=True, exist_ok=True)
    initialize(options.database)
    with SyncServer((str(options.host), options.port), SyncHandler) as server:
        server.database = options.database
        server.token = token
        if context:
            server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
        scheme = "https" if context else "http"
        print(f"Meno Sync listening on {scheme}://{options.host}:{server.server_port}", flush=True)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
