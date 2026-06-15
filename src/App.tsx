import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { polishDictation, transcribeWithCartesia } from './lib/cartesiaTranscribe'

// ---------------------------------------------------------------------------
// Types & storage
// ---------------------------------------------------------------------------

interface Entry {
  id: string
  text: string
  rawText?: string
  durationMs: number
  createdAt: number
}

const ENTRIES_KEY = 'voi-entries'
const CARTESIA_KEY = 'voi-cartesia-key'

function loadEntries(): Entry[] {
  try {
    const raw = localStorage.getItem(ENTRIES_KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? (parsed as Entry[]) : []
  } catch {
    return []
  }
}

function saveEntries(entries: Entry[]) {
  localStorage.setItem(ENTRIES_KEY, JSON.stringify(entries))
}

function loadCartesiaKey(): string {
  return localStorage.getItem(CARTESIA_KEY) ?? ''
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function formatTimer(ms: number): string {
  const totalSeconds = Math.floor(ms / 1000)
  const minutes = Math.floor(totalSeconds / 60)
  const seconds = totalSeconds % 60
  return `${String(minutes).padStart(2, '0')}:${String(seconds).padStart(2, '0')}`
}

function formatDate(ts: number): string {
  return new Date(ts).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  })
}

function previewText(text: string): string {
  const trimmed = text.trim()
  if (!trimmed) return 'Empty recording'
  return trimmed.length > 60 ? `${trimmed.slice(0, 60)}…` : trimmed
}

// Read the accent straight from the token system so the canvas can never
// drift from the CSS palette.
function accentColor(): string {
  if (typeof window === 'undefined') return '#f6b93b'
  const value = getComputedStyle(document.documentElement)
    .getPropertyValue('--amber')
    .trim()
  return value || '#f6b93b'
}

// ---------------------------------------------------------------------------
// VoiLogo
// ---------------------------------------------------------------------------

function VoiLogo() {
  return (
    <div className="brand">
      <svg width="26" height="26" viewBox="0 0 24 24" fill="none" aria-hidden>
        <rect x="2" y="9" width="2.5" height="6" rx="1.25" fill="var(--amber)" />
        <rect x="6.5" y="5" width="2.5" height="14" rx="1.25" fill="var(--amber)" />
        <rect x="11" y="2" width="2.5" height="20" rx="1.25" fill="var(--amber)" />
        <rect x="15.5" y="5" width="2.5" height="14" rx="1.25" fill="var(--amber)" />
        <rect x="20" y="9" width="2.5" height="6" rx="1.25" fill="var(--amber)" />
      </svg>
      <span className="brand__name">Voi</span>
    </div>
  )
}

// ---------------------------------------------------------------------------
// DictationSurface
// ---------------------------------------------------------------------------

function DictationSurface({
  latest,
  copied,
  onCopy,
  onStart,
}: {
  latest: Entry | null
  copied: boolean
  onCopy: () => void
  onStart: () => void
}) {
  return (
    <div className="dictation">
      <div className="status-pill">
        <span className="status-pill__dot" />
        Ready across your Mac
      </div>

      <div className="composer">
        <textarea
          readOnly
          className={`composer__text${latest ? '' : ' composer__text--placeholder'}`}
          value={
            latest?.text ??
            'Say it naturally. Voi removes pauses, fixes changed thoughts, and formats the final text.'
          }
        />
        <div className="composer__footer">
          <span className="composer__hint">
            {latest
              ? `${formatTimer(latest.durationMs)} clipped to clipboard`
              : 'Try: Let’s meet at 2, actually 3.'}
          </span>
          <button className="toolbar__btn" onClick={onCopy} disabled={!latest}>
            {copied ? 'Copied' : 'Copy'}
          </button>
        </div>
      </div>

      <button className="mic-cta" aria-label="Start dictation" onClick={onStart}>
        <MicIcon />
      </button>
      <span className="dictation__hint">Click to speak</span>
    </div>
  )
}

// ---------------------------------------------------------------------------
// AmberWave — canvas reading 48 bars from an AnalyserNode
// ---------------------------------------------------------------------------

const BAR_COUNT = 48

