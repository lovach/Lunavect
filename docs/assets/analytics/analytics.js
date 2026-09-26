/* Explicit consent and allowlisted fields. No SDK autocapture, replay or fingerprinting. */
(function (root) {
  'use strict';
  const consentKey = 'lunavect.analytics.consent.v1';
  const sources = ['reddit', 'x', 'habr', 'producthunt', 'github', 'google', 'bing', 'newsletter', 'other', 'direct'];
  function attribution(location, referrer) {
    const sourceTag = new URLSearchParams(location.search).get('utm_source');
    let source = sources.includes(sourceTag) ? sourceTag : '';
    if (!source) {
      let host = ''; try { host = new URL(referrer).hostname; } catch (_) {}
      const domains = { 'reddit.com': 'reddit', 't.co': 'x', 'x.com': 'x', 'habr.com': 'habr', 'producthunt.com': 'producthunt', 'github.com': 'github', 'google.com': 'google', 'bing.com': 'bing' };
      source = Object.entries(domains).find(([domain]) => host === domain || host.endsWith('.' + domain))?.[1] || (host ? 'other' : 'direct');
    }
    return { source, surface: 'website' };
  }
  function downloadTarget(href, base) {
    let url; try { url = new URL(href, base); } catch (_) { return null; }
    if (url.origin !== 'https://github.com' || !url.pathname.startsWith('/lovach/Lunavect/releases/')) return null;
    if (/\/Lunavect-[0-9.]+(?:-[0-9]+)?\.dmg$/.test(url.pathname)) return 'dmg';
    if (/\/Lunavect-[0-9.]+-[0-9]+\.zip$/.test(url.pathname)) return 'zip';
    return /\/releases\/latest\/?$/.test(url.pathname) ? 'release_page' : null;
  }
  function createClient({ config, storage, send, uuid, now, context, privacySignal = false }) {
    const configured = /^phc_[A-Za-z0-9]{16,160}$/.test(config?.token || '') && config?.host === 'https://eu.i.posthog.com';
    const read = key => { try { return storage.getItem(key); } catch (_) { return null; } };
    const write = (key, value) => { try { storage.setItem(key, value); return true; } catch (_) { return false; } };
    let enabled = configured && !privacySignal && read(consentKey) === 'yes';
    function capture(event, target) {
      if (!enabled || read(consentKey) !== 'yes' || !configured || privacySignal || event !== 'download_clicked') return;
      if (!['dmg', 'zip', 'release_page'].includes(target)) return;
      const properties = { source: sources.includes(context?.source) ? context.source : 'other', surface: 'website',
        target, schema_version: '1', '$geoip_disable': true, '$process_person_profile': false };
      // Required by PostHog, but unique to this event. No browser/install identifier is stored or sent.
      const eventID = uuid();
      const timestamp = new Date(Math.floor(new Date(now()).getTime() / 3600000) * 3600000).toISOString();
      const body = { api_key: config.token, event, distinct_id: eventID, uuid: eventID, timestamp, properties };
      try { Promise.resolve(send(config.host + '/i/v0/e/', body)).catch(() => {}); } catch (_) {}
    }
    return {
      configured, blocked: privacySignal,
      get enabled() { return enabled; }, get decided() { return ['yes', 'no'].includes(read(consentKey)); },
      choose(value) {
        enabled = false;
        if (!value) { write(consentKey, 'no'); return; }
        if (!configured || privacySignal || !write(consentKey, 'yes')) return;
        enabled = true;
      }, capture
    };
  }
  if (typeof module !== 'undefined') module.exports = { attribution, downloadTarget, createClient };
  if (!root?.document || root.__lunavectAnalyticsLoaded) return;
  root.__lunavectAnalyticsLoaded = true;
  const config = root.LUNAVECT_ANALYTICS;
  const client = createClient({ config, storage: { getItem: key => root.localStorage.getItem(key), setItem: (key, value) => root.localStorage.setItem(key, value), removeItem: key => root.localStorage.removeItem(key) },
    uuid: () => root.crypto.randomUUID(), now: () => new Date().toISOString(),
    context: attribution(root.location, root.document.referrer),
    privacySignal: root.navigator.globalPrivacyControl === true || root.navigator.doNotTrack === '1',
    send: (url, body) => root.fetch(url, { method: 'POST', body: JSON.stringify(body), headers: { 'Content-Type': 'application/json' }, credentials: 'omit', referrerPolicy: 'no-referrer', redirect: 'error', keepalive: true })
  });
  if (!client.configured) return;
  function setup() {
    const document = root.document;
    const style = document.createElement('style');
    style.textContent = '.lv-analytics-panel{position:fixed;left:20px;bottom:20px;z-index:1000;box-sizing:border-box;max-width:430px;width:calc(100% - 40px);padding:20px;background:#151a24;color:#eef2f8;border:1px solid #414a59;border-radius:16px;box-shadow:0 8px 40px #0005;font:14px/1.5 system-ui,sans-serif}.lv-analytics-panel h2{font:600 17px system-ui;margin:0 0 8px}.lv-analytics-panel p{margin:0 0 14px}.lv-analytics-actions{display:flex;gap:10px}.lv-analytics-panel button{padding:8px 14px;border:1px solid #647083;border-radius:8px;background:#232c3b;color:inherit;cursor:pointer;font:inherit}.lv-analytics-panel a{color:#a9d1ff}.lv-analytics-settings{display:block;margin:18px auto;padding:4px 8px;background:transparent;border:0;color:inherit;text-decoration:underline;cursor:pointer;font:12px system-ui}';
    document.head.append(style);
    let panel;
    function show() {
      if (panel) return;
      panel = document.createElement('section'); panel.className = 'lv-analytics-panel'; panel.setAttribute('aria-label', 'Optional website statistics');
      const title = document.createElement('h2'); title.textContent = 'Help improve Lunavect';
      const text = document.createElement('p'); text.textContent = client.blocked ? 'Your browser privacy setting disables website analytics.' : 'Count clicks on download links and their source, such as Reddit or GitHub? We use PostHog EU. No visitor ID or browsing history. You can change this choice below at any time.';
      const actions = document.createElement('div'); actions.className = 'lv-analytics-actions';
      for (const [label, value] of client.blocked ? [['Close', false]] : [['No thanks', false], ['Allow statistics', true]]) {
        const button = document.createElement('button'); button.textContent = label;
        button.onclick = () => { client.choose(value); panel.remove(); panel = null; settings.focus(); }; actions.append(button);
      }
      const privacy = document.createElement('a'); privacy.href = '/Lunavect/privacy.html#optional-usage-statistics'; privacy.textContent = 'What is collected'; privacy.style.cssText = 'display:inline-block;margin-top:12px';
      panel.append(title, text, actions, privacy); document.body.append(panel);
    }
    const settings = document.createElement('button'); settings.className = 'lv-analytics-settings'; settings.textContent = 'Website statistics preferences'; settings.onclick = show; document.body.append(settings);
    if (!client.decided && !client.blocked) show();
    document.addEventListener('click', event => {
      const link = event.target.closest?.('a[href]'); if (!link) return;
      const target = downloadTarget(link.href, root.location.href); if (target) client.capture('download_clicked', target);
    });
  }
  if (root.document.readyState === 'loading') root.document.addEventListener('DOMContentLoaded', setup, { once: true }); else setup();
})(typeof window === 'undefined' ? null : window);
