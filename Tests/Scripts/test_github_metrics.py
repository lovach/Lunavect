import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('metrics', Path(__file__).resolve().parents[2] / 'scripts/collect-github-metrics.py')
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)


class GitHubMetricsTests(unittest.TestCase):
    def test_assets_are_separate_from_users_and_drafts_are_excluded(self):
        assets = [dict(id=i, name=name, download_count=count) for i, (name, count) in enumerate([
            ('Lunavect-0.2.3.dmg', 10), ('Lunavect-0.2.3-189.zip', 4), ('appcast.xml', 90), ('SHA256SUMS', 2)])]
        result = metrics.summarize([dict(tag_name='v0.2.3', assets=assets), dict(draft=True, assets=assets)], None, None)
        self.assertEqual(result['asset_downloads'], dict(dmg=10, zip=4, appcast=90, other=2))
        self.assertIsNone(result['views'])
        self.assertNotIn('users', result)

    def test_traffic_reports_actual_returned_dates_not_collection_date(self):
        result = metrics.summarize([], dict(count=33, uniques=11, views=[dict(timestamp='2026-09-10'), dict(timestamp='2026-09-23')]), None)
        self.assertEqual(result['views'], dict(count=33, uniques=11, returned_start='2026-09-10', returned_end='2026-09-23'))

    def test_deltas_compare_asset_ids_and_do_not_invent_new_or_negative_downloads(self):
        old = dict(assets=[dict(id=1, downloads=9), dict(id=2, downloads=20)])
        current = dict(assets=[dict(id=1, name='same.dmg', downloads=12), dict(id=2, name='reset.zip', downloads=1), dict(id=3, name='new.dmg', downloads=5)])
        delta = metrics.asset_deltas(current, old)
        self.assertEqual([row['delta'] for row in delta], [3, None, None])
