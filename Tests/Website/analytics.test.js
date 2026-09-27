'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const { randomUUID } = require('node:crypto');
const { attribution, downloadTarget, createClient } = require('../../docs/assets/analytics/analytics.js');
const config = { token: 'phc_0123456789abcdefghijklmnop', host: 'https://eu.i.posthog.com' };
function fixture(extra = {}) {
  const values = new Map(), requests = [];
  const storage = { getItem: key => values.get(key), setItem: (key, value) => values.set(key, value) };
  const client = createClient({ config, storage, send: (url, body) => requests.push({ url, body }), uuid: randomUUID,
    now: () => '2026-09-27T12:34:56Z', context: attribution(new URL('https://lovach.github.io/Lunavect/'), ''), ...extra });
  return { client, requests, values, storage };
}
test('no request before consent, after refusal, or with missing/invalid configuration', () => {
  for (const setting of [config, {}, { ...config, host: 'https://us.i.posthog.com' }, { ...config, token: 'phx_personalkey' }]) {
    const { client, requests, values } = fixture({ config: setting });
    client.capture('download_clicked', 'dmg'); assert.equal(requests.length, 0); assert.equal(values.size, 0);
    client.choose(false); client.capture('download_clicked', 'dmg'); assert.equal(requests.length, 0);
    if (setting !== config) { client.choose(true); client.capture('download_clicked', 'dmg'); assert.equal(requests.length, 0); }
  }
});
test('consent itself sends nothing; no persistent identity, independent ID per event and hour precision', () => {
  const { client, requests, values } = fixture(); client.choose(true); client.choose(true); assert.equal(requests.length,0);
  client.capture('download_clicked', 'dmg'); client.capture('download_clicked', 'dmg');
  assert.notEqual(requests[0].body.distinct_id, requests[1].body.distinct_id);
  assert.equal(requests[0].body.uuid, requests[0].body.distinct_id);
  assert.equal(requests[0].body.timestamp, '2026-09-27T12:00:00.000Z');
  assert.deepEqual([...values.keys()], ['lunavect.analytics.consent.v1']);
  client.choose(false); client.capture('download_clicked', 'dmg'); assert.equal(requests.length,2);
});
test('persisted choice works after reload; revocation in another tab stops capture', () => {
  const { client, requests, storage } = fixture(); client.choose(true);
  const next = fixture({ storage }); next.client.capture('download_clicked', 'zip'); assert.equal(next.requests.length,1);
  next.client.choose(false); client.capture('download_clicked', 'dmg'); assert.equal(requests.length,0);
});
test('privacy signals and unavailable storage fail closed', () => {
  for (const extra of [{ privacySignal: true }, { storage: { getItem() { throw Error(); }, setItem() { throw Error(); } } }]) {
    const { client, requests } = fixture(extra); client.choose(true); client.capture('download_clicked', 'dmg');
    assert.equal(requests.length,0);
  }
});
test('source is a known category, never arbitrary URL, query, path, campaign or referrer', () => {
  const location = new URL('https://lovach.github.io/Lunavect/private-name?utm_source=private@email.test&utm_campaign=secret&token=secret');
  assert.deepEqual(attribution(location, 'https://www.reddit.com/r/private-name?secret'), { source: 'reddit', surface: 'website' });
  assert.equal(attribution(location, 'https://reddit.com.evil.example/private').source, 'other');
  assert.deepEqual(attribution(new URL('https://lovach.github.io/Lunavect/?utm_source=x'), ''), { source: 'x', surface: 'website' });
});
test('download clicks distinguish release page, DMG and ZIP; external targets are ignored', () => {
  assert.equal(downloadTarget('https://github.com/lovach/Lunavect/releases/latest'), 'release_page');
  assert.equal(downloadTarget('https://github.com/lovach/Lunavect/releases/download/v0.2.3/Lunavect-0.2.3.dmg'), 'dmg');
  assert.equal(downloadTarget('https://github.com/lovach/Lunavect/releases/download/v0.2.3/Lunavect-0.2.3-189.zip'), 'zip');
  assert.equal(downloadTarget('https://example.com/lovach/Lunavect/releases/latest'), null);
  assert.equal(downloadTarget('https://github.com/another/Lunavect/releases/latest'), null);
});
test('only download clicks and allowlisted fields; no page views, profiles or GeoIP', () => {
  const { client, requests } = fixture({context: {source: 'reddit', private: 'secret', url: 'secret'}}); client.choose(true);
  client.capture('website_viewed'); client.capture('private session title'); client.capture('download_clicked', '/private/path');
  assert.equal(requests.length,0); client.capture('download_clicked', 'release_page');
  const { url, body } = requests[0]; assert.equal(url,'https://eu.i.posthog.com/i/v0/e/');
  assert.deepEqual(Object.keys(body.properties).sort(), ['$geoip_disable', '$process_person_profile', 'target', 'schema_version', 'source', 'surface'].sort());
  assert.equal(body.properties.$geoip_disable,true); assert.equal(body.properties.$process_person_profile,false);
});
test('delivery errors do not break downloads or preference actions', () => {
  const { client } = fixture({ send: () => { throw Error('offline'); } });
  assert.doesNotThrow(() => { client.choose(true); client.capture('download_clicked','release_page'); client.choose(false); });
});