function AmberWave({ analyser }: { analyser: AnalyserNode | null }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    const fill = accentColor()
    let raf = 0
    const data = analyser ? new Uint8Array(analyser.frequencyBinCount) : null

    const render = () => {
      const dpr = window.devicePixelRatio || 1
      const width = canvas.clientWidth
      const height = canvas.clientHeight
      if (canvas.width !== width * dpr || canvas.height !== height * dpr) {
        canvas.width = width * dpr
        canvas.height = height * dpr
      }
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      ctx.clearRect(0, 0, width, height)

      if (analyser && data) {
        analyser.getByteFrequencyData(data)
      }

      const gap = 3
      const barWidth = (width - gap * (BAR_COUNT - 1)) / BAR_COUNT
      const step = data ? Math.floor(data.length / BAR_COUNT) : 0

      ctx.fillStyle = fill
      for (let i = 0; i < BAR_COUNT; i++) {
        let amplitude = 0
        if (data && step > 0) {
          amplitude = data[i * step] / 255
        }
        const barHeight = Math.max(2, amplitude * height)
        const x = i * (barWidth + gap)
        const y = (height - barHeight) / 2
        const r = Math.min(barWidth / 2, 2)
        ctx.beginPath()
        ctx.roundRect(x, y, barWidth, barHeight, r)
        ctx.fill()
      }

      raf = requestAnimationFrame(render)
    }

    raf = requestAnimationFrame(render)
    return () => cancelAnimationFrame(raf)
  }, [analyser])

  return <canvas ref={canvasRef} className="wave" />
}

// ---------------------------------------------------------------------------
// RecordingOverlay — bottom sheet
// ---------------------------------------------------------------------------

