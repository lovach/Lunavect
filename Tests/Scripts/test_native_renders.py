"""File fixtures only: this suite never starts SwiftUI or changes user preferences."""
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zlib

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/check-native-renders.py"
SPEC = importlib.util.spec_from_file_location("native_renders", SCRIPT)
renders = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(renders)


def png(path, size, value=0):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    width, height = size
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
                     + chunk(b"IDAT", zlib.compress((b"\x00" + bytes([value]) * width) * height)) + chunk(b"IEND", b""))


def fixture(directory):
    images = directory / "images"
    images.mkdir()
    for name, size in renders.EXPECTED.items():
        png(images / name, size)
    return renders.inspect_images(images)


class NativeRendersTests(unittest.TestCase):
    def test_selected_method_must_really_pass_once_without_skips(self):
        self.assertTrue(renders.one_test_passed('Executed 1 test, with 0 failures (0 unexpected)'))
        for output in ['', 'Executed 0 tests, with 0 failures',
                       'Executed 1 test, with 1 test skipped and 0 failures',
                       'Executed 1 test, with 1 failure', 'Executed 2 tests, with 0 failures']:
            self.assertFalse(renders.one_test_passed(output))

    def test_legacy_matrix_is_independent_and_rejects_missing_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            images = Path(temporary)
            for name, dimensions in renders.LEGACY_EXPECTED.items():
                png(images / name, dimensions)
            records = renders.inspect_images(images, renders.LEGACY_EXPECTED)
            self.assertEqual(len(records), 12)
            self.assertTrue(any('freshness' in item['path'] for item in records))
            (images / next(iter(renders.LEGACY_EXPECTED))).unlink()
            with self.assertRaisesRegex(ValueError, '12 selected states'):
                renders.inspect_images(images, renders.LEGACY_EXPECTED)

    def test_default_is_opt_in_and_does_not_launch_any_process(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(renders, "run", side_effect=AssertionError("process launched")):
            output = Path(temporary)
            report = renders.check(output, enabled=False)
            self.assertEqual(report["render"]["status"], "not-run")
            self.assertEqual(report["isolation"]["status"], "not-run")
            renders.write_report(output, report)
            self.assertEqual(json.loads((output / "render-report.json").read_text()), report)
            self.assertTrue((output / "gallery.html").is_file())

    def test_unavailable_sandbox_never_falls_back(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(renders.platform, "system", return_value="Linux"), \
                patch.object(renders, "run", side_effect=AssertionError("process launched")):
            report = renders.check(Path(temporary), enabled=True)
            self.assertEqual(report["isolation"]["status"], "skipped")
            self.assertEqual(report["render"]["status"], "skipped")

    def test_failed_probe_prevents_test_build_and_renderer(self):
        commands = []
        def fake_run(command, **kwargs):
            commands.append(command)
            if command[:2] == ["/usr/bin/xcode-select", "-p"]:
                return subprocess.CompletedProcess(command, 0, "/Applications/Xcode.app/Contents/Developer\n")
            if command[1:3] == ["--find", "xctest"]:
                return subprocess.CompletedProcess(command, 0, "/Applications/Xcode.app/Contents/Developer/usr/bin/xctest\n")
            if command[0] == "/usr/bin/sandbox-exec":
                return subprocess.CompletedProcess(command, 1, "forbidden-file-read: failed\nprivate diagnostic must not be published\n")
            self.assertNotIn("build", command)
            return subprocess.CompletedProcess(command, 0, "Synthetic toolchain")
        with tempfile.TemporaryDirectory() as temporary, patch.object(renders.platform, "system", return_value="Darwin"), \
                patch.object(renders.Path, "is_file", return_value=True), patch.object(renders, "run", side_effect=fake_run):
            report = renders.check(Path(temporary), enabled=True)
        self.assertEqual(report["isolation"]["status"], "failed")
        self.assertEqual(report["render"]["status"], "skipped")
        self.assertEqual(report["build"]["status"], "not-run")
        self.assertEqual(report["isolation"]["checks"], ["forbidden-file-read: failed"])
        self.assertFalse(any("-XCTest" in command for command in commands))

    def test_expected_64_outputs_have_hashes_and_dimensions(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            images = fixture(output)
            self.assertEqual(len(images), 64)
            self.assertTrue(all(len(image["sha256"]) == 64 for image in images))
            (output / "images" / "unexpected.txt").write_text("extra")
            with self.assertRaisesRegex(ValueError, "exactly the 64"):
                renders.inspect_images(output / "images")

    def test_added_layouts_require_every_state_and_their_native_dimensions(self):
        for layout, dimensions in (("limits-small", (328, 328)),
                                   ("limits-single-claude", (688, 328)),
                                   ("limits-single-claude-small", (328, 328)),
                                   ("overview-large", (688, 688))):
            with self.subTest(layout=layout), tempfile.TemporaryDirectory() as temporary:
                output = Path(temporary)
                images = fixture(output)
                names = {f"{layout}-{state}-{language}-{scheme}.png"
                         for state in ("current", "unknown", "stale-expired")
                         for language in ("ru", "de") for scheme in ("light", "dark")}
                matching = [image for image in images if Path(image["path"]).name in names]
                self.assertEqual(len(matching), 12)
                self.assertEqual({(image["width"], image["height"]) for image in matching}, {dimensions})
                self.assertTrue(names.issubset(renders.EXPECTED))
                target = output / "images" / f"{layout}-unknown-de-dark.png"
                target.unlink()
                with self.assertRaisesRegex(ValueError, "exactly the 64"):
                    renders.inspect_images(output / "images")
                png(target, (688, 344))
                with self.assertRaisesRegex(ValueError, "dimensions"):
                    renders.inspect_images(output / "images")

    def test_wrong_dimensions_or_symlinks_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            fixture(output)
            name = next(iter(renders.EXPECTED))
            target = output / "images" / name
            png(target, (1, 1))
            with self.assertRaisesRegex(ValueError, "dimensions"):
                renders.inspect_images(output / "images")
            target.unlink()
            target.symlink_to(output / "sentinel.png")
            with self.assertRaisesRegex(ValueError, "regular file"):
                renders.inspect_images(output / "images")

    def test_changed_baseline_is_visible_and_fails_comparison(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            current, baseline = root / "current", root / "baseline"
            current.mkdir(); baseline.mkdir()
            fixture(baseline)
            fixture(current)
            environment = {"macos": "fixture"}
            (baseline / "render-report.json").write_text(json.dumps({"render": {"status": "passed"}, "environment": environment}))
            name, size = next(iter(renders.EXPECTED.items()))
            png(current / "images" / name, size, value=40)
            result = renders.compare_baseline(current, baseline, renders.inspect_images(current / "images"), environment)
            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["changed"], [f"images/{name}"])
            self.assertTrue((current / "baseline" / name).is_file())

    def test_baseline_environment_mismatch_is_skipped(self):
        with tempfile.TemporaryDirectory() as temporary:
            baseline = Path(temporary)
            (baseline / "render-report.json").write_text(json.dumps({"render": {"status": "passed"}, "environment": {"macos": "old"}}))
            result = renders.compare_baseline(baseline, baseline, [], {"macos": "new"})
            self.assertEqual(result["status"], "skipped")

    def test_child_environment_does_not_inherit_credentials_or_opt_ins(self):
        with patch.dict(renders.os.environ, {"CODEX_HOME": "/secret", "HOME": "/real-user", "TOKEN": "secret", "LUNAVECT_RELEASE_SCREENSHOTS": "/outside"}):
            environment = renders.child_environment(Path("/synthetic/runtime"))
        self.assertNotIn("CODEX_HOME", environment)
        self.assertNotIn("HOME", environment)
        self.assertNotIn("TOKEN", environment)
        self.assertNotIn("LUNAVECT_RELEASE_SCREENSHOTS", environment)
        self.assertEqual(environment["CFFIXED_USER_HOME"], "/synthetic/runtime/home")

    def test_probe_diagnostics_are_allowlisted_on_success_and_failure(self):
        result = renders.probe_checks("forbidden-file-read: passed\n/Users/private/path: failed\npreferences-persistent-write: failed\n")
        self.assertEqual(result, ["forbidden-file-read: passed", "preferences-persistent-write: failed"])

    def test_provenance_failure_is_visible_in_summary(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            report = renders.initial_report()
            report["provenance"] = {"status": "failed", "reason": "Source changed"}
            renders.write_report(output, report)
            self.assertIn("**provenance: failed**", (output / "summary.md").read_text())

    def test_timeout_preserves_failure_report(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary) / "new-output"
            with patch.object(renders.sys, "argv", [str(SCRIPT), "--output", str(output)]), \
                    patch.object(renders, "check", side_effect=subprocess.TimeoutExpired("synthetic", 1)):
                self.assertEqual(renders.main(), 1)
            self.assertEqual(json.loads((output / "render-report.json").read_text())["render"]["status"], "failed")

    def test_busy_checkout_preserves_existing_build_products(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            products = root / ".build" / "native-render-check"
            products.mkdir(parents=True)
            sentinel = products / "owner"
            sentinel.write_text("keep")
            with (root / ".build" / "native-render-check.lock").open("w") as owner:
                renders.fcntl.flock(owner, renders.fcntl.LOCK_EX | renders.fcntl.LOCK_NB)
                output = root / "new-output"
                with patch.object(renders, "ROOT", root), patch.object(renders.sys, "argv", [str(SCRIPT), "--run", "--require-render", "--output", str(output)]), \
                        patch.object(renders, "run", side_effect=AssertionError("process launched")):
                    self.assertEqual(renders.main(), 1)
                self.assertEqual(json.loads((output / "render-report.json").read_text())["render"]["status"], "skipped")
            self.assertEqual(sentinel.read_text(), "keep")

    def test_existing_output_is_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            sentinel = output / "owner.txt"
            sentinel.write_text("keep")
            result = subprocess.run(["python3", str(SCRIPT), "--output", str(output)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(), "keep")


if __name__ == "__main__":
    unittest.main()
