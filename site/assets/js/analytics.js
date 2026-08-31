// PostHog analytics, tuned for a static marketing site.
//
// Design constraints (see docs/deploy/posthog-analytics.md and site-lint.sh):
//   1. First-party only. Every request goes to this origin's /ingest path,
//      which nginx reverse-proxies to PostHog (server/deploy/nginx-site.conf).
//      This keeps the site free of third-party requests (site-lint rule #1),
//      is one fewer DNS/TLS handshake, and is not dropped by tracker blockers.
//      Because of that invariant there must be NO literal posthog.com URL in
//      this file: the host is built from location.origin at runtime.
//   2. Lean-ish. autocapture is OFF (it attaches listeners /
//      record the DOM); we send pageviews + a few explicit events instead.
//   3. Off the critical path. Loaded on requestIdleCallback so it never
//      competes with LCP.

// Public project (write-only) key. Region: US. It is not a secret, but it lives
// in its own file so it can be supplied from site/.env at deploy time rather
// than hardcoded here — see ph-config.js and scripts/deploy-site.sh. Empty in
// the committed source, so a plain checkout no-ops until deployed/configured.
import { POSTHOG_KEY } from './ph-config.js';

// Same-origin proxy base. nginx routes /ingest/static/* to PostHog's asset CDN
// and /ingest/* to the US ingestion API. location.origin keeps this correct on
// both slipreel.app and www.slipreel.app without a cross-origin hop.
const PROXY_HOST = `${window.location.origin}/ingest`;

function initPostHog() {
  // Official PostHog bootstrap snippet. It injects array.js from
  // `${api_host}/static/array.js` (our api_host is a custom domain, so the
  // built-in *.i.posthog.com asset-host rewrite is a no-op and it resolves to
  // /ingest/static/array.js — handled by the nginx static block).
  !(function (t, e) {
    var o, n, p, r;
    e.__SV ||
      ((window.posthog = e),
      (e._i = []),
      (e.init = function (i, s, a) {
        function g(t, e) {
          var o = e.split('.');
          2 == o.length && ((t = t[o[0]]), (e = o[1]));
          t[e] = function () {
            t.push([e].concat(Array.prototype.slice.call(arguments, 0)));
          };
        }
        ((p = t.createElement('script')).type = 'text/javascript'),
          (p.crossOrigin = 'anonymous'),
          (p.async = !0),
          (p.src = s.api_host.replace('.i.posthog.com', '-assets.i.posthog.com') + '/static/array.js'),
          (r = t.getElementsByTagName('script')[0]).parentNode.insertBefore(p, r);
        var u = e;
        for (
          void 0 !== a ? (u = e[a] = []) : (a = 'posthog'),
            u.people = u.people || [],
            u.toString = function (t) {
              var e = 'posthog';
              return 'posthog' !== a && (e += '.' + a), t || (e += ' (stub)'), e;
            },
            u.people.toString = function () {
              return u.toString(1) + '.people (stub)';
            },
            o =
              'init capture register register_once register_for_session unregister unregister_for_session getFeatureFlag getFeatureFlagPayload isFeatureEnabled reloadFeatureFlags updateEarlyAccessFeatureEnrollment getEarlyAccessFeatures on onFeatureFlags onSessionId getSurveys getActiveMatchingSurveys renderSurvey canRenderSurvey identify setPersonProperties group resetGroups setPersonPropertiesForFlags resetPersonPropertiesForFlags setGroupPropertiesForFlags resetGroupPropertiesForFlags reset get_distinct_id getGroups get_session_id get_session_replay_url alias set_config startSessionRecording stopSessionRecording sessionRecordingStarted captureException loadToolbar get_property getSessionProperty createPersonProfile opt_in_capturing opt_out_capturing has_opted_in_capturing has_opted_out_capturing clear_opt_in_out_capturing debug getPageViewId captureTraceFeedback captureTraceMetric'.split(
                ' '
              ),
            n = 0;
          n < o.length;
          n++
        )
          g(u, o[n]);
        e._i.push([i, s, a]);
      }),
      (e.__SV = 1));
  })(document, window.posthog || []);

  window.posthog.init(POSTHOG_KEY, {
    api_host: PROXY_HOST,
    autocapture: false, // no blanket click/input listeners
    capture_pageview: true, // one pageview per full page load (this is an MPA)
    capture_pageleave: true, // bounce / time-on-page
    disable_session_recording: false, // session replay ON (full) — requires
    // "Record user sessions" enabled in PostHog Project Settings > Session Replay.
    // Inputs are masked by default (maskAllInputs) so typed text isn't captured.
    disable_surveys: true,
    person_profiles: 'identified_only', // anonymous pageviews stay cheap
    persistence: 'localStorage', // no analytics cookie -> no consent banner
  });
}

// Only load once configured, and never on the critical path.
if (typeof POSTHOG_KEY === 'string' && POSTHOG_KEY.startsWith('phc_')) {
  if ('requestIdleCallback' in window) {
    window.requestIdleCallback(initPostHog, { timeout: 3000 });
  } else {
    window.addEventListener('load', () => window.setTimeout(initPostHog, 1));
  }
}
