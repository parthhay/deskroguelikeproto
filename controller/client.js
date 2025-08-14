console.log('client.js v7 loaded');

(() => {
  const status = document.getElementById('status');
  const enemiesEl = document.getElementById('enemies');
  const handEl = document.getElementById('hand');
  const targetEl = document.getElementById('target');
  const nameEl = document.getElementById('name');
  const claimBtn = document.getElementById('claim');
  const startBtn = document.getElementById('start');

  let playerId = null;
  let token = null;
  let turnPlayer = null;
  let runOver = false;

  // --- HTTP helper: always parse JSON, even on errors
  async function api(path, opts = {}) {
    const res = await fetch(path, Object.assign({ headers: {'Content-Type':'application/json'} }, opts));
    let payload = null;
    try { payload = await res.json(); } catch(_) { /* no-op */ }
    if (!res.ok) {
      const code = payload && payload.error ? payload.error : ('HTTP ' + res.status);
      const err = new Error(code);
      err.payload = payload;
      throw err;
    }
    return payload || {};
  }

  function requiresEnemyTarget(card) {
    return card === 'Strike' || card === 'Zap';
  }

  function fmtSlot(s) {
    if (!s || !s.occupied) return '—';
    return s.name || 'Player';
  }

  function setStatus(text) {
    status.textContent = text;
  }

  async function refreshLobby() {
    try {
      const data = await api('/lobby');
      const slots = data.slots || {};
      const lobbyStr = `Lobby: [1] ${fmtSlot(slots['1'])} | [2] ${fmtSlot(slots['2'])} | [3] ${fmtSlot(slots['3'])}`;
      // Don’t overwrite turn/run status if we already have it
      if (playerId == null) setStatus(lobbyStr);
    } catch {
      if (playerId == null) setStatus('Can’t reach host.');
    }
  }

  async function claim() {
    try {
      const data = await api('/claim', {
        method: 'POST',
        body: JSON.stringify({ name: (nameEl.value || 'Player').slice(0,20) })
      });
      playerId = data.player_id;
      token = data.token;
      renderHand(data.hand || []);
      await refreshState();
    } catch (e) {
      alert('Join failed (lobby full or host down).');
    }
  }

  async function startRun() {
    console.log('[CLIENT] Start button clicked');
    try {
      // optimistic UI so it feels responsive
      startBtn.textContent = 'Restart Run';
      targetEl.value = 'none';
      await api('/start', { method: 'POST', body: JSON.stringify({ player_id: playerId || 0 }) });
      console.log('[CLIENT] /start succeeded');
      await refreshState();
    } catch (e) {
      console.warn('[CLIENT] /start failed', e);
      alert('Could not start run.');
      // revert label if needed
      startBtn.textContent = 'Start Run';
    }
  }

  async function refreshState() {
    try {
      const data = await api(`/state?player_id=${playerId || 0}`);
      turnPlayer = data.turn_player;
      runOver = !!data.run_over;

      renderEnemies(data.enemies || []);
      renderTargets(data.enemies || []);
      renderHand(data.your_hand || []);

      const yourTurn = (turnPlayer === playerId);
      const waveStr = data.wave ? ` — Wave ${data.wave}` : '';
      const piles = (data.deck_count != null && data.discard_count != null)
        ? ` — Deck ${data.deck_count} / Discard ${data.discard_count}` : '';
      const ro = runOver ? ' (Run Over)' : '';

      // Label the button
      startBtn.textContent = runOver ? 'Restart Run' : 'Start Run';

      setStatus(
        (playerId
          ? (yourTurn ? `Your turn (P${playerId})` : `Waiting… It’s Player ${turnPlayer}’s turn`)
          : 'Not joined') + waveStr + ro + piles
      );
    } catch {
      // ignore; polling will recover
    }
  }

  async function play(card) {
    if (!playerId || !token || runOver) return;

    // If the card needs a target and none is selected, auto-pick the first enemy.
    let target = targetEl.value;
    if (requiresEnemyTarget(card) && (!target || target === 'none')) {
      // Ask the server what enemies are currently alive to avoid stale UI.
      try {
        const state = await api(`/state?player_id=${playerId}`);
        const firstEnemy = (state.enemies || [])[0];
        if (!firstEnemy) {
          alert('No enemy to target.');
          return;
        }
        target = `enemy_${firstEnemy.id}`;
        // reflect in UI so the user sees the choice
        targetEl.value = target;
      } catch {
        alert('Could not fetch state to auto-select a target.');
        return;
      }
    }

    try {
      const data = await api('/play_card', {
        method: 'POST',
        body: JSON.stringify({ player_id: playerId, token, card, target })
      });
      // Update local state from server response
      turnPlayer = data.turn_player;
      runOver = !!data.run_over;
      renderEnemies(data.enemies || []);
      renderTargets(data.enemies || []);
      renderHand(data.your_hand || []);
      const yourTurn = (turnPlayer === playerId);
      const waveStr = data.wave ? ` — Wave ${data.wave}` : '';
      const ro = runOver ? ' (Run Over)' : '';
      setStatus((yourTurn ? `Your turn (P${playerId})` : `Waiting… It’s Player ${turnPlayer}’s turn`) + waveStr + ro);
    } catch (e) {
      const code = e && e.message ? e.message : 'play_failed';
      // Server may respond with structured error codes like not_your_turn / bad_token / need_enemy_target.
      alert('Play failed: ' + code);
      await refreshState();
    }
  }

  function renderEnemies(enemies) {
    enemiesEl.innerHTML = '';
    if (!enemies.length) {
      enemiesEl.textContent = '(No enemies on field)';
      return;
    }
    enemies.forEach(e => {
      const div = document.createElement('div');
      const bossTag = e.is_boss ? ` [BOSS: ${e.phase}]` : '';
      div.textContent = `${e.name}${bossTag} — HP ${e.hp}/${e.max_hp}`;
      enemiesEl.appendChild(div);
    });
  }

  function renderTargets(enemies) {
    const current = targetEl.value;
    targetEl.innerHTML = '';
    const none = document.createElement('option');
    none.value = 'none';
    none.textContent = 'none';
    targetEl.appendChild(none);
    enemies.forEach(e => {
      const opt = document.createElement('option');
      opt.value = `enemy_${e.id}`;
      opt.textContent = `${e.name}`;
      targetEl.appendChild(opt);
    });
    // keep previous selection if still valid; else leave "none"
    const opts = Array.from(targetEl.options).map(o => o.value);
    if (opts.includes(current)) targetEl.value = current;
  }

  function renderHand(cards) {
    handEl.innerHTML = '';
    const yourTurn = (turnPlayer === playerId);
    const disabled = !yourTurn || runOver;
    cards.forEach(card => {
      const btn = document.createElement('button');
      btn.className = 'card';
      btn.textContent = card;
      btn.disabled = disabled;
      btn.onclick = () => play(card);
      handEl.appendChild(btn);
    });
    if (!cards.length) {
      const p = document.createElement('div');
      p.textContent = '(No cards left in hand)';
      handEl.appendChild(p);
    }
  }

  claimBtn.addEventListener('click', claim);
  startBtn.textContent = runOver ? 'Restart Run' : 'Start Run';
  refreshLobby();
  setInterval(refreshLobby, 4000);
  setInterval(refreshState, 1800);
})();
