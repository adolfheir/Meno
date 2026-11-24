#!/usr/bin/env python3
"""Allow an app-bundled private CA only for the configured sync endpoint."""

import json
import plistlib
import sys
from pathlib import Path
from urllib.parse import urlsplit

plist_path, config_path = map(Path, sys.argv[1:])
config = json.loads(config_path.read_text())
if config.get("rootCertificateDER"):
    endpoint = urlsplit(config["endpoint"])
    if endpoint.scheme != "https" or not endpoint.hostname:
        raise SystemExit("The private sync CA requires an HTTPS endpoint")
    with plist_path.open("rb") as source:
        info = plistlib.load(source)
    transport = info.setdefault("NSAppTransportSecurity", {})
    domains = transport.setdefault("NSExceptionDomains", {})
    # ATS needs a host exception to evaluate the explicitly bundled CA.
    # ReminderSync still requires HTTPS and validates trust against that CA.
    domains[endpoint.hostname] = {"NSExceptionAllowsInsecureHTTPLoads": True}
    with plist_path.open("wb") as output:
        plistlib.dump(info, output, sort_keys=False)
