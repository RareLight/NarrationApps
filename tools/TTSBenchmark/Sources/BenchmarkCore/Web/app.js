(function () {
  'use strict';
  const $ = id => document.getElementById(id), E = BracketEngine;
  const seed = JSON.parse($('bracket-seed').textContent), participants = seed.participants;
  const byID = Object.fromEntries(participants.map(p => [p.id, p]));
  const key = 'tts-bracket-v1:' + seed.runID;
  let state = E.validate(seed, seed.progress), reviewing = null, selected = null, names = null;
  let stored = null, storageOK = true, conflict = false;
  const serial = value => JSON.stringify(value);
  const sameVotes = (a, b) => a.length === b.length && a.every((v, i) => ['match', 'choice', 'note', 'at'].every(k => v[k] === b[i][k]));
  function notice(message) { $('notice').textContent = message; $('notice').hidden = !message; }
  function status() {
    $('save-status').textContent = conflict ? 'A different tab has newer progress' : storageOK ? 'Saved in this browser · back up with a progress file' : 'Browser saving unavailable · save a progress file';
  }
  try {
    stored = localStorage.getItem(key);
    localStorage.setItem(key + ':probe', '1'); localStorage.removeItem(key + ':probe');
    if (stored) {
      const candidate = E.validate(seed, JSON.parse(stored));
      const prefix = candidate.history.slice(0, seed.progress.history.length);
      if (candidate.sourceRevision !== seed.sourceRevision && !sameVotes(prefix, seed.progress.history)) throw Error('Browser progress conflicts with this page’s starting state. Import a backup to choose the progress you want.');
      state = candidate;
      state.sourceRevision = seed.sourceRevision;
    }
  } catch (error) {
    // A malformed/mismatched saved state is never silently overwritten.
    if (stored) { conflict = true; notice(error.message); }
    else { storageOK = false; notice('This browser cannot retain local-file progress. Use Save progress file before closing.'); }
  }
  function persist(next, force = false) {
    next = E.validate(seed, next);
    if (conflict && !force) throw Error('Import a progress backup or reload the page before saving more choices.');
    if (storageOK) {
      try {
        const current = localStorage.getItem(key);
        if (!force && current !== stored) { conflict = true; $('submit').disabled = true; status(); throw Error('Another tab saved a choice. Reload to use its progress; this choice was not saved.'); }
        const text = serial(next); localStorage.setItem(key, text);
        if (localStorage.getItem(key) !== text) throw Error('Browser did not retain progress.');
        stored = text;
      } catch (error) {
        if (conflict) throw error;
        storageOK = false;
        notice('Browser saving failed. Your choices remain here; use Save progress file before closing.');
      }
    }
    state = next; conflict = false; status();
  }
  function stopAudio() { for (const id of ['audio-a', 'audio-b']) $(id).pause(); }
  document.addEventListener('play', event => {
    if (event.target.tagName === 'AUDIO') for (const id of ['audio-a', 'audio-b']) if ($(id) !== event.target) $(id).pause();
  }, true);
  function label(id) { return names?.[id] || byID[id].label; }
  const stages = {winners: 'MAIN BRACKET', consolation: 'SECOND CHANCE', 'grand-final': 'FINAL PAIR', 'final-reset': 'FINAL REMATCH'};
  const choices = {a: 'Preferred A', b: 'Preferred B', tie: 'Tie · another passage', neither: 'Neither', defer: 'Paused here'};
  function setSelection(choice) {
    selected = choice;
    for (const button of document.querySelectorAll('[data-choice]')) button.setAttribute('aria-pressed', String(button.dataset.choice === choice));
    $('submit').disabled = !selected || conflict;
  }
  function render() {
    stopAudio();
    const v = E.view(participants, state.decisions);
    const match = reviewing ? v.matches.find(m => m.id === reviewing) : v.pending;
    $('comparison').hidden = !match; $('complete').hidden = !!match;
    $('progress').textContent = `${v.matches.filter(m => m.id !== v.pending?.id).length} pairs decided · ${participants.length} narrators · ${v.eliminated.length + v.rejected.length} finished`;
    if (match) {
      $('round').textContent = (reviewing ? 'REVISITING · ' : '') + stages[match.stage];
      $('match-title').textContent = `Pair ${Number(match.id.slice(6))}`;
      const passage = seed.passages[match.passageOffset % seed.passages.length];
      for (const side of ['a', 'b']) {
        $('name-' + side).textContent = byID[match[side]].label;
        $('audio-' + side).src = byID[match[side]].clips[passage.id];
      }
      $('passage').textContent = passage.text;
      const vote = state.decisions.filter(d => d.match === match.id).at(-1);
      $('notes').value = vote?.note || '';
      $('revision-warning').hidden = !reviewing; $('cancel-review').hidden = !reviewing;
      $('submit').textContent = reviewing ? 'Save revised choice' : 'Save & continue';
      setSelection(reviewing ? vote?.choice : null);
    } else {
      $('round').textContent = 'BRACKET COMPLETE'; $('match-title').textContent = 'Your preferred narrators';
      $('shortlist').replaceChildren();
      const shortlist = E.shortlist(participants, state);
      for (const id of shortlist) {
        const li = document.createElement('li'); li.textContent = `${label(id)}${id === v.champion ? ' · top choice' : id === v.runnerUp ? ' · runner-up' : ' · contender'}`;
        $('shortlist').append(li);
      }
      if (!shortlist.length) { const p = document.createElement('p'); p.textContent = 'All narrators were rejected. Revisit a pair if you want to reconsider.'; $('shortlist').append(p); }
      $('reveal').disabled = !!v.pending;
      $('reveal').textContent = names ? 'Identities revealed' : 'Reveal final identities…';
      $('identity-results').hidden = !names; $('identity-list').replaceChildren();
      if (names) for (const participant of participants) {
        const li = document.createElement('li');
        li.textContent = participant.label + ' · ' + names[participant.id] + (v.rejected.includes(participant.id) ? ' · rejected' : '');
        $('identity-list').append(li);
      }
      $('contenders').replaceChildren();
      for (const participant of participants.filter(p => !v.rejected.includes(p.id))) {
        const row = document.createElement('label'), input = document.createElement('input');
        input.type = 'checkbox'; input.checked = state.retained.includes(participant.id);
        input.addEventListener('change', () => {
          const next = JSON.parse(serial(state));
          next.retained = next.retained.filter(id => id !== participant.id);
          if (input.checked) next.retained.push(participant.id);
          try { persist(next); render(); } catch (error) { input.checked = !input.checked; notice(error.message); }
        });
        row.append(input, ' Keep ' + label(participant.id) + ' as an extra finalist'); $('contenders').append(row);
      }
    }
    $('history').replaceChildren();
    for (const item of v.matches) {
      const vote = state.decisions.filter(d => d.match === item.id).at(-1);
      const row = document.createElement('div'); row.className = 'history-row';
      const text = document.createElement('div'), title = document.createElement('span'), detail = document.createElement('small');
      title.textContent = `Pair ${Number(item.id.slice(6))} · ${byID[item.a].label} / ${byID[item.b].label}`;
      detail.textContent = (choices[vote?.choice] || 'Not assessed') + (vote?.note ? '\n' + vote.note : '');
      text.append(title, detail); row.append(text);
      if (item.id !== v.pending?.id) {
        const button = document.createElement('button'); button.className = 'quiet'; button.textContent = 'Revisit';
        button.addEventListener('click', () => { reviewing = item.id; names = null; render(); $('match-title').focus(); }); row.append(button);
      }
      $('history').append(row);
    }
    status();
  }
  for (const button of document.querySelectorAll('[data-choice]')) button.addEventListener('click', () => setSelection(button.dataset.choice));
  $('submit').addEventListener('click', () => {
    try {
      const match = reviewing || E.view(participants, state.decisions).pending?.id;
      const choice = selected;
      persist(E.answer(participants, state, match, choice, $('notes').value, !!reviewing));
      reviewing = null; notice(choice === 'defer' ? 'Paused here. Progress is saved; you can return to this pair later.' : '');
      render(); $('match-title').focus();
    } catch (error) { notice(error.message); }
  });
  $('cancel-review').addEventListener('click', () => { reviewing = null; render(); });
  function exportText() { return JSON.stringify(state, null, 2) + '\n'; }
  $('backup').addEventListener('click', () => {
    const blob = new Blob([exportText()], {type: 'application/json'}), url = URL.createObjectURL(blob);
    const a = document.createElement('a'); a.href = url; a.download = 'bracket-progress-' + seed.runID.slice(0, 8) + '.json';
    a.hidden = true; document.body.append(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    notice('Progress file requested. Keep the downloaded JSON file as your portable backup. If downloads are unavailable, use Copy progress.');
  });
  $('copy').addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(exportText()); notice('Progress JSON copied. Paste it into a .json file to keep a backup.'); }
    catch (_) { $('copy-area').hidden = false; $('copy-area').open = true; $('progress-text').value = exportText(); $('progress-text').focus(); $('progress-text').select(); notice('Copy the selected progress text to keep a backup.'); }
  });
  $('restore').addEventListener('click', () => { $('progress-file').value = ''; $('progress-file').click(); });
  $('progress-file').addEventListener('change', async () => {
    const file = $('progress-file').files[0]; if (!file) return;
    try {
      if (file.size > 4000000) throw Error('Progress file is too large.');
      const next = E.validate(seed, JSON.parse(await file.text()));
      if (!window.confirm('Replace this browser’s current progress with this backup?')) return;
      next.sourceRevision = seed.sourceRevision;
      persist(next, true); reviewing = null; names = null; notice('Progress restored.'); render();
    } catch (error) { notice('Could not import progress: ' + error.message); }
  });
  $('reveal').addEventListener('click', () => {
    if (E.view(participants, state.decisions).pending) return;
    $('identity-file').value = ''; $('identity-file').click();
  });
  $('identity-file').addEventListener('change', async () => {
    if (E.view(participants, state.decisions).pending) return;
    const file = $('identity-file').files[0]; if (!file) return;
    try {
      if (file.size > 100000) throw Error('Identity file is too large.');
      const mapping = JSON.parse(await file.text());
      if (mapping.version !== 1 || mapping.runID !== seed.runID || participants.some(p => typeof mapping.names?.[p.id] !== 'string')) throw Error('Select this bracket’s bracket-identities.json file.');
      names = mapping.names; render(); notice('Final identities revealed. Your saved choices are unchanged.');
    } catch (error) { notice(error.message); }
  });
  window.addEventListener('storage', event => {
    if (event.key === key && event.newValue !== stored) { conflict = true; setSelection(null); status(); notice('Another tab changed this bracket. Reload before recording another choice.'); }
  });
  render();
  $('startup-status').hidden = true;
  $('app').hidden = false;
  for (const id of ['backup', 'restore', 'copy']) $(id).disabled = false;
})();
