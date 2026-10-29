"""Exercise first-run commands against temporary files and synthetic HTTP only."""
import contextlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

EXECUTABLE = str(Path(sys.argv.pop(1)).resolve())
ROOT = Path(__file__).resolve().parent.parent


class MockHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def reply(self, value):
        body = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.server.requests.append(("GET", self.path))
        self.reply(self.server.responses[self.path])

    def do_POST(self):
        self.server.requests.append(("POST", self.path))
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.queries.append(body)
        self.reply(self.server.responses[self.path])


@contextlib.contextmanager
def mock_server(responses):
    server = ThreadingHTTPServer(("127.0.0.1", 0), MockHandler)
    server.responses = responses
    server.requests = []
    server.queries = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield server
    finally:
        server.shutdown()
        thread.join()
        server.server_close()


class OnboardingCLI(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asko-cli-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / "config.json"
        self.env = dict(os.environ)
        for name in ("OPENROUTER_API_KEY", "OPENCODE_GO_API_KEY", "ASKO_EMBEDDING_API_KEY", "ASKO_INGEST_TOKEN"):
            self.env.pop(name, None)

    def run_cli(self, *args, expected=0, config=None):
        result = subprocess.run(
            [EXECUTABLE, *args, "--config", str(config or self.config)],
            cwd=self.root, env=self.env, text=True, capture_output=True, timeout=20,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def write_config(self, data):
        self.config.write_text(json.dumps(data))
        self.config.chmod(0o600)

    def test_init_is_private_and_never_overwrites(self):
        self.run_cli("init")
        before = self.config.read_bytes()
        data = json.loads(before)
        self.assertTrue(data["dry_run"])
        self.assertEqual(data["rooms"], [])
        self.assertEqual(stat.S_IMODE(self.config.stat().st_mode), 0o600)
        self.run_cli("init", "--profile", "opencode-go", expected=1)
        self.assertEqual(self.config.read_bytes(), before)
        link = self.root / "symlink.json"
        link.symlink_to(self.config)
        self.run_cli("init", config=link, expected=1)
        self.assertEqual(self.config.read_bytes(), before)
        dangling = self.root / "dangling.json"
        target = self.root / "missing.json"
        dangling.symlink_to(target)
        self.run_cli("init", config=dangling, expected=1)
        self.assertFalse(target.exists())

    def test_profiles_and_examples_parse_without_keys(self):
        examples = {"openrouter": ROOT / "config.example.json",
                    "opencode-go": ROOT / "examples/config.opencode-go.json",
                    "local-jina": ROOT / "examples/config.local-jina.json"}
        for profile in ("openrouter", "opencode-go", "local-jina"):
            with self.subTest(profile=profile):
                config = self.root / profile / "config.json"
                self.run_cli("init", "--profile", profile, config=config)
                self.assertEqual(json.loads(config.read_text()), json.loads(examples[profile].read_text()))
                result = json.loads(self.run_cli("check-config", config=config).stdout)
                self.assertTrue(result["valid"])
                self.assertFalse(result["api_key_present"])
        for config in [ROOT / "config.example.json", *sorted((ROOT / "examples").glob("config.*.json"))]:
            with self.subTest(example=config.name):
                self.run_cli("check-config", config=config)

    def test_invalid_profile_creates_nothing(self):
        self.run_cli("init", "--profile", "unknown", expected=1)
        self.assertFalse(self.config.exists())

    def test_offline_doctor_distinguishes_format_from_readiness(self):
        self.run_cli("init")
        self.run_cli("check-config")
        result = json.loads(self.run_cli("doctor", expected=1).stdout)
        self.assertFalse(result["ready"])
        missing = {c["name"] for c in result["checks"] if c["status"] == "missing"}
        self.assertEqual(missing, {"bot_id", "rooms", "chat_key", "embedding_key", "ingest_token"})
        self.assertFalse((self.root / "var").exists())

    def test_missing_embedding_key_can_be_diagnosed(self):
        self.write_config({"chat_url": "https://chat.example.invalid/v1"})
        self.run_cli("check-config", expected=1)
        result = json.loads(self.run_cli("doctor", expected=1).stdout)
        self.assertTrue(any(c["name"] == "embedding_key" and c["status"] == "missing" for c in result["checks"]))

    def test_directory_cannot_be_used_as_database(self):
        self.write_config({"db_path": str(self.root)})
        result = json.loads(self.run_cli("doctor", expected=1).stdout)
        self.assertTrue(any(c["name"] == "storage" and c["status"] == "error" for c in result["checks"]))

    def test_online_diagnosis_reads_only_config_and_health_and_redacts_secrets(self):
        with mock_server({}) as server:
            port = server.server_port
            self.env["OPENROUTER_API_KEY"] = "synthetic-private-key"
            self.env["ASKO_INGEST_TOKEN"] = "synthetic-private-token"
            self.write_config({"bot_id": "9007199254740993", "rooms": ["42"], "port": port,
                               "iris_url": f"http://127.0.0.1:{port}"})
            fingerprint = json.loads(self.run_cli("check-config").stdout)["scope_fingerprint"]
            server.responses.update({
                "/config": {"bot_id": "9007199254740993", "web_server_endpoint":
                            f"http://127.0.0.1:{port}/events/iris?token=synthetic-private-token"},
                "/health": {"ok": True, "dry_run": True, "allowed_rooms": 1, "scope_fingerprint": fingerprint},
            })
            result = self.run_cli("doctor")
            self.assertEqual(server.requests, [])
            self.assertTrue(json.loads(result.stdout)["ready"])
            result = self.run_cli("doctor", "--online")
            self.assertTrue(json.loads(result.stdout)["ready"])
            self.assertEqual(server.requests, [("GET", "/config"), ("GET", "/health")])
            self.assertNotIn("synthetic-private", result.stdout + result.stderr)
            self.assertFalse((self.root / "var").exists())
            changed = json.loads(self.config.read_text())
            changed["rooms"] = ["43"]
            self.write_config(changed)
            stale = json.loads(self.run_cli("doctor", "--online", expected=1).stdout)
            self.assertTrue(any(c["name"] == "backend" and c["status"] == "error" for c in stale["checks"]))
            server.responses["/config"]["bot_id"] = "999"
            self.run_cli("doctor", "--online", expected=1)
            server.responses["/health"] = []
            self.run_cli("doctor", "--online", expected=1)

    def test_rooms_only_lists_metadata_and_does_not_enable_rooms(self):
        with mock_server({"/query": {"data": [
            {"room_id": "9007199254740993", "private_meta": '{"name":"테스트 방"}', "name": "Fallback"},
            {"room_id": "42", "private_meta": None, "name": "Another room"},
        ]}}) as server:
            self.write_config({"iris_url": f"http://127.0.0.1:{server.server_port}", "rooms": ["42"]})
            original = self.config.read_bytes()
            result = json.loads(self.run_cli("rooms").stdout)
            self.assertEqual(result["rooms"], [
                {"id": "9007199254740993", "name": "테스트 방", "enabled": False},
                {"id": "42", "name": "Another room", "enabled": True},
            ])
            self.assertEqual(server.requests, [("POST", "/query")])
            self.assertNotIn("chat_logs", server.queries[0]["query"])
            self.assertEqual(self.config.read_bytes(), original)
            self.assertFalse((self.root / "var").exists())


if __name__ == "__main__":
    unittest.main()
