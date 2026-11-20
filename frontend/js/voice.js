'use strict';
/*
 * Voice assistant: ask StockMate questions by typing or by voice, optionally with a wake phrase.
 *
 *  - Wake phrase: "Hey StockMate" (also "OK StockMate" or just "StockMate"). Turned OFF by default; the person switches it on.
 *    It uses the browser's speech recognition (Chrome / Edge). Those browsers send the microphone audio to their own speech service,
 *    and listening only happens while this page is open and the switch is on.
 *  - The question goes to POST /api/assistant. The server answers common business questions itself (read-only, role-checked)
 *    and, if an OpenJarvis server is configured, hands other questions to it.
 *  - Answers are shown on screen and read aloud with the browser's speech synthesis.
 */

const WAKE_RE = /\b(?:(?:hey|hay|ok|okay|hi|hello)\s+)?stockmate\b/;

/** Returns null if the wake phrase was not said, otherwise the command after it ('' if nothing followed). */
function extractCommand(transcript) {
  const t = String(transcript || '').toLowerCase().replace(/stock\s+mate/g, 'stockmate').replace(/[^a-z0-9' ]/g, ' ').replace(/\s+/g, ' ').trim();
  const m = WAKE_RE.exec(t);
  return m ? t.slice(m.index + m[0].length).trim() : null;
}

const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
const voice = { rec: null, wake: false, state: 'idle', awaitTimer: null, speakOn: true, wired: false, busy: false };

function voiceEls() {
  const p = document.getElementById('voicePanel');
  return { panel: p, log: p.querySelector('.v-log'), status: p.querySelector('.v-status'), input: p.querySelector('.v-input'),
    wakeBox: p.querySelector('.v-wake'), speakBox: p.querySelector('.v-speak') };
}

function voiceLog(who, text, source) {
  const { log } = voiceEls();
  log.append(h('div', { class: 'v-msg ' + who }, h('span', {}, text), source === 'openjarvis' ? h('small', { class: 'muted' }, ' · via OpenJarvis') : null));
  log.scrollTop = log.scrollHeight;
}
function voiceStatus(t) { voiceEls().status.textContent = t; }

function speak(text, then) {
  if (!voice.speakOn || !('speechSynthesis' in window)) { if (then) then(); return; }
  try {
    speechSynthesis.cancel();
    const u = new SpeechSynthesisUtterance(text);
    u.lang = 'en-IN';
    u.onend = u.onerror = () => { if (then) then(); };
    speechSynthesis.speak(u);
  } catch (e) { if (then) then(); }
}

async function askAssistant(text) {
  text = String(text || '').trim();
  if (!text) return;
  voiceLog('me', text);
  voice.busy = true;
  voiceStatus('Thinking…');
  let reply;
  try {
    const res = await api('POST', '/assistant', { text });
    voiceLog('bot', res.reply, res.source);
    reply = res.reply;
  } catch (e) {
    voiceLog('bot', 'Sorry, that did not work: ' + e.message);
    reply = null;
  }
  voice.busy = false;
  voiceStatus(voice.wake ? 'Listening for "Hey StockMate"…' : 'Ready');
  if (reply) {
    // the microphone is paused while the answer is spoken so the assistant does not hear itself
    pauseRecognition();
    speak(reply, resumeRecognition);
  }
}

// ---- wake-phrase listening
function handleHeard(transcript) {
  if (voice.busy) return;
  if (voice.state === 'awaiting') {
    clearTimeout(voice.awaitTimer); voice.state = 'idle';
    askAssistant(transcript);
    return;
  }
  const cmd = extractCommand(transcript);
  if (cmd === null) return;                     // not for us: ignore, nothing is stored or sent
  if (cmd) { askAssistant(cmd); return; }
  voice.state = 'awaiting';
  voiceStatus('Yes? Ask your question…');
  voiceLog('bot', 'Yes?');
  clearTimeout(voice.awaitTimer);
  voice.awaitTimer = setTimeout(() => { voice.state = 'idle'; voiceStatus('Listening for "Hey StockMate"…'); }, 8000);
}

let paused = false;
function pauseRecognition() { paused = true; try { voice.rec && voice.rec.stop(); } catch (e) { /* not running */ } }
function resumeRecognition() { paused = false; if (voice.wake) startRecognition(); }

function startRecognition() {
  if (!SR || !voice.wake || paused) return;
  if (!voice.rec) {
    const rec = new SR();
    rec.continuous = true; rec.interimResults = false; rec.lang = 'en-IN';
    rec.onresult = ev => {
      for (let i = ev.resultIndex; i < ev.results.length; i++) if (ev.results[i].isFinal) handleHeard(ev.results[i][0].transcript);
    };
    rec.onerror = ev => {
      if (ev.error === 'not-allowed' || ev.error === 'service-not-allowed') {
        setWake(false); voiceStatus('Microphone permission was denied. Allow it in the browser to use the wake phrase.');
      }
    };
    rec.onend = () => { if (voice.wake && !paused) setTimeout(startRecognition, 300); };   // browsers stop after silence; keep going
    voice.rec = rec;
  }
  try { voice.rec.start(); } catch (e) { /* already started */ }
}

function setWake(on) {
  voice.wake = on;
  const { wakeBox } = voiceEls();
  wakeBox.checked = on;
  if (on) { voiceStatus('Listening for "Hey StockMate"…'); startRecognition(); }
  else { voice.state = 'idle'; pauseRecognition(); paused = false; voiceStatus('Ready'); }
  document.getElementById('voiceBtn').classList.toggle('listening', on);
}

function stopVoice() {
  if (!voice.wired) return;
  setWake(false);
  try { speechSynthesis.cancel(); } catch (e) { /* none */ }
  const { panel } = voiceEls(); panel.hidden = true;
  document.getElementById('voiceBtn').setAttribute('aria-expanded', 'false');
  voiceEls().log.replaceChildren();
}

function initVoice() {
  const panel = document.getElementById('voicePanel');
  const btn = document.getElementById('voiceBtn');
  if (!voice.wired) {
    voice.wired = true;
    const input = h('input', { class: 'v-input', type: 'text', placeholder: 'Ask: how much stock of cartridges?', 'aria-label': 'Ask the assistant', autocomplete: 'off' });
    const form = h('form', { class: 'v-form', onsubmit: e => { e.preventDefault(); const t = input.value; input.value = ''; askAssistant(t); } },
      input, h('button', { class: 'btn primary', type: 'submit' }, 'Ask'));
    const mic = h('button', { class: 'btn', type: 'button', 'aria-label': 'Speak one question', title: 'Speak one question',
      onclick: () => oneShot() }, '🎤');
    panel.append(
      h('div', { class: 'v-head' }, h('strong', {}, 'Assistant'), h('span', { class: 'grow' }),
        h('button', { class: 'btn small ghost', type: 'button', 'aria-label': 'Close assistant', onclick: () => toggleVoice(false) }, '✕')),
      h('div', { class: 'v-log', role: 'log', 'aria-live': 'polite' }),
      h('p', { class: 'v-status muted', role: 'status' }, 'Ready'),
      h('div', { class: 'v-row' }, form, SR ? mic : null),
      SR ? h('label', { class: 'check' }, h('input', { type: 'checkbox', class: 'v-wake', onchange: e => setWake(e.target.checked) }), 'Listen for the wake phrase "Hey StockMate"') : h('input', { type: 'checkbox', class: 'v-wake', hidden: true }),
      h('label', { class: 'check' }, h('input', { type: 'checkbox', class: 'v-speak', checked: true, onchange: e => { voice.speakOn = e.target.checked; if (!voice.speakOn) try { speechSynthesis.cancel(); } catch (x) { /* none */ } } }), 'Read answers aloud'),
      h('p', { class: 'muted v-note' }, SR
        ? 'Voice recognition uses your browser’s speech service (Chrome or Edge); the microphone is only used while the wake-phrase switch is on or after you press 🎤.'
        : 'Voice input needs Chrome or Edge. You can still type questions here.'));
    btn.addEventListener('click', () => toggleVoice(panel.hidden));
  }
  btn.hidden = false;
  voice.openjarvis = !!(ME && ME.openjarvis);
  if (!voiceEls().log.children.length) voiceLog('bot', 'Ask me about stock, low stock, overdue invoices, expiring lots or today’s sales.' + (voice.openjarvis ? ' Other questions go to OpenJarvis.' : ''));
}

function toggleVoice(open) {
  const { panel, input } = voiceEls();
  panel.hidden = !open;
  document.getElementById('voiceBtn').setAttribute('aria-expanded', String(open));
  if (open) input.focus(); else setWake(false);
}

// one spoken question without the wake phrase
function oneShot() {
  if (!SR) return;
  pauseRecognition();
  const rec = new SR();
  rec.lang = 'en-IN'; rec.interimResults = false; rec.maxAlternatives = 1;
  voiceStatus('Listening…');
  rec.onresult = ev => askAssistant(ev.results[0][0].transcript);
  rec.onerror = ev => voiceStatus(ev.error === 'not-allowed' ? 'Microphone permission was denied.' : 'Did not catch that. Try again.');
  rec.onend = () => { if (!voice.busy) voiceStatus(voice.wake ? 'Listening for "Hey StockMate"…' : 'Ready'); if (voice.wake) resumeRecognition(); else paused = false; };
  try { rec.start(); } catch (e) { voiceStatus('Could not start the microphone.'); }
}

window.StockMateVoice = { extractCommand, ask: askAssistant, handleHeard };
