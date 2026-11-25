"""Preview webui-vue Event Logs locally with Vite and a mock Redfish service.

Quick start from workspace/sources (Python 3, Node.js and npm required)
  python3 ~/personal-setup/webui_preview.py ./webui-vue

To edit the sample, create events.json once in your current directory
  python3 ~/personal-setup/webui_preview.py --sample > events.json
  python3 ~/personal-setup/webui_preview.py ./webui-vue --entries events.json

Open the Local URL printed by Vite and sign in with preview / preview.
Visit /#/logs/event-logs on that URL. Save a .vue file in the selected
checkout to see it hot-reload. Edit a Message in events.json, save it,
and refresh the browser to reload the entries. Press Ctrl+C to stop.
"""
import argparse
import json
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Thread
from urllib.parse import urlsplit

ROOT = "/redfish/v1"
SYSTEM = ROOT + "/Systems/system"
ENTRIES = SYSTEM + "/LogServices/EventLog/Entries"
SESSIONS = ROOT + "/SessionService/Sessions"
SESSION = SESSIONS + "/preview"
USER = {"UserName": "preview", "Roles": ["Administrator"], "@odata.id": SESSION}
SAMPLE = {"Members": [{
    "@odata.id": ENTRIES + "/1", "Id": "1", "Name": "Event Log Entry",
    "EntryType": "Event", "Message": "Fan 1 speed below threshold",
    "Created": "2026-11-24T10:00:00Z", "Modified": "2026-11-24T10:00:00Z",
    "Severity": "Warning", "Resolved": False,
}]}


class MockRedfish(BaseHTTPRequestHandler):
    def reply(self, status, data, headers=()):
        body = json.dumps(data).encode()
        self.send_response(status)
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path == SESSIONS:
            self.reply(201, USER, [("Location", SESSION), ("X-Auth-Token", "preview"),
                                   ("Set-Cookie", "XSRF-TOKEN=preview; Path=/; SameSite=Strict")])
        else:
            self.reply(404, {})

    def do_GET(self):
        path = urlsplit(self.path).path.rstrip("/")
        if path == ENTRIES:
            try:
                fixture = self.server.fixture
                data = json.loads(fixture.read_text()) if fixture else SAMPLE
                self.reply(200, data)
            except (ValueError, OSError) as error:
                self.reply(500, {"error": str(error)})
            return
        resources = {
            ROOT: {"Systems": {"@odata.id": ROOT + "/Systems"}},
            ROOT + "/Systems": {"Members": [{"@odata.id": SYSTEM}]},
            SYSTEM: {"Id": "system", "Status": {"State": "Enabled"}},
            ROOT + "/Managers": {"Members": [{"@odata.id": ROOT + "/Managers/bmc"}]},
            ROOT + "/Managers/bmc": {"Id": "bmc"},
            SESSION: USER,
        }
        self.reply(200 if path in resources else 404, resources.get(path, {}))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("checkout", nargs="?", type=Path, default=Path.cwd(),
                        help="webui-vue source directory (default: current directory). Run npm ci there if Vite is missing.")
    parser.add_argument("--entries", type=Path, help="Redfish collection JSON (default: one built-in warning entry)")
    parser.add_argument("--sample", action="store_true", help="print an editable sample and exit")
    args = parser.parse_args()
    if args.sample:
        print(json.dumps(SAMPLE, indent=2))
        return 0
    if not (args.checkout / "node_modules/.bin/vite").is_file():
        parser.error("supply the webui-vue directory with npm dependencies installed")
    if args.entries and not args.entries.is_file():
        parser.error(f"fixture does not exist: {args.entries}")
    with ThreadingHTTPServer(("127.0.0.1", 0), MockRedfish) as server:
        server.fixture = args.entries
        Thread(target=server.serve_forever, daemon=True).start()
        env = dict(os.environ, BASE_URL=f"http://127.0.0.1:{server.server_port}")
        print("Open /#/logs/event-logs on the Vite URL. Sign in with preview / preview.", flush=True)
        try:
            return subprocess.call(["npm", "run", "serve", "--", "--host", "127.0.0.1"],
                                   cwd=args.checkout, env=env)
        except KeyboardInterrupt:
            return 130


if __name__ == "__main__":
    raise SystemExit(main())
