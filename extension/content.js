const CARTESIA_TRANSCRIPTION_URL = 'https://api.cartesia.ai/stt';
const CARTESIA_VERSION = '2026-03-01';
const CARTESIA_MODEL = 'ink-whisper';
const CARTESIA_LANGUAGE = 'en';
const FILLER_WORDS = /\b(?:um+|uh+|erm+|ah+|hmm+|mm+|you know|i mean|sort of|kind of)\b[,\s]*/gi;
const PUNCTUATION_WORDS = [
  [/\s+(?:full stop|period)\b/gi, '.'],
  [/\s+comma\b/gi, ','],
  [/\s+question mark\b/gi, '?'],
  [/\s+exclamation mark\b/gi, '!'],
  [/\s+(?:colon)\b/gi, ':'],
  [/\s+(?:semicolon)\b/gi, ';'],
  [/\s+(?:new paragraph|new line)\b/gi, '\n\n'],
];

let recorder = null;
let stream = null;
let chunks = [];
let activeTarget = null;
let recordingStartedAt = 0;

function getCartesiaKey() {
  return new Promise((resolve) => {
    chrome.storage.sync.get(['cartesiaKey'], (data) => resolve(data.cartesiaKey ?? ''));
  });
}

function tidySpacing(text) {
  return text
    .replace(/[ \t]+/g, ' ')
    .replace(/\s+([,.;:!?])/g, '$1')
    .replace(/([,.;:!?])([^\s\n])/g, '$1 $2')
    .replace(/\s*\n\s*/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
}

function applySpokenPunctuation(text) {
  return PUNCTUATION_WORDS.reduce(
    (next, [pattern, replacement]) => next.replace(pattern, replacement),
    text,
  );
}

function applyChangeOfMindCorrections(text) {
  return text
    .replace(
      /\b(at|by|around|about|for|on)\s+([^,.;!?]{1,40}?)\s*(?:\.{3}|,)?\s*(?:actually|no|sorry|rather)\s+([^,.;!?]{1,40}?)(?=([,.;!?])|\s+(?:and|but|so|then|because|when|if)\b|$)/gi,
      (_match, preposition, _oldValue, newValue) => `${preposition} ${newValue.trim()}`,
    )
    .replace(
      /\b([^,.;!?]{1,50}?)\s*(?:\.{3}|,)?\s*(?:actually|no|sorry|rather|i mean)\s+([^,.;!?]{1,50}?)(?=([,.;!?])|\s+(?:and|but|so|then|because|when|if)\b|$)/gi,
      (_match, _oldValue, newValue) => newValue.trim(),
    );
}

function sentenceCase(text) {
  return text.replace(/(^|[.!?]\s+|\n\n)([a-z])/g, (_match, prefix, letter) => {
    return `${prefix}${letter.toUpperCase()}`;
  });
}

function polishDictation(rawText) {
  let text = rawText.trim();
  if (!text) return '';

  text = applySpokenPunctuation(text);
  text = applyChangeOfMindCorrections(text);
  text = text.replace(FILLER_WORDS, '');
  text = tidySpacing(text);
  text = sentenceCase(text);

  if (text && !/[.!?]$/.test(text)) {
    text += '.';
  }

  return text;
}

async function transcribeWithCartesia(audio, apiKey) {
  const key = apiKey.trim();
  if (!key) {
    throw new Error('Add your Cartesia API key in the Voi extension popup.');
  }

  const form = new FormData();
  form.append('file', audio, 'recording.webm');
  form.append('model', CARTESIA_MODEL);
  form.append('language', CARTESIA_LANGUAGE);

  const res = await fetch(CARTESIA_TRANSCRIPTION_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${key}`,
      'Cartesia-Version': CARTESIA_VERSION,
    },
    body: form,
  });

  if (!res.ok) {
    let message = `Transcription failed (${res.status}).`;
    try {
      const data = await res.json();
      if (data?.message) message = data.message;
      if (data?.title && data?.message) message = `${data.title}: ${data.message}`;
    } catch {
      // keep status fallback
    }
    throw new Error(message);
  }

  const data = await res.json();
  return (data.text ?? '').trim();
}

function isTextTarget(element) {
  if (!element) return false;
  if (element.isContentEditable) return true;
  if (element instanceof HTMLTextAreaElement) return true;
  if (!(element instanceof HTMLInputElement)) return false;
  return ['email', 'number', 'password', 'search', 'tel', 'text', 'url'].includes(element.type);
}

function insertText(target, text) {
  target.focus();

  if (target.isContentEditable) {
    document.execCommand('insertText', false, text);
    target.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
    return;
  }

  if (target instanceof HTMLInputElement || target instanceof HTMLTextAreaElement) {
    const start = target.selectionStart ?? target.value.length;
    const end = target.selectionEnd ?? target.value.length;
    const before = target.value.slice(0, start);
    const after = target.value.slice(end);
    const separator = before && !/\s$/.test(before) ? ' ' : '';
    target.value = `${before}${separator}${text}${after}`;
    const nextCursor = before.length + separator.length + text.length;
    target.setSelectionRange(nextCursor, nextCursor);
    target.dispatchEvent(new InputEvent('input', { bubbles: true, inputType: 'insertText', data: text }));
  }
}

function setStatus(message) {
  document.querySelector('#voi-status').textContent = message;
}

function setButtonState(state) {
  document.querySelector('#voi-button').dataset.state = state;
}

async function startRecording() {
  activeTarget = document.activeElement;
  if (!isTextTarget(activeTarget)) {
    setStatus('Click into a text field first');
    return;
  }

  chunks = [];
  stream = await navigator.mediaDevices.getUserMedia({ audio: true });
  recorder = new MediaRecorder(stream);
  recorder.addEventListener('dataavailable', (event) => {
    if (event.data.size > 0) chunks.push(event.data);
  });
  recorder.addEventListener('stop', finishRecording, { once: true });
  recordingStartedAt = Date.now();
  recorder.start();
  setButtonState('recording');
  setStatus('Listening...');
}

async function finishRecording() {
  stream?.getTracks().forEach((track) => track.stop());
  stream = null;
  recorder = null;

  if (Date.now() - recordingStartedAt < 350) {
    setButtonState('idle');
    setStatus('Ready');
    return;
  }

  setButtonState('idle');
  setStatus('Polishing...');

  try {
    const key = await getCartesiaKey();
    const audio = new Blob(chunks, { type: 'audio/webm' });
    const rawText = await transcribeWithCartesia(audio, key);
    const polished = polishDictation(rawText);
    insertText(activeTarget, polished);
    setStatus('Inserted');
    setTimeout(() => setStatus('Ready'), 1400);
  } catch (error) {
    setStatus(error instanceof Error ? error.message : 'Something went wrong');
  }
}

function toggleRecording() {
  if (recorder && recorder.state === 'recording') {
    recorder.stop();
    return;
  }

  startRecording().catch((error) => {
    setButtonState('idle');
    setStatus(error instanceof Error ? error.message : 'Mic access failed');
  });
}

function mount() {
  if (document.querySelector('#voi-root')) return;

  const root = document.createElement('div');
  root.id = 'voi-root';
  root.innerHTML = `
    <div class="voi-panel">
      <span class="voi-status" id="voi-status">Ready</span>
      <button class="voi-button" id="voi-button" type="button" aria-label="Start Voi dictation" data-state="idle">
        <svg width="22" height="22" viewBox="0 0 24 24" fill="none" aria-hidden="true">
          <rect x="9" y="2" width="6" height="12" rx="3" fill="currentColor"></rect>
          <path d="M5 11a7 7 0 0 0 14 0" stroke="currentColor" stroke-width="2" stroke-linecap="round"></path>
          <line x1="12" y1="18" x2="12" y2="22" stroke="currentColor" stroke-width="2" stroke-linecap="round"></line>
        </svg>
      </button>
    </div>
  `;

  document.body.appendChild(root);
  document.querySelector('#voi-button').addEventListener('click', toggleRecording);
}

mount();
