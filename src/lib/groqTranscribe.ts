const GROQ_TRANSCRIPTION_URL =
  'https://api.groq.com/openai/v1/audio/transcriptions'

const GROQ_MODEL = 'whisper-large-v3'

export async function transcribeWithGroq(
  audio: Blob,
  apiKey: string,
): Promise<string> {
  const key = apiKey.trim()
  if (!key.startsWith('gsk_')) {
    throw new Error('Invalid Groq API key. Keys start with "gsk_".')
  }

  const form = new FormData()
  form.append('file', audio, 'recording.webm')
  form.append('model', GROQ_MODEL)
  form.append('response_format', 'json')

  const res = await fetch(GROQ_TRANSCRIPTION_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${key}`,
    },
    body: form,
  })

  if (!res.ok) {
    let message = `Groq request failed (${res.status})`
    try {
      const data = await res.json()
      if (data?.error?.message) message = data.error.message
    } catch {
      // ignore parse errors, fall back to status message
    }
    throw new Error(message)
  }

  const data = (await res.json()) as { text?: string }
  return (data.text ?? '').trim()
}
