/* Forge lab pages: progress, copy buttons, live checks, quizzes. No dependencies. */
(function () {
  'use strict';
  var labId = document.body.dataset.lab || 'unknown';
  function key(k) { return 'forge-labs/' + labId + '/' + k; }
  function store(k, v) { try { localStorage.setItem(key(k), v); } catch (e) {} }
  function load(k) { try { return localStorage.getItem(key(k)); } catch (e) { return null; } }

  // Step checkboxes + progress chip
  var steps = Array.prototype.slice.call(document.querySelectorAll('section.step'));
  var chip = document.getElementById('progress');
  function updateProgress() {
    var done = document.querySelectorAll('section.step input.step-done:checked').length;
    if (chip) chip.textContent = done + '/' + steps.length + ' steps done';
    store('progress', JSON.stringify({ done: done, total: steps.length }));
  }
  steps.forEach(function (s) {
    var id = s.dataset.step;
    var done = load(id) === '1';
    // Two synced checkboxes per step: one in the heading, one at the bottom so a
    // long step can be ticked off without scrolling back up.
    var top = document.createElement('input');
    top.type = 'checkbox'; top.className = 'step-done'; top.title = 'Mark step done';
    var foot = document.createElement('label');
    foot.className = 'step-foot';
    var bottom = document.createElement('input');
    bottom.type = 'checkbox'; bottom.className = 'step-done';
    foot.appendChild(bottom);
    foot.appendChild(document.createTextNode(' Mark this step done'));
    function set(v) {
      top.checked = bottom.checked = v;
      s.classList.toggle('done', v);
    }
    set(done);
    [top, bottom].forEach(function (box) {
      box.addEventListener('change', function () {
        set(box.checked);
        store(id, box.checked ? '1' : '0');
        updateProgress();
      });
    });
    var h = s.querySelector('h2');
    if (h) h.insertBefore(top, h.firstChild);
    s.appendChild(foot);
  });
  updateProgress();

  // Copy buttons on every code block
  document.querySelectorAll('pre').forEach(function (pre) {
    var btn = document.createElement('button');
    btn.className = 'copy'; btn.type = 'button'; btn.textContent = 'copy';
    btn.addEventListener('click', function () {
      var codeEl = pre.querySelector('code');
      var text = (codeEl ? codeEl.innerText : pre.innerText).trim();
      function flash() { btn.textContent = 'copied'; setTimeout(function () { btn.textContent = 'copy'; }, 1200); }
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(flash, function () { fallback(); });
      } else { fallback(); }
      function fallback() {
        var ta = document.createElement('textarea');
        ta.value = text; document.body.appendChild(ta); ta.select();
        try { document.execCommand('copy'); flash(); } catch (e) {}
        ta.remove();
      }
    });
    pre.appendChild(btn);
  });

  // Live "check my work" buttons: <button class="check" data-url="http://...">
  document.querySelectorAll('button.check').forEach(function (btn) {
    var out = document.createElement('span');
    out.className = 'check-result';
    btn.parentNode.insertBefore(out, btn.nextSibling);
    btn.addEventListener('click', function () {
      out.className = 'check-result'; out.textContent = '…';
      if (location.protocol === 'https:') {
        out.textContent = 'live checks need the local copy: python3 -m http.server (see footer)';
        out.classList.add('warn'); return;
      }
      var url = btn.dataset.url;
      fetch(url, { cache: 'no-store' }).then(function (r) {
        out.textContent = r.ok ? 'up (HTTP ' + r.status + ')' : 'answered HTTP ' + r.status;
        out.classList.add(r.ok ? 'ok' : 'warn');
      }, function () {
        // CORS-blocked and network-down both land here; a no-cors probe tells them apart.
        fetch(url, { mode: 'no-cors', cache: 'no-store' }).then(function () {
          out.textContent = 'reachable, but CORS-blocked: rebuild and load the current fake-inference image to enable checks';
          out.classList.add('warn');
        }, function () {
          out.textContent = 'unreachable: is the service running?';
          out.classList.add('bad');
        });
      });
    });
  });

  // Quiz: <div class="quiz"><div class="q"><label class="option" data-correct="true">...
  var qs = Array.prototype.slice.call(document.querySelectorAll('.quiz .q'));
  function updateQuiz() {
    var right = document.querySelectorAll('.quiz .q.correct').length;
    var answered = document.querySelectorAll('.quiz .q.answered').length;
    store('quiz', JSON.stringify({ right: right, answered: answered, total: qs.length }));
    var score = document.getElementById('quiz-score');
    if (score) score.textContent = right + '/' + qs.length + ' correct';
  }
  qs.forEach(function (q) {
    q.querySelectorAll('label.option input').forEach(function (inp) {
      inp.addEventListener('change', function () {
        if (q.classList.contains('answered')) return; // first answer counts
        q.classList.add('answered');
        var correct = inp.closest('label').dataset.correct === 'true';
        q.classList.toggle('correct', correct);
        var ex = q.querySelector('.explain');
        if (ex) ex.hidden = false;
        updateQuiz();
      });
    });
  });
  updateQuiz();
})();
