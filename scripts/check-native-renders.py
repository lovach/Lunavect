#!/usr/bin/env python3
"""Opt-in isolated native fixtures. Never fall back to an unsandboxed render."""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
DIAGNOSTICS: Path | None = None
TEST = "WeekleftUITests.NativeRenderSmokeTests/testRenderSyntheticStates"
LIMIT_LAYOUTS = {
    "limits": (688, 328),
    "limits-small": (328, 328),
    "limits-single-claude": (688, 328),
    "limits-single-claude-small": (328, 328),
    "overview-large": (688, 688),
}
EXPECTED = {
    **{f"{layout}-{state}-{language}-{scheme}.png": dimensions
       for language in ("ru", "de") for scheme in ("light", "dark")
       for layout, dimensions in LIMIT_LAYOUTS.items() for state in ("current", "unknown", "stale-expired")},
    **{f"activity-contour-day-{language}-{scheme}.png": (1240, 1080)
       for language in ("ru", "de") for scheme in ("light", "dark")},
}
LEGACY_EXPECTED = {
    **{f"freshness-{lang}.png": (688, 344) for lang in ('ru', 'de')},
    **{f"{lang}-{width}.png": (width * 2, height * 2) for lang in ('ru', 'de') for width, height in ((340, 700), (580, 450))},
    **{f"contour-day-{lang}-{scheme}.png": (1240, 1080) for lang in ('ru', 'de') for scheme in ('light', 'dark')},
    **{f"icons-{lang}.png": (1168, 1360) for lang in ('ru', 'de')},
}
LEGACY_TESTS = (
    ('WeekleftUITests.LegacyRenderIsolationTests/testPreviewCompositionInsideProvenSandbox', None, ''),
    ('WeekleftUITests.WidgetFreshnessRenderingTests/testRenderStaleClaudeAlongsideFreshCodex', 'LUNAVECT_RENDER_FRESHNESS', 'freshness'),
    ('WeekleftUITests.SettingsRenderingTests/testRenderActivityImportReport', 'LUNAVECT_RENDER_IMPORT_REPORT', ''),
    ('WeekleftUITests.ActivityWidgetRenderingTests/testRenderCleanContourAndSeparateCurrentHour', 'LUNAVECT_RENDER_GAPS', ''),
    ('WeekleftUITests.InterfaceIconRenderingTests/testRenderCompleteControlAlphabet', 'LUNAVECT_RENDER_ICONS', 'icons'),
)
PUBLIC_EXPECTED = {
    "settings-menu-bar.png": (1840, 1520),
    "limits.png": (1840, 1280), "readme-activity.png": (1840, 1960), "menu-bar.png": (1440, 288),
    **{f"readme-overview-{scheme}.png": (1568, 806) for scheme in ('light', 'dark')},
    **{f"readme-sessions-{scheme}.png": (784, 774) for scheme in ('light', 'dark')},
    "widget-overview.png": (688, 688), "widget-activity-large.png": (688, 688),
    "widget-activity-small.png": (328, 328), "widget-limits.png": (688, 328),
}
PUBLIC_TESTS = (('WeekleftUITests.ReleaseScreenshots/testRenderPublicScreenshots', 'LUNAVECT_RELEASE_SCREENSHOTS', ''),)

PROBE_LABELS = ("forbidden-file-read", "forbidden-file-write", "child-process-fork", "child-process-exec",
                "network-connect", "com.apple.cfprefsd.agent", "com.apple.cfprefsd.daemon",
                "preferences-canary-read", "preferences-persistent-write")


def probe_checks(stdout: str) -> list[str]:
    allowed = {f"{label}: {status}" for label in PROBE_LABELS for status in ("passed", "failed")}
    return [line for line in stdout.splitlines() if line in allowed]


