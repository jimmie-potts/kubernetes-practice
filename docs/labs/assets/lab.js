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

  // Clipboard helper shared by copy buttons and the teach-back export
  function copyText(text, done) {
    function fallback() {
      var ta = document.createElement('textarea');
      ta.value = text; document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy'); done(); } catch (e) {}
      ta.remove();
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, fallback);
    } else { fallback(); }
  }

  // Copy buttons on every code block
  document.querySelectorAll('pre').forEach(function (pre) {
    var btn = document.createElement('button');
    btn.className = 'copy'; btn.type = 'button'; btn.textContent = 'copy';
    btn.addEventListener('click', function () {
      var codeEl = pre.querySelector('code');
      var text = (codeEl ? codeEl.innerText : pre.innerText).trim();
      copyText(text, function () { btn.textContent = 'copied'; setTimeout(function () { btn.textContent = 'copy'; }, 1200); });
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

  // Teach-back: <section class="teach-back"> holding <div class="tb" data-tb="t1">
  // with p.prompt, a textarea, and details.model. Answers persist per browser;
  // the model answer unlocks once an answer is written; an export button copies
  // everything as markdown for review.
  var MIN_ANSWER = 20;
  var tbs = Array.prototype.slice.call(document.querySelectorAll('.teach-back .tb'));
  var teachChip = document.getElementById('teach-score');
  function answered(t) { var ta = t.querySelector('textarea'); return !!ta && ta.value.trim().length >= MIN_ANSWER; }
  function updateTeach() {
    var written = tbs.filter(answered).length;
    store('teach', JSON.stringify({ written: written, total: tbs.length }));
    if (teachChip) teachChip.textContent = written + '/' + tbs.length + ' taught back';
  }
  if (teachChip && !tbs.length) teachChip.hidden = true;
  tbs.forEach(function (t) {
    var id = t.dataset.tb;
    var ta = t.querySelector('textarea');
    var model = t.querySelector('details.model');
    if (!ta) return;
    ta.value = load('tb/' + id) || '';
    var saved = document.createElement('div');
    saved.className = 'saved';
    ta.parentNode.insertBefore(saved, ta.nextSibling);
    function refresh() {
      var ok = answered(t);
      if (model) { model.classList.toggle('locked', !ok); if (!ok) model.open = false; }
      saved.textContent = ok ? 'saved in this browser' : (ta.value.trim() ? 'keep going: a sentence or two unlocks the model answer' : '');
    }
    var timer;
    ta.addEventListener('input', function () {
      clearTimeout(timer);
      timer = setTimeout(function () { store('tb/' + id, ta.value); refresh(); updateTeach(); }, 250);
    });
    if (model) {
      var summary = model.querySelector('summary');
      if (summary) summary.addEventListener('click', function (e) {
        if (model.classList.contains('locked')) {
          e.preventDefault();
          saved.textContent = 'write your answer first, then compare';
        }
      });
    }
    refresh();
  });
  var teachSection = document.querySelector('.teach-back');
  if (teachSection && tbs.length) {
    var wrap = document.createElement('p');
    var exportBtn = document.createElement('button');
    exportBtn.type = 'button'; exportBtn.className = 'action'; exportBtn.textContent = 'Copy answers for review';
    var note = document.createElement('span');
    note.className = 'check-result';
    wrap.appendChild(exportBtn); wrap.appendChild(note); teachSection.appendChild(wrap);
    exportBtn.addEventListener('click', function () {
      var h1 = document.querySelector('h1');
      var prog = JSON.parse(load('progress') || '{}');
      var quiz = JSON.parse(load('quiz') || '{}');
      var teach = JSON.parse(load('teach') || '{}');
      var lines = [
        '## Teach-back: ' + (h1 ? h1.textContent.trim() : labId),
        '',
        'Steps ' + (prog.done || 0) + '/' + (prog.total || 0)
          + ' · Quiz ' + (quiz.right || 0) + '/' + (quiz.total || 0)
          + ' · Teach-back ' + (teach.written || 0) + '/' + (teach.total || 0),
        ''
      ];
      tbs.forEach(function (t) {
        var prompt = t.querySelector('p.prompt');
        var ta = t.querySelector('textarea');
        lines.push('### ' + (prompt ? prompt.textContent.trim() : t.dataset.tb));
        lines.push('');
        lines.push(ta && ta.value.trim() ? ta.value.trim() : '(no answer yet)');
        lines.push('');
      });
      copyText(lines.join('\n'), function () {
        note.textContent = 'copied. Paste it in the chat when you report this phase done.';
        note.className = 'check-result ok';
      });
    });
  }
  updateTeach();
})();
