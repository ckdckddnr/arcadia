/* One-time age confirmation for accounts that never gave one.
 *
 * Signing up by email asks for a date of birth and an over-18 tick. Signing in
 * with Google asks for neither, so those accounts walked past a gate the terms
 * rely on and card payments make matter. This asks once, on the first page an
 * account like that opens.
 *
 * Deliberately dependency-free plain fetch, the same as telemetry.js: it has to
 * work on pages whether or not the Supabase library has finished loading, and
 * it must never be the reason a page fails to render.
 */
(function () {
  'use strict';

  var RPC  = 'https://ndntseichzbdzehksxxk.supabase.co/rest/v1/rpc/';
  var ANON = 'sb_publishable_3w88cicQLrH0bSJfSNpi1Q_6kyY0Qsy';

  function accessToken() {
    try {
      for (var i = 0; i < localStorage.length; i++) {
        var k = localStorage.key(i);
        if (!/^sb-.*-auth-token$/.test(k)) continue;
        var v = JSON.parse(localStorage.getItem(k) || 'null');
        if (v && v.access_token) return v.access_token;
      }
    } catch (e) { /* private mode: treat as signed out */ }
    return null;
  }

  function call(fn, body, token) {
    return fetch(RPC + fn, {
      method: 'POST',
      headers: {
        'apikey': ANON,
        'Authorization': 'Bearer ' + token,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify(body || {})
    }).then(function (r) { return r.json(); });
  }

  function style() {
    if (document.getElementById('age-check-css')) return;
    var el = document.createElement('style');
    el.id = 'age-check-css';
    el.textContent = [
      '#age-check-back{position:fixed;inset:0;z-index:9999;background:rgba(6,8,12,0.88);',
      'backdrop-filter:blur(3px);display:flex;align-items:center;justify-content:center;padding:20px;}',
      '#age-check-box{background:#12161F;border:1px solid #242B38;border-radius:16px;',
      'padding:26px 24px;max-width:400px;width:100%;color:#F4F6FA;',
      "font-family:'Inter','Noto Sans KR',sans-serif;box-shadow:0 40px 90px -20px rgba(0,0,0,0.8);}",
      '#age-check-box h2{font-size:20px;margin:0 0 8px;font-weight:800;}',
      '#age-check-box p{font-size:14px;line-height:1.6;color:#8A93A6;margin:0 0 18px;}',
      '#age-check-box label{display:block;font-size:13px;font-weight:600;color:#8A93A6;margin-bottom:8px;}',
      '#age-check-date{width:100%;padding:12px 14px;background:#181D28;border:1px solid #242B38;',
      "border-radius:8px;color:#F4F6FA;font-size:15px;font-family:inherit;margin-bottom:14px;}",
      '#age-check-row{display:flex;align-items:center;gap:9px;font-size:13px;color:#8A93A6;margin-bottom:18px;}',
      '#age-check-row input{accent-color:#2DE1FC;width:16px;height:16px;}',
      '#age-check-go{width:100%;padding:13px;border:none;border-radius:8px;background:#FFB627;',
      "color:#1A1200;font-weight:800;font-size:15px;font-family:inherit;cursor:pointer;}",
      '#age-check-go:disabled{opacity:0.45;cursor:not-allowed;}',
      '#age-check-msg{font-size:13px;margin-top:12px;min-height:18px;color:#FF5C5C;}',
      '#age-check-msg.ok{color:#34D399;}'
    ].join('');
    document.head.appendChild(el);
  }

  function show(token) {
    style();
    var back = document.createElement('div');
    back.id = 'age-check-back';
    back.innerHTML =
      '<div id="age-check-box" role="dialog" aria-modal="true" aria-labelledby="age-check-h">' +
        '<h2 id="age-check-h">One quick thing</h2>' +
        '<p>Arcadia is for players aged 18 and over. Signing in with Google skipped ' +
           'this step, so we need it once.</p>' +
        '<label for="age-check-date">Date of birth</label>' +
        '<input type="date" id="age-check-date">' +
        '<div id="age-check-row"><input type="checkbox" id="age-check-tick">' +
          '<span>I confirm I am 18 years or older</span></div>' +
        '<button id="age-check-go" disabled>Confirm</button>' +
        '<div id="age-check-msg"></div>' +
      '</div>';
    document.body.appendChild(back);

    var date = back.querySelector('#age-check-date');
    var tick = back.querySelector('#age-check-tick');
    var go   = back.querySelector('#age-check-go');
    var msg  = back.querySelector('#age-check-msg');

    function sync() { go.disabled = !(date.value && tick.checked); }
    date.addEventListener('input', sync);
    tick.addEventListener('change', sync);

    go.addEventListener('click', function () {
      go.disabled = true;
      msg.className = '';
      msg.textContent = 'Saving...';
      call('arc_set_birthday', { p_birthday: date.value }, token)
        .then(function (res) {
          if (res && res.ok) {
            msg.className = 'ok';
            msg.textContent = 'Thanks — you are all set.';
            setTimeout(function () { back.remove(); }, 900);
            return;
          }
          var why = res && res.error;
          msg.textContent =
            why === 'under 18' ? 'Arcadia is only available to players aged 18 and over.'
          : why === 'bad date' ? 'That date does not look right — please check it.'
          : 'Could not save that — please try again.';
          // An under-18 answer is final: do not leave them signed in.
          if (why === 'under 18') {
            setTimeout(function () {
              try { localStorage.clear(); } catch (e) {}
              location.href = 'index.html';
            }, 2600);
          } else {
            go.disabled = false;
          }
        })
        ['catch'](function () {
          msg.textContent = 'Could not reach the server — please try again.';
          go.disabled = false;
        });
    });
  }

  var token = accessToken();
  if (!token) return;                       // signed out: nothing to ask
  call('arc_needs_age_check', {}, token)
    .then(function (needs) { if (needs === true) show(token); })
    ['catch'](function () { /* never block the page over this */ });
})();
