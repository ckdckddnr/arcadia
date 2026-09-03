/* Arcadia telemetry — anonymous counters only.
 *
 * Why this file exists at all, given every game here is deliberately a single
 * self-contained page: guests write nothing to the database, which is right for
 * the economy and left us unable to tell "nobody visited" apart from "plenty
 * visited, played, and left". After a $50 ad run that produced zero signups,
 * those two look identical from the server, and they need opposite fixes.
 *
 * What is recorded: a day, a page name, and which of view/start/finish
 * happened, plus a tally. What is NOT recorded, anywhere, ever: user id, IP,
 * session id, cookie, referrer, or any raw user-agent string. The rows cannot
 * be joined back to a person even in principle, which is why this needs no
 * consent banner — same footing as the cookieless Vercel Analytics already in
 * use.
 *
 * Deliberately dependency-free and plain fetch(): it must still report when the
 * Supabase library is the thing that failed to load.
 */
(function () {
  'use strict';

  var RPC  = 'https://ndntseichzbdzehksxxk.supabase.co/rest/v1/rpc/';
  var ANON = 'sb_publishable_3w88cicQLrH0bSJfSNpi1Q_6kyY0Qsy';

  // Reading the session lets the server tell a guest from an account holder.
  // The token is only sent as a bearer, exactly as every other call on the
  // site does; nothing about it is stored.
  function accessToken() {
    try {
      for (var i = 0; i < localStorage.length; i++) {
        var k = localStorage.key(i);
        if (!/^sb-.*-auth-token$/.test(k)) continue;
        var v = JSON.parse(localStorage.getItem(k) || 'null');
        if (v && v.access_token) return v.access_token;
      }
    } catch (e) { /* private mode, blocked storage — treat as guest */ }
    return null;
  }

  var budget = 50;   // a broken page must never hammer the endpoint
  function call(fn, body) {
    if (budget <= 0) return;
    budget--;
    try {
      var t = accessToken();
      fetch(RPC + fn, {
        method: 'POST',
        headers: {
          'apikey': ANON,
          'Authorization': 'Bearer ' + (t || ANON),
          'Content-Type': 'application/json'
        },
        body: JSON.stringify(body),
        keepalive: true          // survives the page being closed mid-send
      })['catch'](function () { /* telemetry never surfaces its own failure */ });
    } catch (e) { /* ditto */ }
  }

  // Page id, matching the whitelist in track_event(). Anything unrecognised is
  // dropped server-side rather than creating a junk row.
  var PAGE = (function () {
    var f = (location.pathname.split('/').pop() || '').toLowerCase();
    if (f === '' || f === 'index.html') return 'home';
    var m = f.match(/^game-(.+)\.html$/);
    if (m) {
      if (m[1] === 'boss-battle') return 'boss-lobby';
      if (m[1] === 'boss-fight-1') return 'boss-1';
      return m[1];
    }
    return f.replace(/\.html$/, '');
  })();

  var viewSent = false;
  function track(event) {
    if (event === 'view') {
      if (viewSent) return;      // once per page load; start/finish may repeat
      viewSent = true;
    }
    call('track_event', { p_page: PAGE, p_event: event });
  }

  // Coarse enough to spot "it only breaks on iOS Safari", too coarse to
  // fingerprint anyone. The raw UA string never leaves the browser.
  function browser() {
    var u = navigator.userAgent || '';
    var os = /iPhone|iPad|iPod/.test(u) ? 'iOS'
           : /Android/.test(u)          ? 'Android'
           : /Windows/.test(u)          ? 'Windows'
           : /Mac OS X/.test(u)         ? 'macOS' : 'other';
    var br = /EdgA?\//.test(u)          ? 'Edge'
           : /CriOS|Chrome/.test(u)     ? 'Chrome'
           : /FxiOS|Firefox/.test(u)    ? 'Firefox'
           : /Safari/.test(u)           ? 'Safari' : 'other';
    var form = /Mobi|Android|iPhone|iPad/.test(u) ? 'mobile' : 'desktop';
    return br + '/' + os + '/' + form;
  }

  var errCount = 0;
  function report(message, where) {
    if (errCount >= 5) return;   // one broken loop should cost five rows, not five thousand
    errCount++;
    call('log_client_error', {
      p_page: PAGE,
      p_message: String(message).slice(0, 300),
      p_where: String(where || '').slice(0, 200),
      p_browser: browser()
    });
  }

  window.addEventListener('error', function (e) {
    if (!e || !e.message) return;
    report(e.message, (e.filename || '') + ':' + (e.lineno || 0) + ':' + (e.colno || 0));
  });

  window.addEventListener('unhandledrejection', function (e) {
    var r = e && e.reason;
    report('unhandled rejection: ' + ((r && r.message) ? r.message : r), '');
  });

  window.arcTrack = track;       // games call arcTrack('start') / arcTrack('finish')
  window.arcReport = report;     // and can report a caught error explicitly

  track('view');
})();
