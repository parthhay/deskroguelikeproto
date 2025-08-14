(() => {
  console.log('client.js v9 (WS + HTTP fallback)');
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
  let lastVer = -1;
  let pollDelay = 1500;
  let pollTimer = null;

  function schedulePoll(ms) {
    if (pollTimer) clearTimeout(pollTimer);
    pollDelay = ms;
    pollTimer = setTimeout(refreshState, pollDelay);
  }
  // --- HTTP helpers ---
  async function api(path, opts={}) {
    const res = await fetch(path, Object.assign({ headers: {'Content-Type':'application/json'} }, opts));
    const data = await res.json().catch(()=> ({}));
    if (!res.ok) throw new Error(data && data.error ? data.error : ('HTTP '+res.status));
    return data;
  }

  // --- WebSocket overlay ---
  let ws = null;
  let wsOpen = false;
  let reconnectTimer = null;

  function connectWS() {
    try {
      const host = location.hostname;
      const url = `ws://${host}:8081`;
      ws = new WebSocket(url);

      ws.addEventListener('open', () => {
        wsOpen = true;
        console.log('[WS] open', url);
        if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
        // If we already have a name, we can claim on click; nothing to send yet.
      });

      ws.addEventListener('message', (ev) => {
        let msg = {};
        try { msg = JSON.parse(ev.data); } catch { return; }
        handleWS(msg);
      });

      ws.addEventListener('close', () => {
        console.log('[WS] closed; falling back to HTTP');
        wsOpen = false;
        reconnectTimer = setTimeout(connectWS, 2000);
      });

      ws.addEventListener('error', () => {
        console.log('[WS] error');
      });
    } catch (e) {
      console.log('[WS] connect error', e);
    }
  }

  function wssend(obj) {
    if (wsOpen && ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(obj));
      return true;
    }
    return false;
  }

  function handleWS(msg) {
    switch (msg.type) {
      case 'welcome':
        break;
      case 'claim_ok':
        playerId = msg.player_id;
        token = msg.token;
        renderHand(msg.hand || []);
        break;
      case 'state':
        applyState(msg);
        break;
      case 'error':
        alert('WS error: ' + msg.code);
        break;
    }
  }

  // --- UI/state ---
  function requiresEnemyTarget(card) { return card === 'Strike' || card === 'Zap'; }
  function setStatus(text) { status.textContent = text; }

  function applyState(st) {
    turnPlayer = st.turn_player;
    runOver = !!st.run_over;

    renderEnemies(st.enemies || []);
    renderTargets(st.enemies || []);
    renderHand(st.your_hand || []);

    const yourTurn = (turnPlayer === playerId);
    const waveStr = st.wave ? ` — Wave ${st.wave}` : '';
    const piles = (st.deck_count!=null && st.discard_count!=null) ? ` — Deck ${st.deck_count} / Discard ${st.discard_count}` : '';
    const ro = runOver ? ' (Run Over)' : '';
    startBtn.textContent = runOver ? 'Restart Run' : 'Start Run';
    setStatus((playerId ? (yourTurn ? `Your turn (P${playerId})` : `Waiting… It’s Player ${turnPlayer}’s turn`) : 'Not joined') + waveStr + ro + piles);

    // Adaptive polling: fast on changes / your turn, back off when idle
    if (st.ver != null) {
      if (st.ver !== lastVer) {
        lastVer = st.ver;
        const base = yourTurn ? 350 : 1200;
        schedulePoll(base);
      } else {
        schedulePoll(Math.min(3000, pollDelay + 400));
      }
    } else {
      // Fallback if ver is missing for any reason
      schedulePoll(yourTurn ? 500 : 2000);
    }
  }


  function renderEnemies(enemies) {
    enemiesEl.innerHTML = '';
    if (!enemies.length) { enemiesEl.textContent = '(No enemies on field)'; return; }
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
    const none = document.createElement('option'); none.value = 'none'; none.textContent = 'none';
    targetEl.appendChild(none);
    enemies.forEach(e => {
      const opt = document.createElement('option');
      opt.value = `enemy_${e.id}`;
      opt.textContent = e.name;
      targetEl.appendChild(opt);
    });
    if (Array.from(targetEl.options).some(o => o.value === current)) targetEl.value = current;
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

  // --- Actions (WS first, HTTP fallback) ---
  async function claim() {
    const nm = (nameEl.value || 'Player').slice(0,20);
    if (wssend({type:'claim', name:nm})) return;
    // HTTP fallback
    const data = await api('/claim', { method:'POST', body: JSON.stringify({name: nm}) });
    playerId = data.player_id; token = data.token;
    renderHand(data.hand || []); await refreshState();
  }

  async function startRun() {
    // optimistic label
    startBtn.textContent = 'Restart Run';
    targetEl.value = 'none';
    if (wssend({type:'start'})) return; // WS will push a state to us
    // HTTP fallback
    await api('/start', { method: 'POST', body: JSON.stringify({ player_id: playerId || 0 }) });
    await refreshState();
  }

  async function play(card) {
    if (!playerId || !token || runOver) return;
    let target = targetEl.value;
    if (requiresEnemyTarget(card) && (!target || target === 'none')) {
      // pick first enemy via quick state fetch fallback
      try {
        const st = await api(`/state?player_id=${playerId}`);
        const first = (st.enemies || [])[0];
        if (first) { target = `enemy_${first.id}`; targetEl.value = target; }
        else { alert('No enemy to target.'); return; }
      } catch { /* ignore */ }
    }
    if (wssend({type:'play_card', player_id: playerId, token, card, target})) return;
    // HTTP fallback
    try {
      const st = await api('/play_card', { method:'POST', body: JSON.stringify({ player_id: playerId, token, card, target }) });
      applyState(st);
    } catch (e) {
      alert('Play failed: ' + e.message);
      await refreshState();
    }
  }

  // --- HTTP polling stays as a backup ---
  async function refreshState() {
    const st = await api(`/state?player_id=${playerId || 0}`);
    applyState(st);
  }

  // Wire buttons
  claimBtn.addEventListener('click', claim);
  startBtn.addEventListener('click', startRun);

  // Boot
  connectWS();
  schedulePoll(250);  // start light and adapt
})();
