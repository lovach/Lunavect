"""The installed widget is reasserted only for a matching Lunavect copy."""
import contextlib
import importlib.util
import io
import os
import plistlib
import subprocess
import sys
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('reassert', ROOT / 'scripts/reassert-installed-widget.py')
reassert = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reassert)


class ReassertInstalledWidgetTests(unittest.TestCase):
    def test_failed_unregister_accepts_only_confirmed_absence(self):
        app = Path('/tmp/owned-fixture.app')
        for present in [False, True]:
            def run(argv, **kwargs):
                if argv[1] == '-u':
                    raise subprocess.CalledProcessError(1, argv, stderr='failed to scan: -10814')
                self.assertEqual(argv[1], '-dump')
                return subprocess.CompletedProcess(argv, 0, stdout=f'path: {app} (0x1)\n' if present else '')
            if present:
                with self.assertRaises(subprocess.CalledProcessError):
                    reassert.unregister(app, run=run)
            else:
                reassert.unregister(app, run=run)

    def bundle(self, app, host='com.weekleft.app', widget='com.weekleft.app.widget', build='182', widget_build='182'):
        for path, identifier, version in [(app, host, build), (app / 'Contents/PlugIns/LunavectWidget.appex', widget, widget_build)]:
            info = path / 'Contents/Info.plist'
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier, 'CFBundleVersion': version}))

    def run_case(self, **kwargs):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            copies = reassert.installed_copies(home=home, system=home / 'global')
            self.bundle(copies[0], **kwargs)
            calls = []
            restored = reassert.reassert(copies, run=lambda argv, check: calls.append(argv))
            return restored, calls, copies[0]

    def test_matching_installed_copy_is_registered_host_first(self):
        restored, calls, app = self.run_case()
        self.assertEqual(restored, app)
        self.assertEqual(calls, [[reassert.LSREGISTER, '-f', str(app)], ['pluginkit', '-a', str(app / 'Contents/PlugIns/LunavectWidget.appex')]])

    def test_two_installed_copies_without_a_running_one_register_only_the_first(self):
        """Matrix W8 under the current rule (WP-6b): the running copy wins. With
        ~/Applications and /Applications both valid and neither running, only the
        first copy in the documented order (~/Applications) is registered; the
        other is never switched in. The process list is injected, never the host's."""
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary)
            copies = reassert.installed_copies(home=home, system=home / 'global')
            for app in copies:
                self.bundle(app)
            calls = []
            with contextlib.redirect_stderr(io.StringIO()) as warning:
                restored = reassert.reassert(copies, run=lambda argv, check: calls.append(argv), list_processes=lambda: [])
            self.assertIn('neither is running', warning.getvalue())
            self.assertEqual(restored, home / 'Applications/Lunavect.app')
            registered = [argv[-1] for argv in calls]
            self.assertEqual(registered, [str(copies[0]), str(copies[0] / 'Contents/PlugIns/LunavectWidget.appex')])
            self.assertFalse(any(str(copies[1]) in argument for argv in calls for argument in argv))

    def test_foreign_or_mismatched_copies_are_left_alone(self):
        for kwargs in [dict(host='other.app'), dict(widget_build='181'), dict(widget='other.widget')]:
            restored, calls, _ = self.run_case(**kwargs)
            self.assertIsNone(restored, kwargs)
            self.assertEqual(calls, [], kwargs)

    def test_temporary_copy_is_retired_before_installed_host_is_reasserted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            installed, exported = root / 'Applications/Lunavect.app', root / 'export/Lunavect.app'
            self.bundle(installed); self.bundle(exported)
            calls = []
            def run(argv, check):
                self.assertTrue((exported / 'Contents/Info.plist').exists())
                calls.append(argv)
            self.assertEqual(reassert.retire_temporary([exported], [installed], run=run), [exported])
            self.assertEqual(calls, [
                ['pluginkit', '-r', str(exported / 'Contents/PlugIns/LunavectWidget.appex')],
                [reassert.LSREGISTER, '-u', str(exported)],
                [reassert.LSREGISTER, '-f', str(installed)],
                ['pluginkit', '-a', str(installed / 'Contents/PlugIns/LunavectWidget.appex')]])
            self.assertTrue((exported / 'Contents/Info.plist').exists(), 'Cleanup never deletes the packaged source')

    def test_retirement_preserves_installed_aliases_foreign_and_missing_apps(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); installed = root / 'Applications/Lunavect.app'
            alias, foreign, missing = root / 'alias.app', root / 'foreign.app', root / 'missing.app'
            self.bundle(installed); self.bundle(foreign, host='other.app'); alias.symlink_to(installed)
            calls = []
            retired = reassert.retire_temporary([installed, alias, foreign, missing], [installed],
                                                run=lambda argv, check: calls.append(argv))
            self.assertEqual(retired, []); self.assertEqual(calls, [])

    def two_copies(self, root, global_build='182'):
        home, system = root / 'home/Applications/Lunavect.app', root / 'global/Lunavect.app'
        self.bundle(home); self.bundle(system, build=global_build, widget_build=global_build)
        return home, system

    def reassert_quietly(self, copies, running):
        calls, warnings = [], io.StringIO()
        with contextlib.redirect_stderr(warnings):
            restored = reassert.reassert(copies, run=lambda argv, check: calls.append(argv),
                                         list_processes=lambda: running)
        return restored, calls, warnings.getvalue()

    def test_running_copy_is_reasserted_and_the_other_never_registered(self):
        with tempfile.TemporaryDirectory() as temporary:
            home, system = self.two_copies(Path(temporary))
            for running, other in ((system, home), (home, system)):
                with self.subTest(running=running.parent.name):
                    # ps reports the executable path the app was launched from.
                    processes = [(4242, str(running / 'Contents/MacOS/Lunavect')), (7, '/usr/libexec/other')]
                    restored, calls, warning = self.reassert_quietly([home, system], processes)
                    self.assertEqual(restored, running)
                    self.assertEqual(calls, [[reassert.LSREGISTER, '-f', str(running)],
                                             [reassert.PLUGINKIT, '-a', str(running / 'Contents/PlugIns/LunavectWidget.appex')]])
                    self.assertFalse(any(str(other) in arg for argv in calls for arg in argv), calls)
                    self.assertIn(str(home), warning); self.assertIn(str(system), warning)
                    self.assertIn('running copy ' + str(running), warning)

    def test_no_running_copy_falls_back_to_documented_order_with_warning(self):
        with tempfile.TemporaryDirectory() as temporary:
            home, system = self.two_copies(Path(temporary))
            restored, calls, warning = self.reassert_quietly([home, system], [])
            self.assertEqual(restored, home)
            self.assertEqual([argv[-1] for argv in calls], [str(home), str(home / 'Contents/PlugIns/LunavectWidget.appex')])
            self.assertIn('Two Lunavect copies', warning)
            self.assertIn('neither is running', warning)

    def test_running_copy_that_fails_validation_blocks_the_other_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home, system = root / 'home/Applications/Lunavect.app', root / 'global/Lunavect.app'
            self.bundle(home); self.bundle(system, widget_build='181')
            restored, calls, warning = self.reassert_quietly([home, system], [(9, str(system / 'Contents/MacOS/Lunavect'))])
            self.assertIsNone(restored)
            self.assertEqual(calls, [])
            self.assertIn('not reasserting ' + str(home), warning)

    def test_single_copy_is_reasserted_without_warning(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / 'Applications/Lunavect.app'; self.bundle(home)
            restored, calls, warning = self.reassert_quietly([home, Path(temporary) / 'missing/Lunavect.app'], [])
            self.assertEqual(restored, home)
            self.assertEqual(warning, '')

    def test_running_copy_is_matched_through_the_legacy_link_and_exact_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            home, system = self.two_copies(Path(temporary))
            legacy = home.with_name('Weekleft.app'); legacy.symlink_to('Lunavect.app')
            near_misses = [(1, str(system) + '-old/Contents/MacOS/Lunavect'),
                           (2, str(system / 'Contents/PlugIns/LunavectWidget.appex/Contents/MacOS/LunavectWidget')),
                           (3, str(legacy / 'Contents/MacOS/Lunavect'))]
            restored, calls, warning = self.reassert_quietly([home, system], near_misses)
            self.assertEqual(restored, home)
            self.assertIn('running copy ' + str(home), warning)

    def test_process_listing_parses_paths_with_spaces_and_tolerates_ps_failure(self):
        listing = ' 123 /Users/a b/Applications/Lunavect.app/Contents/MacOS/Lunavect\n  9 launchd\n\n'
        run = lambda argv, **kwargs: subprocess.CompletedProcess(argv, 0, stdout=listing)
        self.assertEqual(reassert.list_processes(run=run),
                         [(123, '/Users/a b/Applications/Lunavect.app/Contents/MacOS/Lunavect'), (9, 'launchd')])
        def failing(argv, **kwargs):
            raise OSError('ps unavailable')
        self.assertEqual(reassert.list_processes(run=failing), [])

    def test_tools_and_installed_copies_follow_environment_overrides(self):
        environment = {'LUNAVECT_LSREGISTER': '/fixture/lsregister', 'LUNAVECT_PLUGINKIT': '/fixture/pluginkit'}
        self.assertEqual(reassert.tool_paths(environment), ('/fixture/lsregister', '/fixture/pluginkit'))
        self.assertEqual(reassert.tool_paths({}), (reassert.DEFAULT_LSREGISTER, 'pluginkit'))
        self.assertEqual(reassert.default_installed_copies({}), reassert.installed_copies())
        self.assertEqual(reassert.default_installed_copies({'LUNAVECT_INSTALLED_APPS': ''}), [])
        joined = os.pathsep.join(['/tmp/a b/Lunavect.app', '', '/tmp/c/Lunavect.app'])
        self.assertEqual(reassert.default_installed_copies({'LUNAVECT_INSTALLED_APPS': joined}),
                         [Path('/tmp/a b/Lunavect.app'), Path('/tmp/c/Lunavect.app')])

    def test_command_line_uses_only_injected_tools_and_prefers_running_copy(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home, system = self.two_copies(root)
            bin_dir, trace = root / 'bin', root / 'trace'
            bin_dir.mkdir()
            for name in ('lsregister', 'pluginkit', 'ps'):
                tool = bin_dir / name
                tool.write_text('#!/bin/sh\nprintf "%s %s\\n" "$(basename "$0")" "$*" >> "$FIXTURE_TRACE"\n'
                                'if [ "$(basename "$0")" = ps ]; then printf "  77 %s\\n" "$FIXTURE_RUNNING"; fi\n')
                tool.chmod(0o755)
            environment = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ['PATH'], FIXTURE_TRACE=str(trace),
                               FIXTURE_RUNNING=str(system / 'Contents/MacOS/Lunavect'),
                               LUNAVECT_LSREGISTER=str(bin_dir / 'lsregister'), LUNAVECT_PLUGINKIT=str(bin_dir / 'pluginkit'),
                               LUNAVECT_INSTALLED_APPS=os.pathsep.join([str(home), str(system)]))
            result = subprocess.run([sys.executable, '-B', str(ROOT / 'scripts/reassert-installed-widget.py')],
                                    env=environment, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(trace.read_text().splitlines(), [
                'ps -axo pid=,comm=', 'lsregister -f ' + str(system),
                'pluginkit -a ' + str(system / 'Contents/PlugIns/LunavectWidget.appex')])
            self.assertIn('Two Lunavect copies', result.stderr)

    def test_failed_retirement_still_reasserts_installed_host(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); installed, exported = root / 'installed.app', root / 'exported.app'
            self.bundle(installed); self.bundle(exported); calls = []
            def run(argv, check):
                calls.append(argv)
                if argv[:2] == [reassert.LSREGISTER, '-u']:
                    raise RuntimeError('Synthetic unregister failure')
            with self.assertRaisesRegex(RuntimeError, 'Synthetic'):
                reassert.retire_temporary([exported], [installed], run=run)
            self.assertEqual(calls[-2:], [[reassert.LSREGISTER, '-f', str(installed)],
                              ['pluginkit', '-a', str(installed / 'Contents/PlugIns/LunavectWidget.appex')]])


if __name__ == '__main__':
    unittest.main()
