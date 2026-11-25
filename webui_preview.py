"""Preview webui-vue Event Logs locally with a mock Redfish service.

From workspace/sources or your webui-vue checkout, run:
  webui_preview

The launcher finds webui-vue and creates or reuses events.json in the
directory where you ran the command. Edit its Message and refresh the page.
Sign in with preview / preview and open /#/logs/event-logs on the dev server URL.
Save Vue edits for hot reload. Press Ctrl+C to stop.
"""
import argparse
import json
import os
import shutil
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Thread
from urllib.parse import urlsplit

# Vue CLI loads this preview config after its environment and mode are set.
VUE_PREVIEW_CONFIG = """\
const original = require(process.env.WEBUI_PREVIEW_PROJECT_CONFIG);
module.exports = {
  ...original,
  devServer: {
    ...original.devServer,
    proxy: { '/redfish': { target: process.env.BASE_URL, changeOrigin: true } }
  }
};
"""

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
                data = json.loads(fixture.read_text())
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


def find_checkout(start):
    for directory in (start, *start.parents):
        if (directory / "src/store/modules/Logs/EventLogStore.js").is_file():
            return directory
        if directory.name == "sources" and directory.parent.name == "workspace":
            devtool = directory / "webui-vue"
            if (devtool / "package.json").is_file():
                return devtool
            work = directory.parent.parent / "tmp/work"
            matches = sorted(path for path in work.glob("*/webui-vue/*/sources/webui-vue*")
                             if (path / "package.json").is_file())
            if len(matches) == 1:
                return matches[0]
            if matches:
                raise ValueError("Multiple checkouts found. Pass one of: " + ", ".join(map(str, matches)))
    raise ValueError("Run from workspace/sources or pass the webui-vue checkout path.")


def preview_environment(checkout):
    package = json.loads((checkout / "package.json").read_text())
    serve = package.get("scripts", {}).get("serve", "")
    tool = next((name for name in serve.split() if name in ("vite", "vue-cli-service")), None)
    if not tool:
        raise ValueError(f"Unsupported package.json serve script: {serve!r}")
    if not (checkout / "node_modules/.bin" / tool).is_file():
        raise ValueError(f"{tool} is missing in {checkout}. Install the checkout's dependencies. "
                         "For SDK builds, ensure local vendor archives exist before running npm ci, "
                         "or restore node_modules from the matching Yocto build.")

    env = os.environ.copy()
    for directory in (checkout, *checkout.parents):
        candidates = [directory / "recipe-sysroot-native/usr/bin"]
        if directory.name == "workspace":
            candidates.extend(sorted(directory.parent.glob(
                "tmp/work/*/webui-vue/*/recipe-sysroot-native/usr/bin")))
        for bin_dir in candidates:
            if all(os.access(bin_dir / exe, os.X_OK) for exe in ("node", "npm")):
                env["PATH"] = os.pathsep.join([str(bin_dir), *os.get_exec_path(env)])
                return tool, env
    if not all(shutil.which(exe) for exe in ("node", "npm")):
        raise ValueError("Install Node.js and npm or prepare the Yocto webui-vue native sysroot.")
    return tool, env


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("checkout", nargs="?", type=Path,
                        help="webui-vue source directory (default: autodetect).")
    parser.add_argument("--entries", type=Path, help="Redfish collection JSON (default: create or reuse ./events.json)")
    parser.add_argument("--sample", action="store_true", help="print an editable sample and exit")
    args = parser.parse_args()
    if args.sample:
        print(json.dumps(SAMPLE, indent=2))
        return 0
    try:
        checkout = (args.checkout or find_checkout(Path.cwd())).resolve()
        tool, env = preview_environment(checkout)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    if args.entries and not args.entries.is_file():
        parser.error(f"fixture does not exist: {args.entries}")
    fixture = args.entries or Path.cwd() / "events.json"
    if args.entries is None:
        try:
            with fixture.open("x") as out:
                print(json.dumps(SAMPLE, indent=2), file=out)
        except FileExistsError:
            if not fixture.is_file():
                parser.error(f"Expected a JSON file at {fixture}")
    print(f"Checkout: {checkout}\nMock events: {fixture.resolve()}", flush=True)
    with TemporaryDirectory() as config_dir, ThreadingHTTPServer(("127.0.0.1", 0), MockRedfish) as server:
        server.fixture = fixture
        Thread(target=server.serve_forever, daemon=True).start()
        env["BASE_URL"] = f"http://127.0.0.1:{server.server_port}"
        if tool == "vue-cli-service":
            project_config = next((checkout / name for name in ("vue.config.js", "vue.config.cjs")
                                   if (checkout / name).is_file()), None)
            if project_config is None:
                parser.error("Vue CLI preview requires the checkout's vue.config.js or vue.config.cjs.")
            preview_config = Path(config_dir) / "vue.config.cjs"
            preview_config.write_text(VUE_PREVIEW_CONFIG)
            # Vue CLI 5 looks up package metadata beside an external config.
            (preview_config.parent / "package.json").write_text('{"type":"commonjs"}')
            env["WEBUI_PREVIEW_PROJECT_CONFIG"] = str(project_config)
            env["VUE_CLI_SERVICE_CONFIG_PATH"] = str(preview_config)
            env["VUE_APP_SUBSCRIBE_SOCKET_DISABLED"] = "true"
        print("Open /#/logs/event-logs on the dev server URL. Sign in with preview / preview.", flush=True)
        try:
            return subprocess.call(["npm", "run", "serve", "--", "--host", "127.0.0.1"],
                                   cwd=checkout, env=env)
        except KeyboardInterrupt:
            return 130


if __name__ == "__main__":
    raise SystemExit(main())