def one_test_passed(stdout: str) -> bool:
    counts = re.findall(r'Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?', stdout)
    return bool(counts) and all(int(total) == 1 and int(skips or '0') == 0 and int(failures) == 0
                                for total, skips, failures in counts)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def png_dimensions(path: Path) -> tuple[int, int]:
    with path.open("rb") as stream:
        header = stream.read(24)
    if len(header) != 24 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError(f"Invalid PNG: {path.name}")
    return struct.unpack(">II", header[16:24])


def inspect_images(directory: Path, expected: dict | None = None) -> list[dict]:
    expected = EXPECTED if expected is None else expected
    names = {path.name for path in directory.iterdir()}
    if names != set(expected):
        raise ValueError(f"Render output does not contain exactly the {len(expected)} selected states")
    result = []
    for name, expected_size in sorted(expected.items()):
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Render output must be a regular file: {name}")
        size = png_dimensions(path)
        if size != expected_size:
            raise ValueError(f"Unexpected PNG dimensions: {name}")
        result.append({"path": f"images/{name}", "sha256": sha256(path), "width": size[0], "height": size[1], "status": "passed"})
    return result


def sandbox_profile(*, xcode: Path, products: Path, probe: Path, xctest: Path, runtime: Path, images: Path) -> str:
    # JSON quoting is also valid for these Scheme string literals; paths are not shell code.
    quote = lambda path: json.dumps(str(path.resolve()))
    reads = [Path("/System"), Path("/usr/lib"), Path("/usr/share"), Path("/Library/Apple/System/Library"),
             Path("/private/var/db/dyld"), Path("/private/var/db/timezone"),
             xcode, products, runtime, images]
    return "\n".join([
        "(version 1)", "(deny default)",
        "(allow sysctl-read)", "(allow file-read-metadata)",
        *(f"(allow file-read* file-map-executable (subpath {quote(path)}))" for path in reads),
        '(allow file-read* (literal "/") (literal "/dev/null") (literal "/dev/urandom") (literal "/dev/random") (literal "/private/etc/localtime"))',
        '(allow file-write* (literal "/dev/null"))',
        f"(allow file-read* file-map-executable (literal {quote(probe)}))",
        f"(allow process-exec (literal {quote(probe)}) (literal {quote(xctest)}))",
        f"(allow file-write* (subpath {quote(images)}) (subpath {quote(runtime / 'tmp')}))",
        # No process-fork, network, cfprefsd, securityd, user directories or preference writes.
        # ImageRenderer may use system fonts. These services cannot access app/account preferences.
        '(allow mach-lookup (global-name "com.apple.FontObjectsServer") (global-name "com.apple.fonts"))',
        "",
    ])


def child_environment(runtime: Path) -> dict[str, str]:
    # Deliberately avoid inheriting tokens, client paths, opt-in tests and DYLD overrides.
    # HOME / CODEX_HOME are neither reassigned nor passed to the render process.
    return {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
        "TZ": "UTC", "TMPDIR": str(runtime / "tmp"), "CFFIXED_USER_HOME": str(runtime / "home"),
    }