function RecordingOverlay({
  analyser,
  elapsedMs,
  onCancel,
  onDone,
}: {
  analyser: AnalyserNode | null
  elapsedMs: number
  onCancel: () => void
  onDone: () => void
}) {
  return (
    <div className="overlay overlay--bottom">
      <div className="sheet" role="dialog" aria-label="Recording">
        <div className="sheet__listening">
          <span className="dot" />
          <div className="listening-meta">
            <span className="listening-label">Listening</span>
            <span className="timer">{formatTimer(elapsedMs)}</span>
          </div>
        </div>
        <AmberWave analyser={analyser} />
        <div className="sheet__actions">
          <button className="btn btn--ghost" onClick={onCancel}>
            Cancel
          </button>
          <button className="btn btn--amber" onClick={onDone}>
            Polish
          </button>
        </div>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// TranscribingOverlay
// ---------------------------------------------------------------------------

function TranscribingOverlay() {
  return (
    <div className="overlay overlay--bottom">
      <div className="sheet transcribing" role="status" aria-live="polite">
        <span className="spinner" />
        <span className="transcribing__label">POLISHING</span>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// SettingsModal
// ---------------------------------------------------------------------------

function SettingsModal({
  initialKey,
  onClose,
  onSave,
}: {
  initialKey: string
  onClose: () => void
  onSave: (key: string) => void
}) {
  const [value, setValue] = useState(initialKey)

  return (
    <div className="overlay overlay--center" onClick={onClose}>
      <div
        className="modal"
        role="dialog"
        aria-label="Settings"
        onClick={(e) => e.stopPropagation()}
      >
        <h2 className="modal__title">Settings</h2>
        <label className="field-label" htmlFor="cartesia-key">
          Cartesia API key
        </label>
        <input
          id="cartesia-key"
          className="input"
          type="password"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          placeholder="sk_car_..."
          autoFocus
        />
        <span className="field-hint">
          Stored only in this browser. Sent straight to Cartesia to transcribe —
          nowhere else.
        </span>
        <div className="modal__actions">
          <button className="btn btn--ghost" onClick={onClose}>
            Cancel
          </button>
          <button className="btn btn--amber" onClick={() => onSave(value.trim())}>
            Save key
          </button>
        </div>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// EntryDetail
// ---------------------------------------------------------------------------

function EntryDetail({
  entry,
  onSave,
  onDelete,
}: {
  entry: Entry
  onSave: (text: string) => void
  onDelete: () => void
}) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(entry.text)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    setEditing(false)
    setDraft(entry.text)
    setCopied(false)
  }, [entry.id, entry.text])

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(entry.text)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      // clipboard may be unavailable
    }
  }

  return (
    <div className="detail">
      <div className="detail__meta">
        <span>{formatDate(entry.createdAt)}</span>
        <span className="meta-dot">·</span>
        <span>{formatTimer(entry.durationMs)}</span>
      </div>

      <div className="toolbar">
        <button className="toolbar__btn" onClick={copy}>
          {copied ? 'Copied' : 'Copy'}
        </button>
        {editing ? (
          <button
            className="toolbar__btn"
            onClick={() => {
              onSave(draft)
              setEditing(false)
            }}
          >
            Save
          </button>
        ) : (
          <button className="toolbar__btn" onClick={() => setEditing(true)}>
            Edit
          </button>
        )}
        <button className="toolbar__btn toolbar__btn--danger" onClick={onDelete}>
          Delete
        </button>
      </div>

      {editing ? (
        <textarea
          className="transcript-edit"
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          autoFocus
        />
      ) : (
        <div className={`transcript${entry.text ? '' : ' transcript--empty'}`}>
          {entry.text || 'Nothing was transcribed for this recording.'}
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

type RecorderState = 'idle' | 'recording' | 'transcribing'

export default function App() {
  const [entries, setEntries] = useState<Entry[]>(() => loadEntries())
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [cartesiaKey, setCartesiaKey] = useState<string>(() => loadCartesiaKey())
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [recorderState, setRecorderState] = useState<RecorderState>('idle')
  const [elapsedMs, setElapsedMs] = useState(0)
  const [analyser, setAnalyser] = useState<AnalyserNode | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [copiedLatest, setCopiedLatest] = useState(false)

  const streamRef = useRef<MediaStream | null>(null)
  const audioCtxRef = useRef<AudioContext | null>(null)
  const recorderRef = useRef<MediaRecorder | null>(null)
  const chunksRef = useRef<Blob[]>([])
  const timerRef = useRef<number | null>(null)
  const startTimeRef = useRef<number>(0)
  const cancelledRef = useRef<boolean>(false)

  useEffect(() => {
    saveEntries(entries)
  }, [entries])

  const selected = useMemo(
    () => entries.find((e) => e.id === selectedId) ?? null,
    [entries, selectedId],
  )

  const latest = entries[0] ?? null

  const copyLatest = useCallback(async () => {
    if (!latest) return
    try {
      await navigator.clipboard.writeText(latest.text)
      setCopiedLatest(true)
      setTimeout(() => setCopiedLatest(false), 1500)
    } catch {
      setError('Clipboard access is unavailable in this browser.')
    }
  }, [latest])

  const teardown = useCallback(() => {
    if (timerRef.current !== null) {
      clearInterval(timerRef.current)
      timerRef.current = null
    }
    recorderRef.current = null
    streamRef.current?.getTracks().forEach((t) => t.stop())
    streamRef.current = null
    if (audioCtxRef.current) {
      audioCtxRef.current.close().catch(() => {})
      audioCtxRef.current = null
    }
    setAnalyser(null)
  }, [])

  const startRecording = useCallback(async () => {
    if (!cartesiaKey) {
      setSettingsOpen(true)
      return
    }
    setError(null)
    cancelledRef.current = false
    try {
      const stream = await navigator.mediaDevices.getUserMedia({ audio: true })
      streamRef.current = stream

      const audioCtx = new AudioContext()
      audioCtxRef.current = audioCtx
      const source = audioCtx.createMediaStreamSource(stream)
      const node = audioCtx.createAnalyser()
      node.fftSize = 256
      source.connect(node)
      setAnalyser(node)

      chunksRef.current = []
      const recorder = new MediaRecorder(stream)
      recorderRef.current = recorder
      recorder.ondataavailable = (e) => {
        if (e.data.size > 0) chunksRef.current.push(e.data)
      }
      recorder.start()

      startTimeRef.current = Date.now()
      setElapsedMs(0)
      timerRef.current = window.setInterval(() => {
        setElapsedMs(Date.now() - startTimeRef.current)
      }, 200)

      setRecorderState('recording')
    } catch {
      teardown()
      setRecorderState('idle')
      setError('Could not reach the microphone. Check your browser permissions and try again.')
    }
  }, [cartesiaKey, teardown])

  const stopRecording = useCallback(() => {
    const recorder = recorderRef.current
    if (!recorder) return
    const durationMs = Date.now() - startTimeRef.current

    recorder.onstop = async () => {
      const tracksStream = streamRef.current
      tracksStream?.getTracks().forEach((t) => t.stop())
      streamRef.current = null
      if (audioCtxRef.current) {
        audioCtxRef.current.close().catch(() => {})
        audioCtxRef.current = null
      }
      setAnalyser(null)

      if (cancelledRef.current) {
        setRecorderState('idle')
        return
      }

      const blob = new Blob(chunksRef.current, { type: 'audio/webm' })
      setRecorderState('transcribing')
      try {
        const rawText = await transcribeWithCartesia(blob, cartesiaKey)
        const text = polishDictation(rawText)
        const entry: Entry = {
          id: crypto.randomUUID(),
          text,
          rawText,
          durationMs,
          createdAt: Date.now(),
        }
        setEntries((prev) => [entry, ...prev])
        setSelectedId(null)
        try {
          await navigator.clipboard.writeText(text)
          setCopiedLatest(true)
          setTimeout(() => setCopiedLatest(false), 1500)
        } catch {
          // Clipboard is a convenience; keep the transcript even if copy fails.
        }
      } catch (err) {
        setError(err instanceof Error ? err.message : 'Transcription failed.')
      } finally {
        setRecorderState('idle')
      }
    }

    if (timerRef.current !== null) {
      clearInterval(timerRef.current)
      timerRef.current = null
    }
    recorder.stop()
  }, [cartesiaKey])

  const cancelRecording = useCallback(() => {
    cancelledRef.current = true
    const recorder = recorderRef.current
    if (recorder && recorder.state !== 'inactive') {
      if (timerRef.current !== null) {
        clearInterval(timerRef.current)
        timerRef.current = null
      }
      recorder.stop()
    } else {
      teardown()
      setRecorderState('idle')
    }
  }, [teardown])

  const deleteEntry = useCallback((id: string) => {
    setEntries((prev) => prev.filter((e) => e.id !== id))
    setSelectedId((cur) => (cur === id ? null : cur))
  }, [])

  const updateEntry = useCallback((id: string, text: string) => {
    setEntries((prev) => prev.map((e) => (e.id === id ? { ...e, text } : e)))
  }, [])

  return (
    <div className="app">
      {/* Sidebar */}
      <aside className="sidebar">
        <div className="sidebar__head">
          <VoiLogo />
          <button
            className="icon-btn"
            aria-label="Settings"
            onClick={() => setSettingsOpen(true)}
          >
            <GearIcon />
          </button>
        </div>

        <button
          className="btn btn--amber btn--block btn--record"
          onClick={startRecording}
        >
          <MicGlyph />
          Start dictation
        </button>

        <div className="entry-list">
          {entries.length === 0 ? (
            <div className="entry-empty">
              No dictations yet. Your transcripts will collect here.
            </div>
          ) : (
            entries.map((entry) => (
              <button
                key={entry.id}
                onClick={() => setSelectedId(entry.id)}
                className={`entry${entry.id === selectedId ? ' entry--active' : ''}`}
              >
                <span className="entry__title">{previewText(entry.text)}</span>
                <span className="entry__meta">
                  {formatDate(entry.createdAt)} · {formatTimer(entry.durationMs)}
                </span>
              </button>
            ))
          )}
        </div>
      </aside>

      {/* Main */}
      <main className="main">
        {error && <div className="error">{error}</div>}
        {selected ? (
          <EntryDetail
            entry={selected}
            onSave={(text) => updateEntry(selected.id, text)}
            onDelete={() => deleteEntry(selected.id)}
          />
        ) : (
          <DictationSurface
            latest={latest}
            copied={copiedLatest}
            onCopy={copyLatest}
            onStart={startRecording}
          />
        )}
      </main>

      {recorderState === 'recording' && (
        <RecordingOverlay
          analyser={analyser}
          elapsedMs={elapsedMs}
          onCancel={cancelRecording}
          onDone={stopRecording}
        />
      )}
      {recorderState === 'transcribing' && <TranscribingOverlay />}

      {settingsOpen && (
        <SettingsModal
          initialKey={cartesiaKey}
          onClose={() => setSettingsOpen(false)}
          onSave={(key) => {
            setCartesiaKey(key)
            localStorage.setItem(CARTESIA_KEY, key)
            setSettingsOpen(false)
          }}
        />
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// Icons
// ---------------------------------------------------------------------------

function MicIcon() {
  return (
    <svg width="32" height="32" viewBox="0 0 24 24" fill="none" aria-hidden>
      <rect x="9" y="2" width="6" height="12" rx="3" fill="currentColor" />
      <path
        d="M5 11a7 7 0 0 0 14 0"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <line
        x1="12"
        y1="18"
        x2="12"
        y2="22"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
    </svg>
  )
}

function MicGlyph() {
  return (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" aria-hidden>
      <rect x="9" y="2" width="6" height="12" rx="3" fill="currentColor" />
      <path
        d="M5 11a7 7 0 0 0 14 0"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <line
        x1="12"
        y1="18"
        x2="12"
        y2="22"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
    </svg>
  )
}

function GearIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none" aria-hidden>
      <circle cx="12" cy="12" r="3" stroke="currentColor" strokeWidth="2" />
      <path
        d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M19.1 4.9L17 7M7 17l-2.1 2.1"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
    </svg>
  )
}
