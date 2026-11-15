#!/usr/bin/env bats

@test "Unity adb setup selects the system binary and preserves unrelated preferences" {
  run python3 -I - "$BATS_TEST_DIRNAME/../../.config/android/setup-unity-adb.py" <<'PY'
import base64
import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("unity_adb", sys.argv.pop())
setup = importlib.util.module_from_spec(spec)
spec.loader.exec_module(setup)

class UnityAdbTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.sdk = self.home / "SDK with spaces"
        for component in ("platform-tools", "platforms", "build-tools", "cmdline-tools"):
            (self.sdk / component).mkdir(parents=True)
        self.adb = self.home / "system-adb"
        self.adb.write_text("system")
        self.sdk_adb = self.sdk / "platform-tools/adb"
        self.sdk_adb.write_text("bundled")
        self.prefs = self.home / ".local/share/unity3d/prefs"
        self.prefs.parent.mkdir(parents=True)
        self.prefs.write_text('<unity_prefs version_major="1" version_minor="1">'
            '<pref name="Unrelated" type="string">a2VlcA==</pref>'
            '<pref name="AndroidADBKillExternalInstance" type="int">1</pref>'
            '<pref name="AndroidADBKillServerOnExit" type="int">1</pref>'
            '</unity_prefs>')
        self.before = self.prefs.read_bytes()

    def apply(self):
        setup.configure(self.sdk, self.prefs, self.adb)

    def assert_unchanged(self):
        self.assertEqual(self.prefs.read_bytes(), self.before)
        self.assertFalse(self.sdk_adb.is_symlink())
        self.assertEqual(self.sdk_adb.read_text(), "bundled")

    def test_configuration(self):
        self.apply()
        self.assertTrue(self.sdk_adb.is_symlink())
        self.assertEqual(self.sdk_adb.resolve(), self.adb)
        prefs = {p.get("name"): (p.get("type"), p.text) for p in ET.parse(self.prefs).getroot()}
        self.assertEqual(prefs["Unrelated"], ("string", "a2VlcA=="))
        self.assertEqual(prefs["AndroidSdkRoot"], ("string", base64.b64encode(str(self.sdk).encode()).decode()))
        for key in ("SdkUseEmbedded", "AndroidADBKillExternalInstance", "AndroidADBKillServerOnExit"):
            self.assertEqual(prefs[key], ("int", "0"))

    def test_idempotency(self):
        self.apply()
        stamp = self.prefs.stat().st_mtime_ns
        link_stamp = self.sdk_adb.lstat().st_mtime_ns
        self.apply()
        self.assertEqual(self.prefs.stat().st_mtime_ns, stamp)
        self.assertEqual(self.sdk_adb.lstat().st_mtime_ns, link_stamp)

    def test_missing_system_adb(self):
        self.adb.unlink()
        with self.assertRaisesRegex(ValueError, "System adb is missing"):
            self.apply()
        self.assert_unchanged()

    def test_incomplete_sdk(self):
        (self.sdk / "build-tools").rmdir()
        with self.assertRaisesRegex(ValueError, "missing build-tools"):
            self.apply()
        self.assert_unchanged()

    def test_invalid_preferences(self):
        self.prefs.write_text("<unexpected />")
        with self.assertRaisesRegex(ValueError, "Unexpected Unity preferences"):
            self.apply()
        self.assertEqual(self.sdk_adb.read_text(), "bundled")
        self.assertEqual(self.prefs.read_text(), "<unexpected />")

    def test_live_editors_and_failed_detection_refuse_without_changes(self):
        for status in (0, 2):
            with self.subTest(status=status), patch.object(sys, "argv", ["setup", str(self.sdk)]), patch.object(setup.subprocess, "run", return_value=subprocess.CompletedProcess([], status)), patch.object(setup, "configure") as configure:
                with self.assertRaises(SystemExit) as result:
                    setup.main()
                self.assertEqual(result.exception.code, 2)
                configure.assert_not_called()
        self.assert_unchanged()

    def test_cli_uses_linux_preferences_and_system_adb(self):
        with patch.object(sys, "argv", ["setup", str(self.sdk)]), patch.object(setup.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)), patch.object(setup.Path, "home", return_value=self.home), patch.object(setup, "configure") as configure:
            setup.main()
            configure.assert_called_once_with(self.sdk, self.prefs, Path("/usr/bin/adb"))

unittest.main()
PY
  [ "$status" -eq 0 ]
}
