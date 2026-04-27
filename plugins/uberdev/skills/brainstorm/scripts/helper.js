(function() {
  // Bind to 127.0.0.1 loopback only. WebSocket scheme is auto-derived from the
  // page protocol so HTTPS deployments upgrade to the secure variant; the
  // localhost default uses cleartext loopback (no network egress).
  const WS_SCHEME = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
  const WS_URL = WS_SCHEME + '/' + '/' + window.location.host;
  let ws = null;
  let eventQueue = [];
  let locked = false;

  function connect() {
    ws = new WebSocket(WS_URL);

    ws.onopen = () => {
      eventQueue.forEach(e => ws.send(JSON.stringify(e)));
      eventQueue = [];
    };

    ws.onmessage = (msg) => {
      const data = JSON.parse(msg.data);
      if (data.type === 'reload') {
        // New screen pushed by Claude — clear lock state and reload
        window.location.reload();
      }
    };

    ws.onclose = () => {
      setTimeout(connect, 1000);
    };
  }

  function sendEvent(event) {
    event.timestamp = Date.now();
    if (ws && ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(event));
    } else {
      eventQueue.push(event);
    }
  }

  // ===== Safe DOM helpers (no innerHTML for dynamic strings — XSS guard) =====
  function el(tag, attrs, children) {
    const node = document.createElement(tag);
    if (attrs) {
      for (const k in attrs) {
        if (k === 'className') node.className = attrs[k];
        else if (k === 'dataset') {
          for (const dk in attrs.dataset) node.dataset[dk] = attrs.dataset[dk];
        } else {
          node.setAttribute(k, attrs[k]);
        }
      }
    }
    if (children != null) {
      const arr = Array.isArray(children) ? children : [children];
      for (const c of arr) {
        if (c == null) continue;
        node.appendChild(typeof c === 'string' ? document.createTextNode(c) : c);
      }
    }
    return node;
  }

  function clearChildren(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
  }

  // ===== Selection tracking =====
  // Capture clicks on choice elements (exploration clicks)
  document.addEventListener('click', (e) => {
    if (locked) return;
    const target = e.target.closest('[data-choice]');
    if (!target) return;

    sendEvent({
      type: 'click',
      text: target.textContent.trim().slice(0, 240),
      choice: target.dataset.choice,
      id: target.id || null
    });

    setTimeout(updateIndicator, 0);
    setTimeout(updateSubmitButton, 0);
  });

  // Frame UI: selection toggle (called from inline onclick="toggleSelect(this)")
  window.selectedChoice = null;
  window.toggleSelect = function(targetEl) {
    if (locked) return;
    const container = targetEl.closest('.options') || targetEl.closest('.cards');
    const multi = container && container.dataset.multiselect !== undefined;
    if (container && !multi) {
      container.querySelectorAll('.option, .card').forEach(o => o.classList.remove('selected'));
    }
    if (multi) {
      targetEl.classList.toggle('selected');
    } else {
      targetEl.classList.add('selected');
    }
    window.selectedChoice = targetEl.dataset.choice;
  };

  // ===== Lock-in submit button =====
  function ensureSubmitRow() {
    const containers = document.querySelectorAll('.options, .cards');
    if (containers.length === 0) return null;

    let row = document.getElementById('uberdev-submit-row');
    if (row) return row;

    const btn = el('button', {
      id: 'uberdev-submit-btn',
      className: 'submit-btn',
      type: 'button',
      disabled: 'disabled'
    }, '▶ LOCK IN');

    const status = el('span', {
      id: 'uberdev-submit-status',
      className: 'submit-status'
    }, 'Pick an option to enable lock-in');

    row = el('div', {
      id: 'uberdev-submit-row',
      className: 'submit-row'
    }, [btn, status]);

    const lastContainer = containers[containers.length - 1];
    lastContainer.parentNode.insertBefore(row, lastContainer.nextSibling);

    btn.addEventListener('click', lockIn);
    return row;
  }

  function getSelections() {
    // `h3` matches both `.option .content h3` and `.card .card-body h3` —
    // descendant lookup is the default, so a single selector is sufficient.
    return Array.from(document.querySelectorAll('.option.selected, .card.selected'))
      .map(node => ({
        choice: node.dataset.choice,
        label: (node.querySelector('h3')?.textContent || node.dataset.choice || '').trim(),
        id: node.id || null
      }));
  }

  // Short summary for indicator + button labels; e.g. "Login flow" or "3 selections".
  function summarizeSelections(sels) {
    return sels.length === 1 ? sels[0].label : `${sels.length} selections`;
  }

  function updateSubmitButton() {
    const row = ensureSubmitRow();
    if (!row) return;
    const btn = document.getElementById('uberdev-submit-btn');
    const status = document.getElementById('uberdev-submit-status');
    const sels = getSelections();
    status.classList.toggle('locked', locked);

    if (locked) {
      btn.disabled = true;
      btn.textContent = '✓ LOCKED IN';
      status.textContent = sels.length === 1
        ? `Sent: ${sels[0].label} — switch to Claude and hit enter`
        : `Sent ${sels.length} selections — switch to Claude and hit enter`;
      return;
    }

    if (sels.length === 0) {
      btn.disabled = true;
      btn.textContent = '▶ LOCK IN';
      status.textContent = 'Pick an option to enable lock-in';
      return;
    }

    btn.disabled = false;
    btn.textContent = sels.length === 1 ? '▶ LOCK IN' : `▶ LOCK IN ${sels.length}`;
    status.textContent = `Ready: ${summarizeSelections(sels)}`;
  }

  function lockIn() {
    if (locked) return;
    const sels = getSelections();
    if (sels.length === 0) return;

    locked = true;

    // Send a single `submit` event carrying all selections.
    // server.cjs persists any event with a `choice` field to the events file.
    sendEvent({
      type: 'submit',
      choice: sels[0].choice,
      label: sels[0].label,
      selections: sels,
      url: window.location.pathname
    });

    document.querySelectorAll('.option, .card').forEach(node => {
      if (!node.classList.contains('selected')) node.style.opacity = '0.35';
      node.style.pointerEvents = 'none';
      node.style.cursor = 'default';
    });

    updateSubmitButton();
    updateIndicator();
    showWaitingBlock();
  }

  // ===== Waiting / next-phase loader =====
  let waitingTimerHandle = null;
  let waitingStartedAt = 0;

  function formatElapsed(ms) {
    const total = Math.floor(ms / 1000);
    const m = Math.floor(total / 60);
    const s = total % 60;
    return String(m).padStart(2, '0') + ':' + String(s).padStart(2, '0');
  }

  function showWaitingBlock() {
    if (document.getElementById('uberdev-waiting-block')) return;

    const row = document.getElementById('uberdev-submit-row');
    if (!row) return;

    // Phase chips: SELECTED ✓ / SENT ✓ / NEXT (active) / RESULT
    const phaseTrack = el('div', { className: 'phase-track' }, [
      el('span', { className: 'phase-chip done' }, '✓ SELECTED'),
      el('span', { className: 'phase-chip done' }, '✓ SENT'),
      el('span', { className: 'phase-chip active' }, 'AWAITING'),
      el('span', { className: 'phase-chip' }, 'NEXT PHASE')
    ]);

    // Marching bricks loader
    const bricks = el('div', { className: 'brut-bricks' }, [
      el('span'), el('span'), el('span'), el('span'), el('span')
    ]);

    // Status column: phase chips + status text with animated dots
    const statusText = el('div', { className: 'status-text' }, [
      document.createTextNode('WAITING FOR NEXT PHASE'),
      el('span', { className: 'dots' })
    ]);
    const statusCol = el('div', { className: 'col' }, [
      phaseTrack,
      el('div', { className: 'label' }, 'STATUS'),
      statusText
    ]);

    // Timer column
    const timerEl = el('div', { id: 'uberdev-waiting-timer', className: 'timer' }, '00:00');
    const timerCol = el('div', { className: 'timer-col' }, [
      timerEl,
      el('div', { className: 'timer-label' }, 'ELAPSED')
    ]);

    const block = el('div', {
      id: 'uberdev-waiting-block',
      className: 'waiting-block',
      role: 'status',
      'aria-live': 'polite'
    }, [bricks, statusCol, timerCol]);

    row.parentNode.insertBefore(block, row.nextSibling);

    // Start elapsed timer
    waitingStartedAt = Date.now();
    if (waitingTimerHandle) clearInterval(waitingTimerHandle);
    waitingTimerHandle = setInterval(() => {
      const t = document.getElementById('uberdev-waiting-timer');
      if (!t) {
        clearInterval(waitingTimerHandle);
        waitingTimerHandle = null;
        return;
      }
      t.textContent = formatElapsed(Date.now() - waitingStartedAt);
    }, 1000);
  }

  // ===== Indicator bar =====
  function updateIndicator() {
    const indicator = document.getElementById('indicator-text');
    if (!indicator) return;
    const sels = getSelections();

    clearChildren(indicator);

    if (locked) {
      const summary = sels.length === 1 ? sels[0].label : `${sels.length} selections`;
      indicator.appendChild(el('span', { className: 'selected-text' }, `✓ ${summary}`));
      indicator.appendChild(document.createTextNode(' — sent to Claude'));
      return;
    }

    if (sels.length === 0) {
      indicator.textContent = 'CLICK AN OPTION ABOVE — THEN PRESS LOCK IN';
      return;
    }

    const tagText = sels.length === 1 ? sels[0].label : `${sels.length} selected`;
    const trailing = sels.length === 1 ? ' ready — press LOCK IN' : ' — press LOCK IN';
    indicator.appendChild(el('span', { className: 'selected-text' }, tagText));
    indicator.appendChild(document.createTextNode(trailing));
  }

  // ===== Public API for explicit programmatic interaction =====
  window.brainstorm = {
    send: sendEvent,
    choice: (value, metadata = {}) => sendEvent({ type: 'choice', value, ...metadata }),
    lock: lockIn
  };

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => {
      ensureSubmitRow();
      updateSubmitButton();
    });
  } else {
    ensureSubmitRow();
    updateSubmitButton();
  }

  connect();
})();
