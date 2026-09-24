import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('product_resources', ROOT / 'scripts/verify-product-resources.py')
RESOURCES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RESOURCES)


class ProductResourceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.app = Path(self.temporary.name) / 'Lunavect.app'
        self.widget = self.app / 'Contents/PlugIns/LunavectWidget.appex'
        self.info = dict(CFBundleName='Lunavect', CFBundleDisplayName='Lunavect',
                         CFBundleVersion='108', CFBundleShortVersionString='0.1.1',
                         CFBundleIconFile='LunavectTide', WeekleftAppGroup='test.shared',
                         CFBundleLocalizations=['ru', 'en'])
        for bundle in (self.app, self.widget):
            resources = bundle / 'Contents/Resources'
            resources.mkdir(parents=True)
            (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(self.info))
            for name in RESOURCES.SHARED | (RESOURCES.APP_ONLY if bundle == self.app else set()):
                shutil.copyfile(RESOURCES.resource_source(ROOT, name), resources / name)
            for language in self.info['CFBundleLocalizations']:
                localized = resources / (language + '.lproj')
                localized.mkdir()
                shutil.copyfile(ROOT / 'Sources/LunavectWidget/Resources' / (language + '.lproj') / 'Localizable.strings', localized / 'Localizable.strings')
            self.metadata(bundle, RESOURCES.WIDGET_INTENTS if bundle == self.widget else RESOURCES.APP_INTENTS)

    def metadata(self, bundle, actions, enums=('ActivityPeriod', 'ActivitySource')):
        path = bundle / 'Contents/Resources/Metadata.appintents/extract.actionsdata'
        path.parent.mkdir(exist_ok=True)
        path.write_text(json.dumps({'actions': {name: {} for name in actions},
                                    'enums': [{'identifier': name} for name in enums]}))

    def test_missing_or_incomplete_intent_metadata_is_rejected(self):
        # Edit Widget and the interactive chart need the extracted metadata in both bundles.
        for bundle in (self.app, self.widget):
            path = bundle / 'Contents/Resources/Metadata.appintents/extract.actionsdata'
            content = path.read_bytes(); path.unlink()
            with self.subTest(bundle=bundle.name), self.assertRaisesRegex(ValueError, 'missing App Intents metadata'):
                RESOURCES.verify(self.app)
            path.write_bytes(content)
        for actions, enums in (({'SelectActivityPointIntent'}, ('ActivityPeriod', 'ActivitySource')),
                               (RESOURCES.WIDGET_INTENTS, ('ActivityPeriod',))):
            self.metadata(self.widget, actions, enums)
            with self.assertRaisesRegex(ValueError, 'lacks the activity intents'):
                RESOURCES.verify(self.app)

    def test_missing_any_consumed_asset_is_rejected(self):
        for bundle, resources in ((self.app, RESOURCES.SHARED | RESOURCES.APP_ONLY), (self.widget, RESOURCES.SHARED)):
            for name in resources:
                path = bundle / 'Contents/Resources' / name
                content = path.read_bytes(); path.unlink()
                with self.subTest(bundle=bundle.name, resource=name), self.assertRaises((OSError, ValueError)):
                    RESOURCES.verify(self.app)
                path.write_bytes(content)

    def test_widget_does_not_ship_app_animations_or_interface_marks(self):
        path = self.widget / 'Contents/Resources/clawd-walking.gif'
        shutil.copyfile(RESOURCES.resource_source(ROOT, path.name), path)
        with self.assertRaisesRegex(ValueError, 'outside bundle allowlist'):
            RESOURCES.verify(self.app)

    def test_stale_app_only_resource_is_rejected_against_source(self):
        path = self.app / 'Contents/Resources/clawd-laptop.json'
        path.write_text('{}')
        with self.assertRaisesRegex(ValueError, 'clawd-laptop.json is stale'):
            RESOURCES.verify(self.app, ROOT)

    def test_missing_intent_localization_is_rejected(self):
        (self.widget / 'Contents/Resources/en.lproj/Localizable.strings').unlink()
        with self.assertRaisesRegex(ValueError, 'missing en intent localization'):
            RESOURCES.verify(self.app)

    def test_matching_app_and_extension(self):
        self.assertEqual(RESOURCES.verify(self.app), '108')

    def test_stale_widget_version_is_rejected(self):
        (self.widget / 'Contents/Info.plist').write_bytes(plistlib.dumps({**self.info, 'CFBundleVersion': '96'}))
        with self.assertRaisesRegex(ValueError, 'CFBundleVersion'):
            RESOURCES.verify(self.app)

    def test_old_icon_in_widget_is_rejected(self):
        (self.widget / 'Contents/Resources/LunavectTide.icns').write_bytes(b'icns-old-design')
        with self.assertRaisesRegex(ValueError, 'different icon artwork'):
            RESOURCES.verify(self.app)

    def test_declared_icon_must_exist(self):
        (self.widget / 'Contents/Info.plist').write_bytes(plistlib.dumps({**self.info, 'CFBundleIconFile': 'AppIcon'}))
        with self.assertRaisesRegex(ValueError, 'declared icon'):
            RESOURCES.verify(self.app)

    def test_old_translations_are_rejected(self):
        (self.widget / 'Contents/Resources/Translations.json').write_bytes(b'{}')
        with self.assertRaisesRegex(ValueError, 'Translations.json differs'):
            RESOURCES.verify(self.app)


if __name__ == '__main__':
    unittest.main()
