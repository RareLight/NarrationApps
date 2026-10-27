/* Mirrors Bracket.swift. Cross-language fixtures check every advancement path. */
(function (global) {
  'use strict';
  const clone = value => JSON.parse(JSON.stringify(value));
  function view(participants, decisions) {
    const ids = participants.map(p => p.id);
    if (!ids.length || new Set(ids).size !== ids.length) throw Error('Invalid narrator roster.');
    const result = {pending: null, matches: [], byes: [], champion: null, runnerUp: null,
      eliminated: [], rejected: [], losses: Object.fromEntries(ids.map(id => [id, 0]))};
    let number = 0;
    function play(a, b, stage) {
      if (++number >= 10000) throw Error('Invalid bracket progression.');
      const id = 'match-' + String(number).padStart(3, '0');
      const votes = decisions.filter(v => v.match === id);
      const match = {id, stage, a, b, passageOffset: votes.filter(v => v.choice === 'tie').length};
      result.matches.push(match);
      const vote = votes.at(-1);
      if (!vote || !['a', 'b', 'neither'].includes(vote.choice)) { result.pending = match; return null; }
      if (vote.choice === 'neither') { result.rejected.push(a, b); return []; }
      const winner = vote.choice === 'a' ? a : b, loser = vote.choice === 'a' ? b : a;
      if (++result.losses[loser] === 2) result.eliminated.push(loser);
      return [winner, loser];
    }
    let winners = ids.slice(), losers = [];
    while (winners.length > 1) {
      const next = [];
      for (let i = 0; i < winners.length; i += 2) {
        if (i + 1 === winners.length) { next.push(winners[i]); result.byes.push(winners[i]); continue; }
        const outcome = play(winners[i], winners[i + 1], 'winners');
        if (outcome === null) return result;
        if (outcome.length === 2) { next.push(outcome[0]); losers.push(outcome[1]); }
      }
      winners = next;
    }
    while (losers.length > 1) {
      const next = [];
      for (let i = 0; i < losers.length; i += 2) {
        if (i + 1 === losers.length) { next.push(losers[i]); result.byes.push(losers[i]); continue; }
        const outcome = play(losers[i], losers[i + 1], 'consolation');
        if (outcome === null) return result;
        if (outcome.length === 2) next.push(outcome[0]);
      }
      losers = next;
    }
    if (winners.length && losers.length) {
      const w = winners[0], l = losers[0], final = play(w, l, 'grand-final');
      if (final === null || final.length !== 2) return result;
      if (final[0] === l) {
        const reset = play(w, l, 'final-reset');
        if (reset === null) return result;
        if (reset.length === 2) { result.champion = reset[0]; result.runnerUp = reset[1]; }
      } else { result.champion = w; result.runnerUp = l; }
    } else result.champion = winners[0] || losers[0] || null;
    return result;
  }
  function answer(participants, state, match, choice, note = '', revise = false, at = new Date().toISOString()) {
    if (!['a', 'b', 'tie', 'neither', 'defer'].includes(choice) || typeof note !== 'string' || note.length > 4000) throw Error('Invalid choice or note.');
    const next = clone(state), current = view(participants, next.decisions);
    if (revise) {
      const index = current.matches.findIndex(m => m.id === match);
      if (index < 0) throw Error('Unknown match.');
      const invalidated = new Set(current.matches.slice(index).map(m => m.id));
      next.decisions = next.decisions.filter(v => !invalidated.has(v.match));
      next.history.push({match, choice: 'revision', note: 'Dependent decisions invalidated. ' + note, at});
    }
    if (view(participants, next.decisions).pending?.id !== match) throw Error('This match is no longer pending.');
    const vote = {match, choice, note, at};
    next.decisions.push(vote); next.history.push(vote);
    const rejected = view(participants, next.decisions).rejected;
    next.retained = next.retained.filter(id => !rejected.includes(id));
    if (next.history.length > 10000) throw Error('Progress history is too large.');
    return next;
  }
  function validate(seed, state) {
    if (state.version !== 1 || state.runID !== seed.runID || !/^[a-f0-9]{64}$/.test(state.sourceRevision || '') ||
        !Array.isArray(state.decisions) || !Array.isArray(state.history) || !Array.isArray(state.retained) ||
        state.history.length > 10000 || state.decisions.length > 10000) throw Error('This progress file belongs to another bracket or version.');
    let replay = {...clone(state), decisions: [], history: [], retained: []}, revision = null;
    for (const vote of state.history) {
      if (typeof vote.at !== 'string' || vote.at.length > 64 || typeof vote.note !== 'string' || vote.note.length > 4100) throw Error('Invalid progress history.');
      if (vote.choice === 'revision') { if (revision) throw Error('Unfinished revision.'); revision = vote; continue; }
      if (revision && revision.match !== vote.match) throw Error('Revision target changed.');
      replay = answer(seed.participants, replay, vote.match, vote.choice, vote.note, !!revision, vote.at);
      if (revision) {
        const marker = replay.history.at(-2);
        if (marker.note !== revision.note) throw Error('Invalid revision history.');
        marker.at = revision.at;
      }
      revision = null;
    }
    const equalVotes = (a, b) => a.length === b.length && a.every((v, i) => ['match', 'choice', 'note', 'at'].every(k => v[k] === b[i][k]));
    if (revision || !equalVotes(replay.decisions, state.decisions)) throw Error('Progress and history disagree.');
    const roster = new Set(seed.participants.map(p => p.id)), rejected = view(seed.participants, state.decisions).rejected;
    if (new Set(state.retained).size !== state.retained.length || state.retained.some(id => !roster.has(id) || rejected.includes(id))) throw Error('Invalid retained narrator.');
    return clone(state);
  }
  function shortlist(participants, state) {
    const current = view(participants, state.decisions), ids = [];
    if (current.pending) throw Error('Finish the bracket first.');
    for (const id of [current.champion, current.runnerUp, ...current.eliminated.slice().reverse()].filter(Boolean)) {
      if (!ids.includes(id) && !current.rejected.includes(id)) ids.push(id);
      if (ids.length === 4) break;
    }
    for (const id of state.retained) if (!ids.includes(id) && !current.rejected.includes(id)) ids.push(id);
    return ids;
  }
  global.BracketEngine = {view, answer, validate, shortlist};
})(globalThis);
