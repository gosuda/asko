#!/usr/bin/env python3
"""Local shell integration tests; all device paths and privileged calls are mocked."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
SOURCES = (
    "scripts/install-boot-service.sh",
    "scripts/deploy-iris-phone.sh",
    "tools/magisk-asko.sh.in",
    "tools/magisk-iris.sh.in",
)

MOCK = r'''
import json, os, pathlib, shutil, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["ASKO_TEST_ROOT"])
with (root / "calls").open("a") as log:
    log.write(json.dumps([name, args]) + "\n")
env = os.environ.copy()
if name == "ssh":
    command = " ".join(args[args.index("--") + 2:])
    sys.exit(subprocess.run(["/bin/sh", "-c", command], input=sys.stdin.read(), text=True, env=env).returncode)
elif name == "scp":
    home = root / "device/data/data/com.termux/files/home"
    destination = home / args[-1].split(":", 1)[1]
    for source in [a for a in args[:-1] if a != "-q"]:
        shutil.copyfile(source, destination / pathlib.Path(source).name if destination.is_dir() else destination)
elif name == "su":
    if os.environ.get("ASKO_TEST_NO_ROOT") == "1":
        sys.exit(1)
    dropping = "-d" in args
    env["ASKO_TEST_UID"] = os.environ.get("ASKO_TEST_DROP_UID", args[args.index("-c") - 1]) if dropping else "0"
    command = args[args.index("-c") + 1]
    # A deploy command is recorded, never executed, even inside the fake device.
    if "iris-install-root.sh" in command:
        sys.exit(0)
    sys.exit(subprocess.run(["/bin/sh", "-c", command], env=env).returncode)
elif name == "id":
    print(os.environ.get("ASKO_TEST_UID", "10042"))
elif name == "stat":
    print(os.environ.get("ASKO_TEST_OWNER", "10042"))
elif name == "sleep":
    # No actual waiting. A mock-only cap also stops a broken test's background
    # shell, without imposing a deadline on either production boot template.
    calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()]
    count = sum(command == "sleep" for command, _ in calls)
    if count > 150:
        sys.exit(99)
    if count >= int(os.environ.get("ASKO_TEST_UNLOCK_AFTER", "999")):
        (root / "device/sdcard/Android").mkdir(parents=True, exist_ok=True)
        backend = root / "device/data/data/com.termux/files/home/asko/current/asko"
        backend.parent.mkdir(parents=True, exist_ok=True)
        backend.write_text("#!/bin/sh\nexit 98\n")
        backend.chmod(0o700)
elif name == "sha256sum":
    sys.stdin.read()
elif name == "curl":
    raise SystemExit("network access is forbidden in these tests")
else:
    raise SystemExit("unexpected mock command: " + name)
'''


class BootScripts(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="asko-boot-test-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.device = self.root / "device"
        self.repo = self.root / "repo"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = os.environ.copy()
        # Use only mock privileged/network commands; retain basic host utilities.
        self.env.update(ASKO_TEST_ROOT=str(self.root), PATH=f"{self.bin}:/usr/bin:/bin")
        for key in ("LD_PRELOAD", "LD_LIBRARY_PATH"):
            self.env.pop(key, None)
        for name in ("ssh", "scp", "su", "id", "stat", "sleep", "curl", "sha256sum"):
            self.executable(self.bin / name, f"#!{sys.executable}\n" + MOCK)
        system = self.device / "system/bin"
        system.mkdir(parents=True)
        (system / "sh").symlink_to("/bin/sh")
        for name in ("id", "stat", "sleep"):
            (system / name).symlink_to(self.bin / name)
        for name in ("iptables", "ip6tables", "unshare", "mount", "app_process", "nohup"):
            self.executable(system / name, "#!/bin/sh\nexit 98\n")
        self.home = self.device / "data/data/com.termux/files/home/asko"
        self.home.mkdir(parents=True)
        self.services = self.device / "data/adb/service.d"
        self.services.mkdir(parents=True)
        self.iris = self.device / "data/local/tmp/asko-iris"
        self.iris.mkdir(parents=True)
        self.executable(self.iris / "iris-start.sh", '#!/bin/sh\nprintf started >>"$ASKO_TEST_ROOT/iris-started"\n')
        (self.iris / "iris-inner.sh").write_text("#!/bin/sh\nexit 98\n")
        (self.iris / "Iris.apk").write_text("fixture, not an APK")
        self.executable(self.home / "current/asko", "#!/bin/sh\nexit 98\n")
        self.executable(self.home / "supervise-phone.sh", '#!/bin/sh\nid -u >"$ASKO_TEST_ROOT/backend-uid"\n')
        (self.device / "data/data/com.kakao.talk/databases").mkdir(parents=True)
        (self.device / "sdcard/Android").mkdir(parents=True)
        for relative in SOURCES:
            target = self.repo / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(self.rewrite((REPO / relative).read_text()))
        # No download or real Iris installation is allowed in the deploy test.
        cache = self.repo / ".cache/iris/v0.33"
        cache.mkdir(parents=True)
        (cache / "Iris.apk").write_text("fixture, not an APK")
        for name in ("iris-start.sh", "iris-inner.sh", "iris-install-root.sh"):
            (self.repo / "tools" / name).write_text("#!/bin/sh\nexit 98\n")

    @staticmethod
    def executable(path, source):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source)
        path.chmod(0o700)

    def rewrite(self, source):
        for prefix in ("/system/", "/data/", "/data_mirror/", "/sdcard/", "/product/", "/sbin/", "/debug_ramdisk/", "/su/"):
            source = source.replace(prefix, str(self.device) + prefix)
        return source

    def run_script(self, relative="scripts/install-boot-service.sh", *args):
        return subprocess.run(["/bin/bash", str(self.repo / relative), *args], env=self.env,
                              text=True, capture_output=True, timeout=15)

    def calls(self, name):
        path = self.root / "calls"
        return [args for command, args in map(json.loads, path.read_text().splitlines()) if command == name] if path.exists() else []

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def boot(self, name, uid="10042"):
        source = (self.repo / "tools" / name).read_text().replace("@UID@", uid)
        # Join the template's background shell so no child outlives the test.
        return subprocess.run(["/bin/sh"], input=source + '\nwait "$!"\n', env=self.env,
                              text=True, capture_output=True, timeout=10)

    def test_shell_syntax(self):
        for relative in SOURCES:
            with self.subTest(relative=relative):
                shell = "/bin/bash" if relative.endswith(".sh") else "/bin/sh"
                result = subprocess.run([shell, "-n"], input=(REPO / relative).read_text().replace("@UID@", "10042"), text=True, capture_output=True)
                self.assert_ok(result)

    def test_help_and_invalid_options_do_not_contact_device(self):
        self.assert_ok(self.run_script("scripts/install-boot-service.sh", "--help"))
        for args in (("--update",), ("bad host",), ("one", "two")):
            self.assertEqual(self.run_script("scripts/install-boot-service.sh", *args).returncode, 2)
        self.assertFalse(self.calls("ssh"))

    def test_default_is_backend_only_and_idempotent(self):
        self.assert_ok(self.run_script())
        backend = self.services / "asko-backend.sh"
        before = backend.stat()
        self.assertEqual(before.st_mode & 0o777, 0o700)
        self.assertFalse((self.services / "asko-iris.sh").exists())
        self.assert_ok(self.run_script())
        self.assertEqual(backend.stat().st_ino, before.st_ino)
        self.assertFalse((self.root / "backend-uid").exists())
        self.assertFalse((self.root / "iris-started").exists())

    def test_explicit_iris_is_idempotent_without_starting_services(self):
        self.assert_ok(self.run_script("scripts/install-boot-service.sh", "--with-iris", "test-phone"))
        iris = self.services / "asko-iris.sh"
        before = iris.stat()
        self.assert_ok(self.run_script("scripts/install-boot-service.sh", "test-phone", "--with-iris"))
        self.assertEqual(iris.stat().st_ino, before.st_ino)
        self.assert_ok(self.run_script())
        self.assertTrue(iris.exists())  # Backend-only install does not revoke an earlier opt-in.
        self.assertFalse((self.root / "iris-started").exists())
        self.assertFalse((self.root / "backend-uid").exists())

    def test_conflict_checks_both_entries_before_installing(self):
        conflict = self.services / "asko-iris.sh"
        conflict.write_text("# unrelated or older managed entry\n")
        result = self.run_script("scripts/install-boot-service.sh", "--with-iris")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Refusing to replace", result.stderr)
        self.assertEqual(conflict.read_text(), "# unrelated or older managed entry\n")
        self.assertFalse((self.services / "asko-backend.sh").exists())

    def test_existing_symlink_is_refused(self):
        target = self.root / "unrelated"
        target.write_text("keep")
        (self.services / "asko-backend.sh").symlink_to(target)
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertEqual(target.read_text(), "keep")

    def test_preflight_rejects_root_wrong_owner_and_failed_drop(self):
        for overrides in ({"ASKO_TEST_UID": "0"}, {"ASKO_TEST_UID": "invalid"},
                          {"ASKO_TEST_OWNER": "10043"}, {"ASKO_TEST_DROP_UID": "0"},
                          {"ASKO_TEST_NO_ROOT": "1"}):
            with self.subTest(overrides=overrides):
                saved = self.env.copy()
                self.env.update(overrides)
                self.assertNotEqual(self.run_script().returncode, 0)
                self.assertFalse(self.calls("scp"))
                self.env = saved

    def test_iris_preflight_checks_are_opt_in(self):
        (self.iris / "Iris.apk").unlink()
        self.assertNotEqual(self.run_script("scripts/install-boot-service.sh", "--with-iris").returncode, 0)
        self.assertFalse(self.calls("scp"))
        self.assert_ok(self.run_script())

    def test_iris_preflight_checks_executable_capabilities(self):
        (self.device / "system/bin/unshare").unlink()
        result = self.run_script("scripts/install-boot-service.sh", "--with-iris")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Missing Iris executable", result.stderr)
        self.assertFalse(self.calls("scp"))

    def test_backend_boot_preserves_nonroot_execution(self):
        self.assert_ok(self.boot("magisk-asko.sh.in"))
        self.assertEqual((self.root / "backend-uid").read_text().strip(), "10042")
        args = self.calls("su")[-1]
        self.assertEqual(args[:6], ["-d", "-g", "10042", "-G", "3003", "-s"])

    def test_boot_rejects_invalid_or_mismatched_uid(self):
        for name in ("magisk-asko.sh.in", "magisk-iris.sh.in"):
            for uid in ("0", "bad", "10043"):
                with self.subTest(name=name, uid=uid):
                    self.assertNotEqual(self.boot(name, uid).returncode, 0)
        self.assertFalse((self.root / "backend-uid").exists())
        self.assertFalse((self.root / "iris-started").exists())

    def test_backend_boot_survives_unlock_after_more_than_ten_minutes(self):
        (self.home / "current/asko").unlink()
        self.env["ASKO_TEST_UNLOCK_AFTER"] = "121"
        self.assert_ok(self.boot("magisk-asko.sh.in"))
        self.assertEqual(len(self.calls("sleep")), 121)
        self.assertEqual((self.root / "backend-uid").read_text().strip(), "10042")

    def test_iris_boot_survives_unlock_after_more_than_ten_minutes(self):
        (self.device / "sdcard/Android").rmdir()
        self.env["ASKO_TEST_UNLOCK_AFTER"] = "121"
        self.assert_ok(self.boot("magisk-iris.sh.in"))
        self.assertEqual(len(self.calls("sleep")), 121)
        self.assertEqual((self.root / "iris-started").read_text(), "started")

    def test_iris_boot_waits_for_storage_then_uses_protected_launcher(self):
        (self.device / "sdcard/Android").rmdir()
        self.env["ASKO_TEST_UNLOCK_AFTER"] = "1"
        self.assert_ok(self.boot("magisk-iris.sh.in"))
        self.assertEqual(len(self.calls("sleep")), 1)
        self.assertEqual((self.root / "iris-started").read_text(), "started")

    def test_path_su_and_deploy_uid_validation(self):
        self.assert_ok(self.run_script("scripts/deploy-iris-phone.sh"))
        self.assertTrue(any("iris-install-root.sh" in args[-1] for args in self.calls("su")))
        self.assertFalse(self.calls("curl"))
        count = len(self.calls("scp"))
        for uid in ("0", "10043", "bad"):
            self.env["ASKO_TEST_UID"] = uid
            self.assertNotEqual(self.run_script("scripts/deploy-iris-phone.sh").returncode, 0)
            self.assertEqual(len(self.calls("scp")), count)

    def test_known_su_fallback(self):
        # Hide the host su as well, without touching any host paths.
        (self.bin / "su").unlink()
        for name in ("bash", "sh", "dirname", "mkdir", "mktemp", "sed", "rm", "cmp", "cp", "chmod", "ln", "env"):
            (self.bin / name).symlink_to(shutil.which(name))
        self.env["PATH"] = str(self.bin)
        self.executable(self.device / "system/xbin/su", f"#!{sys.executable}\n" + MOCK)
        self.assert_ok(self.run_script())
        self.assert_ok(self.boot("magisk-asko.sh.in"))
        self.assert_ok(self.run_script("scripts/deploy-iris-phone.sh"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
