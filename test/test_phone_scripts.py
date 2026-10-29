"""Phone lifecycle regression tests using temporary files and mock processes only.

Run with: python3 -B test/test_phone_scripts.py
No SSH, Android binaries, repository configuration or real secrets are used.
"""

import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
PHONE = "/data/data/com.termux/files/home/asko"


class PhoneScriptsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="asko-phone-scripts-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.phone = self.root / "phone"
        for directory in ("var", "secrets", "releases"):
            (self.phone / directory).mkdir(parents=True, exist_ok=True)
        self.proc = self.root / "proc"
        self.proc.mkdir()
        self.signals = self.root / "signals"
        self.held = self.root / "held"
        self.env = {
            "PATH": os.environ["PATH"],
            "ASKO_TEST_SIGNALS": str(self.signals),
            "ASKO_TEST_HELD": str(self.held),
        }

    def source(self, name, remote=False, mock_lock=False):
        source = (REPO / name).read_text()
        if remote:
            source = source.split("<<'REMOTE'\n", 1)[1].split("\nREMOTE\n", 1)[0]
        source = source.replace(PHONE, str(self.phone))
        source = source.replace("/data/data/com.termux/files/usr/tmp", str(self.root))
        source = source.replace("/proc/", str(self.proc) + "/")
        source = source.replace("/system/bin/sh", "/bin/sh")
        source = source.replace("/system/bin/sleep", "asko_test_sleep")
        source = source.replace("/system/bin/nohup", "asko_test_nohup")
        flock = "asko_test_flock" if mock_lock else shutil.which("flock")
        self.assertIsNotNone(flock, "These tests require local flock")
        source = source.replace("/system/bin/flock", flock)
        # Signals and service starts are always mocked, including unexpected calls.
        mocks = """
kill() {
    [ "${1:-}" != -0 ] || return 1
    printf '%s\\n' "$*" >>"$ASKO_TEST_SIGNALS"
    rm -f "$ASKO_TEST_HELD"
}
asko_test_flock() { [ ! -f "$ASKO_TEST_HELD" ]; }
asko_test_sleep() { /bin/sleep 0.02; }
asko_test_nohup() {
    printf '%s\\n' 777 >var/supervisor.pid
    printf '%s\\n' started >var/test-started
}
"""
        return mocks + source

    def run_shell(self, source, *args, env=None):
        return subprocess.run(
            ["/bin/sh", "-s", "--", *args],
            input=source,
            text=True,
            cwd=self.phone,
            env=self.env | (env or {}),
            capture_output=True,
            timeout=5,
        )

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def write_binary(self, path):
        path.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, sys\n"
            "config = pathlib.Path(sys.argv[sys.argv.index('--config') + 1])\n"
            "value = json.loads(config.read_text())\n"
            "record = {'argv': sys.argv[1:], 'config': str(config),\n"
            "          'ca': pathlib.Path(os.environ['SSL_CERT_FILE']).read_text(),\n"
            "          'keys': {key: os.environ.get(key) for key in\n"
            "          ['OPENROUTER_API_KEY', 'OPENCODE_GO_API_KEY',\n"
            "           'ASKO_EMBEDDING_API_KEY', 'ASKO_INGEST_TOKEN']}}\n"
            "print(json.dumps(record))\n"
            "if sys.argv[1] == 'check-config' and not value.get('valid'):\n"
            "    sys.exit(41)\n"
            "if sys.argv[1] == 'version' and not value.get('version_valid', True):\n"
            "    sys.exit(42)\n"
        )
        path.chmod(0o700)

    def install_old(self, valid=True):
        old = self.phone / "releases/old"
        old.mkdir()
        self.write_binary(old / "asko")
        (old / "cacert.pem").write_text("old-ca")
        (self.phone / "current").symlink_to("releases/old")
        (self.phone / "run-phone.sh").write_text("old launcher\n")
        (self.phone / "supervise-phone.sh").write_text("old supervisor\n")
        (self.phone / "config.local.json").write_text(json.dumps({"valid": valid}))

    def stage(self, valid=True, version_valid=True):
        pending = self.phone / "releases/.pending-test"
        pending.mkdir()
        self.write_binary(pending / "asko")
        (pending / "cacert.pem").write_text("new-ca")
        (pending / "config.example.json").write_text(
            json.dumps({"valid": valid, "version_valid": version_valid})
        )
        for name in ("run-phone.sh", "supervise-phone.sh"):
            (pending / name).write_text("new launcher; must not run during validation\n")
        names = ("asko", "cacert.pem", "config.example.json", "run-phone.sh", "supervise-phone.sh")
        manifest = "".join(
            hashlib.sha256((pending / name).read_bytes()).hexdigest() + "  " + name + "\n"
            for name in names
        )
        (pending / "SHA256SUMS").write_text(manifest)
        (self.phone / "secrets/ingest.token").write_text("test-ingest")
        release = hashlib.sha256(manifest.encode()).hexdigest()[:16]
        return release, pending.name

    def deploy(self, release, pending, env=None):
        return self.run_shell(
            self.source("scripts/deploy-android.sh", remote=True), release, pending, env=env
        )

    def records(self, result):
        return [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]

    def test_failed_existing_config_keeps_active_release_and_launchers(self):
        self.install_old(valid=False)
        before = (self.phone / "config.local.json").read_bytes()
        release, pending = self.stage()
        result = self.deploy(release, pending)
        self.assertEqual(result.returncode, 41, result.stderr)
        self.assertEqual(os.readlink(self.phone / "current"), "releases/old")
        self.assertEqual((self.phone / "run-phone.sh").read_text(), "old launcher\n")
        self.assertEqual((self.phone / "supervise-phone.sh").read_text(), "old supervisor\n")
        self.assertEqual((self.phone / "config.local.json").read_bytes(), before)
        self.assertFalse((self.phone / "previous-release").exists())
        self.assertEqual(self.records(result)[0]["ca"], "new-ca")

    def test_invalid_first_config_leaves_installation_inactive(self):
        release, pending = self.stage(valid=False)
        result = self.deploy(release, pending)
        self.assertEqual(result.returncode, 41, result.stderr)
        for name in ("current", "config.local.json", "run-phone.sh", "supervise-phone.sh"):
            self.assertFalse((self.phone / name).exists(), name)

    def test_existing_config_wins_over_example_and_uses_staged_ca_and_secrets(self):
        self.install_old()
        before = (self.phone / "config.local.json").read_bytes()
        self.write_secrets()
        release, pending = self.stage(valid=False)
        result = self.deploy(release, pending)
        self.assert_ok(result)
        self.assertEqual((self.phone / "config.local.json").read_bytes(), before)
        self.assertEqual(os.readlink(self.phone / "current"), "releases/" + release)
        self.assertEqual((self.phone / "previous-release").read_text().strip(), "releases/old")
        self.assertEqual([r["argv"][0] for r in self.records(result)], ["check-config", "version"])
        for record in self.records(result):
            self.assertEqual(record["ca"], "new-ca")
            self.assertEqual(record["config"], str(self.phone / "config.local.json"))
            self.assertEqual(record["keys"]["OPENCODE_GO_API_KEY"], "test-go")
            self.assertEqual(record["keys"]["ASKO_EMBEDDING_API_KEY"], "test-embedding")
            self.assertEqual(record["keys"]["OPENROUTER_API_KEY"], "test-openrouter")

    def test_valid_first_install_copies_only_validated_example(self):
        release, pending = self.stage()
        result = self.deploy(release, pending)
        self.assert_ok(result)
        self.assertEqual(os.readlink(self.phone / "current"), "releases/" + release)
        self.assertEqual(
            (self.phone / "config.local.json").read_bytes(),
            (self.phone / "current/config.example.json").read_bytes(),
        )

    def test_deploy_respects_explicit_environment_keys(self):
        self.install_old()
        self.write_secrets()
        release, pending = self.stage()
        overrides = {"OPENROUTER_API_KEY": "test-env-router", "OPENCODE_GO_API_KEY": "",
                     "ASKO_EMBEDDING_API_KEY": "test-env-embedding"}
        result = self.deploy(release, pending, env=overrides)
        self.assert_ok(result)
        for record in self.records(result):
            for key, value in overrides.items():
                self.assertEqual(record["keys"][key], value)

    def test_version_failure_also_precedes_activation(self):
        release, pending = self.stage(version_valid=False)
        result = self.deploy(release, pending)
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertFalse((self.phone / "current").exists())
        self.assertFalse((self.phone / "run-phone.sh").exists())

    def write_secrets(self):
        for name, value in (("openrouter.key", "test-openrouter"),
                            ("opencode-go.key", "test-go"),
                            ("embedding.key", "test-embedding")):
            (self.phone / "secrets" / name).write_text(value + "\n")

    def test_launcher_loads_optional_secret_files_and_preserves_legacy_key(self):
        self.install_old()
        self.write_secrets()
        result = self.run_shell(self.source("scripts/run-phone.sh"))
        self.assert_ok(result)
        record = self.records(result)[0]
        self.assertEqual(record["argv"][0], "serve")
        self.assertEqual(record["keys"]["OPENROUTER_API_KEY"], "test-openrouter")
        self.assertEqual(record["keys"]["OPENCODE_GO_API_KEY"], "test-go")
        self.assertEqual(record["keys"]["ASKO_EMBEDDING_API_KEY"], "test-embedding")

    def test_launcher_respects_explicit_environment_even_empty_new_keys(self):
        self.install_old()
        self.write_secrets()
        for value in ("explicit-test-key", ""):
            with self.subTest(value=value):
                result = self.run_shell(self.source("scripts/run-phone.sh"), env={
                    "OPENROUTER_API_KEY": value,
                    "OPENCODE_GO_API_KEY": value,
                    "ASKO_EMBEDDING_API_KEY": value,
                })
                self.assert_ok(result)
                keys = self.records(result)[0]["keys"]
                self.assertEqual(keys["OPENROUTER_API_KEY"], value or "test-openrouter")
                self.assertEqual(keys["OPENCODE_GO_API_KEY"], value)
                self.assertEqual(keys["ASKO_EMBEDDING_API_KEY"], value)

    def test_missing_optional_secret_files_leave_keys_unset(self):
        self.install_old()
        result = self.run_shell(self.source("scripts/run-phone.sh"))
        self.assert_ok(result)
        self.assertTrue(all(value is None for value in self.records(result)[0]["keys"].values()))

    def test_supervisor_initialization_failure_cleans_pids_and_keeps_lock_inode(self):
        runner = self.phone / "run-phone.sh"
        runner.write_text("#!/bin/sh\nexit 37\n")
        runner.chmod(0o700)
        lock = self.phone / "var/supervisor.lock"
        lock.touch()
        inode = lock.stat().st_ino
        for name in ("supervisor.pid", "child.pid", "embedding.pid"):
            (self.phone / "var" / name).write_text("stale")
        result = self.run_shell(self.source("scripts/supervise-phone.sh"))
        self.assertEqual(result.returncode, 37, result.stderr)
        self.assertEqual(lock.stat().st_ino, inode)
        self.assertFalse(list((self.phone / "var").glob("*.pid")))
        self.assertFalse(self.signals.exists())

    def test_stop_cleans_stale_or_empty_pid_only_under_lock(self):
        for value in ("", "987654", "malformed"):
            with self.subTest(value=value):
                (self.phone / "var/supervisor.pid").write_text(value)
                (self.phone / "var/child.pid").write_text("987655")
                lock = self.phone / "var/supervisor.lock"
                lock.touch()
                inode = lock.stat().st_ino
                result = self.run_shell(self.source("scripts/control-phone.sh", remote=True), "stop")
                self.assert_ok(result)
                self.assertFalse(list((self.phone / "var").glob("*.pid")))
                self.assertEqual(lock.stat().st_ino, inode)
                self.assertFalse(self.signals.exists())

    def fake_process(self, arguments):
        process = self.proc / "12345"
        process.mkdir()
        (process / "cmdline").write_bytes(b"\0".join(arg.encode() for arg in arguments) + b"\0")
        (process / "cwd").symlink_to(self.phone)
        (self.phone / "var/supervisor.pid").write_text("12345\n")
        self.held.touch()

    def test_held_lock_with_unrelated_pid_is_never_signalled(self):
        self.fake_process(["/bin/sh", "-c", "echo ./supervise-phone.sh"])
        result = self.run_shell(self.source("scripts/control-phone.sh", remote=True, mock_lock=True), "stop")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to signal", result.stderr)
        self.assertTrue((self.phone / "var/supervisor.pid").exists())
        self.assertFalse(self.signals.exists())

    def test_held_lock_with_empty_pid_is_not_cleared(self):
        (self.phone / "var/supervisor.pid").touch()
        self.held.touch()
        result = self.run_shell(self.source("scripts/control-phone.sh", remote=True, mock_lock=True), "stop")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.phone / "var/supervisor.pid").exists())
        self.assertFalse(self.signals.exists())

    def test_verified_supervisor_stop_waits_for_lock_before_cleanup(self):
        self.fake_process(["/bin/sh", "./supervise-phone.sh"])
        result = self.run_shell(self.source("scripts/control-phone.sh", remote=True, mock_lock=True), "stop")
        self.assert_ok(result)
        self.assertEqual(self.signals.read_text().strip(), "12345")
        self.assertFalse((self.phone / "var/supervisor.pid").exists())

    def test_restart_recovers_stale_pid_without_signalling_it(self):
        (self.phone / "var/supervisor.pid").write_text("987654")
        result = self.run_shell(self.source("scripts/control-phone.sh", remote=True), "restart")
        self.assert_ok(result)
        self.assertTrue((self.phone / "var/test-started").exists())
        self.assertFalse((self.phone / "var/disabled").exists())
        self.assertFalse(self.signals.exists())

    def maintenance_fixture(self, script, uid="10456"):
        home = self.root / "home"
        (home / ".ssh").mkdir(parents=True, exist_ok=True)
        (home / ".ssh/asko-sshd.conf").write_text("PidFile " + str(self.root / "sshd.pid") + "\n")
        directory = self.root / "ssh"
        directory.mkdir(exist_ok=True)
        supervisor = directory / "supervise.sh"
        supervisor.write_text(script)
        binary_dir = self.root / "bin"
        binary_dir.mkdir(exist_ok=True)
        su = binary_dir / "su"
        su.write_text("#!/bin/sh\nexit 99\n")
        su.chmod(0o700)
        (self.proc / "self").mkdir(exist_ok=True)
        (self.proc / "self/status").write_text("CapEff:\t0000000000000001\n")
        source = self.source("tools/fix-phone-ssh.sh")
        source = source.replace("/data/data/com.termux/files/home", str(home))
        source = source.replace("/data/adb/asko-ssh", str(directory))
        source = source.replace("/system/bin/stat", "asko_test_stat")
        source = source.replace("/system/bin/id", "asko_test_id")
        source = "asko_test_stat() { printf '%s\\n' \"$ASKO_TEST_UID\"; }\n" + source
        source = "asko_test_id() { printf '%s\\n' \"${ASKO_TEST_CALLER_UID:-0}\"; }\n" + source
        source = source.replace("/system/bin/readlink", shutil.which("readlink"))
        environment = {"PATH": str(binary_dir) + os.pathsep + self.env["PATH"], "ASKO_TEST_UID": uid}
        return source, environment, supervisor, su

    def test_ssh_maintenance_uses_discovered_su_and_actual_termux_uid(self):
        original = "#!/bin/sh\nexec /product/bin/su -d -g 10456 -G 3003 -s /system/bin/sh 10456\n"
        source, env, supervisor, su = self.maintenance_fixture(original)
        result = self.run_shell(source, env=env)
        self.assert_ok(result)
        self.assertEqual(supervisor.read_text(), original.replace("/product/bin/su -d", str(su)))
        self.assertEqual(supervisor.with_suffix(".sh.before-capability-fix").read_text(), original)
        self.assertFalse(self.signals.exists())

    def test_ssh_maintenance_is_idempotent_for_recognized_fixed_script(self):
        source, env, supervisor, su = self.maintenance_fixture("")
        fixed = f"#!/bin/sh\nexec {su} -g 10456 -G 3003 -s /system/bin/sh 10456\n"
        supervisor.write_text(fixed)
        result = self.run_shell(source, env=env)
        self.assert_ok(result)
        self.assertEqual(supervisor.read_text(), fixed)
        self.assertFalse(supervisor.with_suffix(".sh.before-capability-fix").exists())

    def test_ssh_maintenance_refuses_unexpected_scripts_before_changes(self):
        known = "exec /product/bin/su -d -g 10456 -G 3003 -s /system/bin/sh 10456\n"
        for original in (known.replace("10456", "10323"),
                         known.replace("10456", "104560"),
                         "# " + known,
                         known + known,
                         known + "if\n"):
            with self.subTest(script=original):
                source, env, supervisor, _ = self.maintenance_fixture(original)
                result = self.run_shell(source, env=env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(supervisor.read_text(), original)
                self.assertFalse(supervisor.with_suffix(".sh.before-capability-fix").exists())
                self.assertFalse((self.phone / "var/test-started").exists())
                self.assertFalse(self.signals.exists())

    def test_ssh_maintenance_refuses_invalid_termux_uid(self):
        original = "exec /product/bin/su -d -g 10456 -G 3003\n"
        for uid in ("", "not-a-uid", "9999"):
            with self.subTest(uid=uid):
                source, env, supervisor, _ = self.maintenance_fixture(original, uid=uid)
                result = self.run_shell(source, env=env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(supervisor.read_text(), original)
                self.assertFalse((self.phone / "var/test-started").exists())

    def test_ssh_maintenance_relaunches_actual_script_with_shell_safe_path(self):
        source, env, _, su = self.maintenance_fixture("")
        capture = self.root / "su-arguments.json"
        su.write_text(
            f"#!{sys.executable}\n"
            "import json, os, pathlib, sys\n"
            "pathlib.Path(os.environ['ASKO_TEST_SU_ARGS']).write_text(json.dumps(sys.argv[1:]))\n"
        )
        su.chmod(0o700)
        # Shell metacharacters are part of a synthetic filename, never commands.
        script = self.root / "maintenance space's $(not-a-command);.sh"
        script.write_text(source)
        result = subprocess.run(
            ["/bin/sh", script.name], cwd=self.root,
            env=self.env | env | {"ASKO_TEST_CALLER_UID": "10456", "ASKO_TEST_SU_ARGS": str(capture)},
            text=True, capture_output=True, timeout=5,
        )
        self.assert_ok(result)
        arguments = json.loads(capture.read_text())
        self.assertEqual(arguments[0], "-c")
        self.assertEqual(shlex.split(arguments[1]), ["/bin/sh", str(script.resolve())])
        # Verify a shell receives exactly those arguments without executing a command.
        parsed = subprocess.run(
            ["/bin/sh", "-c", "set -- " + arguments[1] + "; printf '%s\\n' \"$1\" \"$2\""],
            text=True, capture_output=True, timeout=5,
        )
        self.assert_ok(parsed)
        self.assertEqual(parsed.stdout.splitlines(), ["/bin/sh", str(script.resolve())])

    def test_script_syntax(self):
        for name in ("scripts/deploy-android.sh", "scripts/control-phone.sh",
                     "scripts/run-phone.sh", "scripts/supervise-phone.sh", "tools/fix-phone-ssh.sh"):
            with self.subTest(script=name):
                interpreter = "bash" if name in ("scripts/deploy-android.sh", "scripts/control-phone.sh") else "sh"
                result = subprocess.run([interpreter, "-n", str(REPO / name)], text=True,
                                        capture_output=True, timeout=5)
                self.assert_ok(result)


if __name__ == "__main__":
    unittest.main()