def run(command: list[str], *, cwd: Path, env: dict | None = None, timeout: int = 900) -> subprocess.CompletedProcess:
    # Raw diagnostics stay under ignored .build, outside uploaded artifacts.
    try:
        result = subprocess.run(command, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as error:
        if DIAGNOSTICS is not None:
            stdout = error.stdout or b""
            (DIAGNOSTICS / (uuid.uuid4().hex + "-timeout.log")).write_bytes(stdout.encode() if isinstance(stdout, str) else stdout)
        raise
    if DIAGNOSTICS is not None:
        (DIAGNOSTICS / (uuid.uuid4().hex + ".log")).write_text(result.stdout)
    return result


def compare_baseline(output: Path, baseline: Path, images: list[dict], environment: dict) -> dict:
    report = json.loads((baseline / "render-report.json").read_text())
    if report.get("render", {}).get("status") != "passed":
        raise ValueError("Baseline must come from a passed isolated render")
    if report.get("environment") != environment:
        return {"status": "skipped", "reason": "Baseline OS/toolchain/fixture environment differs; compare visually before approving a new baseline"}
    prior = inspect_images(baseline / "images", LEGACY_EXPECTED if environment.get('suite') == 'legacy-values' else PUBLIC_EXPECTED if environment.get('suite') == 'public-gallery' else EXPECTED)
    prior_hashes = {item["path"]: item["sha256"] for item in prior}
    changed = [item["path"] for item in images if item["sha256"] != prior_hashes[item["path"]]]
    (output / "baseline").mkdir()
    for item in prior:
        shutil.copyfile(baseline / item["path"], output / "baseline" / Path(item["path"]).name)
    return {"status": "passed" if not changed else "failed", "method": "exact PNG SHA-256 comparison; changes require visual review",
            "changed": changed, "reason": "No differences" if not changed else "PNG bytes changed; inspect side-by-side gallery"}


def write_report(output: Path, report: dict) -> None:
    (output / "render-report.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    rows = ["# Isolated native render check", "", "Synthetic fixtures only; no live accounts, system widget placement or accessibility interaction verified.", ""]
    for key in ("build", "isolation", "render", "comparison", "provenance", "visual_review"):
        item = report[key]
        rows.append(f"- **{key}: {item['status']}** — {item.get('reason', '')}")
    scope = "Legacy value views: stale allowances, import reports at two widths, contour gaps and control icon alphabet." if report['environment'].get('suite') == 'legacy-values' else "Current/unknown/stale-expired limits in small and medium cards with two providers or Claude alone, plus large overview; clean contour with known zero, unknown gaps and current incomplete hour."
    if report['environment'].get('suite') == 'public-gallery':
        scope = "Current production sessions, limits, statistics, menu-bar indicators and widgets; one fictional dataset. Offscreen AppKit windows are never ordered on screen."
    languages = "/".join(report['environment']['languages']).upper()
    clock_note = "Capture-time fixture; Gregorian calendar; native 2x pixels." if report['environment'].get('suite') == 'public-gallery' else "Fixed clock: 2026-09-12 09:56 UTC; Gregorian calendar; 2× pixels; animations disabled by transaction."
    rows.extend(["", "Fixtures: " + languages + ". " + scope,
                 clock_note + " Read-only accessibility values are observed and recorded in render-report.json.",
                 "PNG hashes identify outputs. They are not a promise of reproducible bytes across OS/toolchain versions.", ""])
    (output / "summary.md").write_text("\n".join(rows))
    cards = []
    for item in report.get("files", []):
        path = item["path"]
        name = Path(path).name
        baseline = output / "baseline" / name
        previous = f'<div><p>Baseline</p><img src="baseline/{html.escape(name)}" alt="Baseline {html.escape(name)}"></div>' if baseline.exists() else ""
        cards.append(f'<section><h2>{html.escape(name)}</h2><div class="pair">{previous}<div><p>Current · {item["width"]} × {item["height"]}</p><img src="{html.escape(path)}" alt="{html.escape(name)}"></div></div></section>')
    (output / "gallery.html").write_text("<!doctype html><meta charset=utf-8><title>Lunavect synthetic native renders</title>"
        "<style>body{font:15px system-ui;margin:28px;background:#e7e7e7;color:#202020}section{margin:32px 0}h2{font-size:16px}"
        ".pair{display:flex;gap:20px;flex-wrap:wrap}img{max-width:620px;width:100%;height:auto;border:1px solid #aaa}p{margin:8px 0}</style>"
        "<h1>Synthetic native renders</h1><p>Visual review is manual. Open summary.md for passed/skipped/not-run evidence.</p>" + "".join(cards))


def initial_report() -> dict:
    return {"schema_version": 1, "fixture_version": 1, "files": [],
              "environment": {"macos": platform.mac_ver()[0], "architecture": platform.machine(), "clock": "2026-09-12T09:56:00Z",
                              "scale": 2, "languages": ["ru", "de"], "calendar": "gregorian", "time_zone": "UTC"},
              "build": {"status": "not-run"}, "isolation": {"status": "not-run"},
              "provenance": {"status": "not-run"},
              "render": {"status": "not-run", "reason": "Opt-in: pass --run"},
              "comparison": {"status": "not-run", "reason": "No baseline supplied"},
              "visual_review": {"status": "not-run", "reason": "Human review required; opening a gallery is not approval"}}


def check(output: Path, *, enabled: bool, baseline: Path | None = None, report: dict | None = None, suite: str = 'smoke') -> dict:
    if report is None:
        report = initial_report()
    report['environment']['suite'] = suite
    if suite == 'public-gallery':
        report['environment']['languages'] = ['en']
        report['environment']['clock'] = 'capture-time; one shared fixture'
        report['environment']['renderer'] = 'AppKit offscreen, native 2x bitmap'
    if not enabled:
        return report
    report["render"] = {"status": "skipped", "reason": "Prerequisites have not passed; no renderer launched"}
    if platform.system() != "Darwin" or not Path("/usr/bin/sandbox-exec").is_file():
        report["render"]["reason"] = "macOS sandbox-exec is unavailable; no unsandboxed fallback"
        report["isolation"] = {"status": "skipped", "reason": "Required sandbox unavailable"}
        return report
    scratch = ROOT / ".build" / "native-render-check"
    with tempfile.TemporaryDirectory(prefix="lunavect-native-render-") as temporary:
        temp = Path(temporary).resolve()
        runtime = temp / "runtime"
        (runtime / "tmp").mkdir(parents=True)
        (runtime / "home").mkdir()
        forbidden = temp / "forbidden"
        (forbidden / "Library" / "Preferences").mkdir(parents=True)
        sentinel = forbidden / "synthetic-sentinel.txt"
        sentinel.write_text("synthetic forbidden canary\n")
        sentinel_hash = sha256(sentinel)
        domain = "org.lunavect.native-render-probe." + uuid.uuid4().hex
        preference_file = forbidden / "Library" / "Preferences" / (domain + ".plist")
        preference_file.write_bytes(plistlib.dumps({"canary": "synthetic forbidden preference"}))
        preference_hash = sha256(preference_file)
        images = output / "images"
        images.mkdir()
        xcode_result = run(["/usr/bin/xcode-select", "-p"], cwd=ROOT)
        if xcode_result.returncode != 0:
            report["build"] = {"status": "failed", "reason": "xcode-select did not locate the required toolchain"}
            return report
        xcode = Path(xcode_result.stdout.strip()).resolve()
        toolchain = run(["/usr/bin/xcrun", "swift", "--version"], cwd=ROOT)
        version = re.search(r"Apple Swift version ([0-9.]+) \(swiftlang-([0-9.]+) clang-([0-9.]+)\)", toolchain.stdout)
        report["environment"]["swift"] = {"version": version[1], "swiftlang": version[2], "clang": version[3]} if version else {"version": "unavailable"}
        xctest_result = run(["/usr/bin/xcrun", "--find", "xctest"], cwd=ROOT)
        if xctest_result.returncode != 0:
            report["build"] = {"status": "failed", "reason": "XCTest runner unavailable"}
            return report
        xctest = Path(xctest_result.stdout.strip()).resolve()
        probe = temp / "sandbox-probe"
        report["_active_stage"] = "isolation"
        compiled = run(["/usr/bin/xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-framework", "CoreFoundation",
                        str(ROOT / "Tests/Scripts/native_render_sandbox_probe.c"), "-o", str(probe)], cwd=ROOT)
        if compiled.returncode != 0:
            report["isolation"] = {"status": "failed", "reason": "Sandbox probe could not compile"}
            report["render"]["reason"] = "Isolation unproven; no renderer launched"
            return report
        profile = temp / "render.sb"
        profile.write_text(sandbox_profile(xcode=xcode, products=scratch, probe=probe, xctest=xctest, runtime=runtime, images=images))
        env = child_environment(runtime)
        probe_env = {**env, "CFFIXED_USER_HOME": str(forbidden)}
        preflight = run(["/usr/bin/sandbox-exec", "-f", str(profile), str(probe), str(sentinel), domain], cwd=runtime, env=probe_env, timeout=60)
        unchanged = sha256(sentinel) == sentinel_hash and sha256(preference_file) == preference_hash
        checks = probe_checks(preflight.stdout)
        if preflight.returncode != 0 or not unchanged or set(checks) != {f"{label}: passed" for label in PROBE_LABELS}:
            # Store only the fixed probe labels, never general stderr or filesystem paths.
            report["isolation"] = {"status": "failed", "reason": "Sandbox preflight failed or could not execute; no renderer launched", "checks": checks}
            report["render"]["reason"] = "Isolation unproven; no renderer launched"
            return report
        report["isolation"] = {"status": "passed", "reason": "Synthetic file/preference read and writes, cfprefsd, process fork/exec and network denied; sentinels unchanged",
                               "checks": checks}
        print("Isolation preflight: passed. Building only the test products (--jobs 2).", flush=True)
        report["_active_stage"] = "build"
        built = run(["/usr/bin/xcrun", "swift", "build", "--build-tests", "--jobs", "2", "--scratch-path", str(scratch)], cwd=ROOT)
        if built.returncode != 0:
            report["build"] = {"status": "failed", "reason": "Swift test products did not build"}
            report["render"]["reason"] = "Build failed; no renderer launched"
            return report
        report["build"] = {"status": "passed", "reason": "Debug Swift test products built with --jobs 2; no signing/install"}
        report["_active_stage"] = "render"
        bin_result = run(["/usr/bin/xcrun", "swift", "build", "--show-bin-path", "--scratch-path", str(scratch)], cwd=ROOT)
        bundle = Path(bin_result.stdout.strip()) / "WeekleftPackageTests.xctest"
        if bin_result.returncode != 0 or not bundle.is_dir():
            report["render"] = {"status": "failed", "reason": "Built XCTest bundle not found"}
            return report
        for language in (("en",) if suite == "public-gallery" else ("ru", "de")):
            observed_environment = runtime / "tmp" / f"environment-{language}.json"
            render_env = {**env, "LUNAVECT_NATIVE_RENDER_ISOLATION": "passed", "LUNAVECT_PREVIEW_LANGUAGE": language,
                          "LUNAVECT_NATIVE_RENDER_OUTPUT": str(images), "LUNAVECT_NATIVE_RENDER_FORBIDDEN": str(sentinel),
                          "LUNAVECT_NATIVE_RENDER_ENVIRONMENT": str(observed_environment)}
            selected = ((TEST, None, ''),) if suite == 'smoke' else PUBLIC_TESTS if suite == 'public-gallery' else LEGACY_TESTS
            for test, flag, prefix in selected:
                test_env = dict(render_env)
                if flag:
                    test_env[flag] = str(images / prefix) if prefix else str(images)
                rendered = run(["/usr/bin/sandbox-exec", "-f", str(profile), str(xctest), "-XCTest", test, str(bundle)],
                               cwd=runtime, env=test_env, timeout=120)
                if rendered.returncode != 0 or not one_test_passed(rendered.stdout):
                    report["render"] = {"status": "failed", "reason": f"Isolated {language} renderer failed; sandbox was not relaxed"}
                    return report
            observed = json.loads(observed_environment.read_text())
            if (set(observed) != {"contrast", "reduce_motion", "reduce_transparency"}
                    or observed["contrast"] not in ("standard", "increased")
                    or any(observed[key] not in ("true", "false") for key in ("reduce_motion", "reduce_transparency"))):
                raise ValueError("Unexpected observed accessibility environment")
            if report["environment"].get("accessibility", observed) != observed:
                raise ValueError("Accessibility environment changed between language renders")
            report["environment"]["accessibility"] = observed
        report["files"] = inspect_images(images, EXPECTED if suite == 'smoke' else PUBLIC_EXPECTED if suite == 'public-gallery' else LEGACY_EXPECTED)
        report["render"] = {"status": "passed", "reason": f"{len(report['files'])} isolated synthetic PNGs generated with expected dimensions"}
        if baseline:
            report["_active_stage"] = "comparison"
            report["comparison"] = compare_baseline(output, baseline, report["files"], report["environment"])
    return report


def main() -> int:
    global DIAGNOSTICS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="Explicitly opt in to the isolated render")
    parser.add_argument("--suite", choices=('smoke', 'legacy-values', 'public-gallery'), default='smoke', help='Only explicitly audited test methods are callable')
    parser.add_argument("--require-render", action="store_true", help="Fail when render is skipped or fails (recommended in the opt-in CI job)")
    parser.add_argument("--output", type=Path, required=True, help="New output directory; an existing directory is never reused")
    parser.add_argument("--baseline", type=Path, help="Previous passed output from the same OS/toolchain; byte differences fail for manual review")
    args = parser.parse_args()
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        output.mkdir()  # Exclusive ownership also prevents concurrent report overwrites.
    except FileExistsError:
        parser.error("--output must be a new directory")
    report = initial_report()
    lock = None
    try:
        if args.run:
            # Keep incremental products, but reject competing writers in this checkout.
            lock_path = ROOT / ".build" / "native-render-check.lock"
            lock_path.parent.mkdir(parents=True, exist_ok=True)
            lock = lock_path.open("w")
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            DIAGNOSTICS = ROOT / ".build" / "native-render-check" / "diagnostics" / uuid.uuid4().hex
            DIAGNOSTICS.mkdir(parents=True)
            report["diagnostics"] = {"path": DIAGNOSTICS.relative_to(ROOT).as_posix(), "uploaded": False}
            report["_active_stage"] = "provenance"
            began = run([sys.executable, str(ROOT / "scripts/build-manifest.py"), "begin", "--source-root", str(ROOT),
                         "--output", str(output / "build-manifest.json"), "--kind", "native-render"], cwd=ROOT)
            if began.returncode != 0:
                raise ValueError("Source provenance checkpoint failed")
            report.pop("_active_stage", None)
        check(output, enabled=args.run, baseline=args.baseline.resolve() if args.baseline else None, report=report, suite=args.suite)
    except BlockingIOError:
        report["render"] = {"status": "skipped", "reason": "Another native render owns this checkout's build directory; no shared products changed"}
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        stage = report.get("_active_stage", "render")
        report[stage] = {"status": "failed", "reason": f"{stage} did not complete ({type(error).__name__}); diagnostics are not uploaded"}
    finally:
        report.pop("_active_stage", None)
        manifest = output / "build-manifest.json"
        if manifest.is_file():
            try:
                command = [sys.executable, str(ROOT / "scripts/build-manifest.py"), "finalize", "--source-root", str(ROOT), "--manifest", str(manifest)]
                if (output / "images").is_dir():
                    command += ["--artifact", f"renders={output / 'images'}"]
                finalized = run(command, cwd=ROOT)
                report["provenance"] = {"status": "passed" if finalized.returncode == 0 else "failed",
                                        "reason": "Source checkpoint and output hashes recorded; see build-manifest.json" if finalized.returncode == 0 else "Source changed during the run or artifact hashing failed"}
            except (ValueError, OSError, subprocess.SubprocessError) as error:
                report["provenance"] = {"status": "failed", "reason": f"Provenance finalization did not complete ({type(error).__name__})"}
        if lock is not None:
            lock.close()
        DIAGNOSTICS = None
    write_report(output, report)
    print("; ".join(f"{key}: {report[key]['status']}" for key in ("build", "isolation", "render", "comparison", "provenance", "visual_review")))
    return int(any(report[key]["status"] == "failed" for key in ("build", "isolation", "render", "comparison", "provenance"))
               or (args.require_render and report["render"]["status"] != "passed"))


if __name__ == "__main__":
    raise SystemExit(main())
