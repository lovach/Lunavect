#!/usr/bin/env python3
"""Reproduce extra audit fixtures through the unchanged strict sandbox runner.

Usage: python3 docs/audits/2026-09-27/render-extra.py --run --require-render --output /new/private/directory
No real clients, preferences, credentials, network or installed widgets are used.
"""
import importlib.util
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('native_render', ROOT / 'scripts/check-native-renders.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)
runner.LEGACY_TESTS = (
    ('WeekleftUITests.ConnectionSetupRenderingTests/testRenderLocalRecoveryStatesWithoutClients', 'LUNAVECT_RENDER_LOCAL_RECOVERY', ''),
    ('WeekleftUITests.ActivityAccessibilityTests/testRenderLongActivityLabels', 'LUNAVECT_RENDER_ACTIVITY_ACCESSIBILITY', ''),
)
runner.LEGACY_EXPECTED = {
    **{f'{name}-{language}.png': (1040, 300)
       for language in ('ru', 'de')
       for name in ('partial-connect', 'partial-disconnect', 'unreadable', 'missing-hud-backup')},
    **{f'selected-codex-path-{language}.png': (1200, 360) for language in ('ru', 'de')},
    **{f'{name}-{language}-{scheme}.png': size
       for language in ('ru', 'de') for scheme in ('light', 'dark')
       for name, size in (('activity-unknown-point', (520, 570)), ('activity-long-projects', (640, 540)))},
}
original_report = runner.write_report

def write_report(output, report):
    report['environment']['suite'] = 'audit-extra-recovery-and-long-labels'
    report['environment']['scale'] = {'recovery': 2, 'activity': 1}
    report['audit_tests'] = [test for test, _, _ in runner.LEGACY_TESTS]
    original_report(output, report)
    (output / 'summary.md').write_text(
        '# Audit edge-state renders\n\n'
        'Partial connect/disconnect, unreadable settings, missing previous HUD backup, unavailable selected Codex path; '
        'unknown chart point and long multilingual project/session names. Russian/German; activity in light/dark.\n\n'
        + '\n'.join(f"- {key}: {report[key]['status']}" for key in ('build', 'isolation', 'render', 'provenance', 'visual_review'))
        + '\n\nSynthetic fixtures only; rendering does not prove VoiceOver interaction or live connection recovery.\n')

runner.write_report = write_report
if '--suite' in sys.argv or '--baseline' in sys.argv:
    raise SystemExit('This audit wrapper accepts only its fixed extra fixture suite, without baseline comparison.')
sys.argv += ['--suite', 'legacy-values']
raise SystemExit(runner.main())
