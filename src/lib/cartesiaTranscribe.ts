const CARTESIA_TRANSCRIPTION_URL = 'https://api.cartesia.ai/stt'
const CARTESIA_VERSION = '2026-03-01'
const CARTESIA_MODEL = 'ink-whisper'
const CARTESIA_LANGUAGE = 'en'

const FILLER_WORDS =
  /\b(?:um+|uh+|erm+|ah+|hmm+|mm+|you know|i mean|sort of|kind of)\b[,\s]*/gi

const PUNCTUATION_WORDS: Array<[RegExp, string]> = [
  [/\s+(?:full stop|period)\b/gi, '.'],
  [/\s+comma\b/gi, ','],
  [/\s+question mark\b/gi, '?'],
  [/\s+exclamation mark\b/gi, '!'],
  [/\s+(?:colon)\b/gi, ':'],
  [/\s+(?:semicolon)\b/gi, ';'],
  [/\s+(?:new paragraph|new line)\b/gi, '\n\n'],
]

function tidySpacing(text: string): string {
  return text
    .replace(/[ \t]+/g, ' ')
    .replace(/\s+([,.;:!?])/g, '$1')
    .replace(/([,.;:!?])([^\s\n])/g, '$1 $2')
    .replace(/\s*\n\s*/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim()
}

function applySpokenPunctuation(text: string): string {
  return PUNCTUATION_WORDS.reduce(
    (next, [pattern, replacement]) => next.replace(pattern, replacement),
    text,
  )
}

function applyChangeOfMindCorrections(text: string): string {
  let next = text

  next = next.replace(
    /\b(at|by|around|about|for|on)\s+([^,.;!?]{1,40}?)\s*(?:\.{3}|,)?\s*(?:actually|no|sorry|rather)\s+([^,.;!?]{1,40}?)(?=([,.;!?])|\s+(?:and|but|so|then|because|when|if)\b|$)/gi,
    (_match, preposition: string, _oldValue: string, newValue: string) =>
      `${preposition} ${newValue.trim()}`,
  )

  next = next.replace(
    /\b([^,.;!?]{1,50}?)\s*(?:\.{3}|,)?\s*(?:actually|no|sorry|rather|i mean)\s+([^,.;!?]{1,50}?)(?=([,.;!?])|\s+(?:and|but|so|then|because|when|if)\b|$)/gi,
    (_match, _oldValue: string, newValue: string) => newValue.trim(),
  )

  return next
}

function sentenceCase(text: string): string {
  return text.replace(/(^|[.!?]\s+|\n\n)([a-z])/g, (_match, prefix, letter) => {
    return `${prefix}${letter.toUpperCase()}`
  })
}

export function polishDictation(rawText: string): string {
  let text = rawText.trim()
  if (!text) return ''

  text = applySpokenPunctuation(text)
  text = applyChangeOfMindCorrections(text)
  text = text.replace(FILLER_WORDS, '')
  text = tidySpacing(text)
  text = sentenceCase(text)

  if (text && !/[.!?]$/.test(text)) {
    text += '.'
  }

  return text
}

export async function transcribeWithCartesia(
  audio: Blob,
  apiKey: string,
): Promise<string> {
  const key = apiKey.trim()
  if (!key) {
    throw new Error('Add your Cartesia API key first.')
  }

  const form = new FormData()
  form.append('file', audio, 'recording.webm')
  form.append('model', CARTESIA_MODEL)
  form.append('language', CARTESIA_LANGUAGE)

  const res = await fetch(CARTESIA_TRANSCRIPTION_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${key}`,
      'Cartesia-Version': CARTESIA_VERSION,
    },
    body: form,
  })

  if (!res.ok) {
    let message = `Cartesia request failed (${res.status})`
    try {
      const data = await res.json()
      if (data?.message) message = data.message
      if (data?.title && data?.message) message = `${data.title}: ${data.message}`
    } catch {
      // ignore parse errors, fall back to status message
    }
    throw new Error(message)
  }

  const data = (await res.json()) as { text?: string }
  return (data.text ?? '').trim()
}
