import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from 'react'
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

// ---------------------------------------------------------------------------
// Waveform — slim canvas reading bars from an AnalyserNode
// ---------------------------------------------------------------------------

const BAR_COUNT = 40

function Waveform({ analyser }: { analyser: AnalyserNode | null }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

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

      if (analyser && data) analyser.getByteFrequencyData(data)

      const gap = 3
      const barWidth = (width - gap * (BAR_COUNT - 1)) / BAR_COUNT
      const step = data ? Math.floor(data.length / BAR_COUNT) : 0

      for (let i = 0; i < BAR_COUNT; i++) {
        const amplitude = data && step > 0 ? data[i * step] / 255 : 0
        const barHeight = Math.max(2, amplitude * height)
        const x = i * (barWidth + gap)
        const y = (height - barHeight) / 2
        ctx.fillStyle = '#f6b93b'
        ctx.beginPath()
        ctx.roundRect(x, y, barWidth, barHeight, Math.min(barWidth / 2, 2))
        ctx.fill()
      }

      raf = requestAnimationFrame(render)
    }

    raf = requestAnimationFrame(render)
    return () => cancelAnimationFrame(raf)
  }, [analyser])

  return (
    <canvas ref={canvasRef} style={{ width: '100%', height: 40, display: 'block' }} />
  )
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

type RecorderState = 'idle' | 'recording' | 'transcribing'

export default function App() {
  const [entries, setEntries] = useState<Entry[]>(() => loadEntries())
  const [openId, setOpenId] = useState<string | null>(null)
  const [cartesiaKey, setCartesiaKey] = useState<string>(() => loadCartesiaKey())
  const [keyDraft, setKeyDraft] = useState('')
  const [settingsOpen, setSettingsOpen] = useState(false)
  const [recorderState, setRecorderState] = useState<RecorderState>('idle')
  const [elapsedMs, setElapsedMs] = useState(0)
  const [analyser, setAnalyser] = useState<AnalyserNode | null>(null)
  const [error, setError] = useState<string | null>(null)

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
      setKeyDraft('')
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
      setError('Could not access the microphone.')
    }
  }, [cartesiaKey, teardown])

  const stopRecording = useCallback(() => {
    const recorder = recorderRef.current
    if (!recorder) return
    const durationMs = Date.now() - startTimeRef.current

    recorder.onstop = async () => {
      streamRef.current?.getTracks().forEach((t) => t.stop())
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
        setOpenId(entry.id)
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
    setOpenId((cur) => (cur === id ? null : cur))
  }, [])

  const updateEntry = useCallback((id: string, text: string) => {
    setEntries((prev) => prev.map((e) => (e.id === id ? { ...e, text } : e)))
  }, [])

  return (
    <div style={shell}>
      <div style={column}>
        {/* Header */}
        <header style={header}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
            <svg width="20" height="20" viewBox="0 0 24 24" fill="none">
              <rect x="2" y="9" width="2.5" height="6" rx="1.25" fill="var(--amber)" />
              <rect x="6.5" y="5" width="2.5" height="14" rx="1.25" fill="var(--amber)" />
              <rect x="11" y="2" width="2.5" height="20" rx="1.25" fill="var(--amber)" />
              <rect x="15.5" y="5" width="2.5" height="14" rx="1.25" fill="var(--amber)" />
              <rect x="20" y="9" width="2.5" height="6" rx="1.25" fill="var(--amber)" />
            </svg>
            <span style={{ fontSize: 15, fontWeight: 600, letterSpacing: '-0.01em' }}>
              Voi
            </span>
          </div>
          <button
            style={textButton}
            onClick={() => {
              setKeyDraft(cartesiaKey)
              setSettingsOpen(true)
            }}
          >
            Settings
          </button>
        </header>

        {/* Recorder */}
        <div style={recorder}>
          {recorderState === 'recording' ? (
            <>
              <div style={timerRow}>
                <span style={pulsingDot} />
                <span style={timerText}>{formatTimer(elapsedMs)}</span>
              </div>
              <Waveform analyser={analyser} />
              <div style={{ display: 'flex', gap: 10 }}>
                <button style={ghostButton} onClick={cancelRecording}>
                  Cancel
                </button>
                <button style={amberButton} onClick={stopRecording}>
                  Stop
                </button>
              </div>
            </>
          ) : recorderState === 'transcribing' ? (
            <div style={transcribing}>
              <span style={spinner} />
              <span style={{ letterSpacing: '0.16em', fontSize: 12, color: '#6b7186' }}>
                TRANSCRIBING
              </span>
            </div>
          ) : (
            <button style={recordButton} onClick={startRecording} aria-label="Record">
              <MicIcon />
            </button>
          )}
        </div>

        {error && <div style={errorBanner}>{error}</div>}

        {/* Entries */}
        <div style={list}>
          {entries.length === 0 ? (
            <p style={emptyText}>Tap the mic and start speaking.</p>
          ) : (
            entries.map((entry) => (
              <EntryRow
                key={entry.id}
                entry={entry}
                open={entry.id === openId}
                onToggle={() =>
                  setOpenId((cur) => (cur === entry.id ? null : entry.id))
                }
                onSave={(text) => updateEntry(entry.id, text)}
                onDelete={() => deleteEntry(entry.id)}
              />
            ))
          )}
        </div>
      </div>

      {settingsOpen && (
        <div style={backdrop} onClick={() => setSettingsOpen(false)}>
          <div style={modalCard} onClick={(e) => e.stopPropagation()}>
            <span style={{ fontSize: 13, color: '#9aa0b4' }}>Cartesia API key</span>
            <input
              type="password"
              value={keyDraft}
              onChange={(e) => setKeyDraft(e.target.value)}
              placeholder="sk_car_..."
              style={textInput}
              autoFocus
            />
            <span style={{ fontSize: 12, color: '#5a6078' }}>
              Stored only in your browser.
            </span>
            <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
              <button style={ghostButton} onClick={() => setSettingsOpen(false)}>
                Cancel
              </button>
              <button
                style={amberButton}
                onClick={() => {
                  const trimmed = keyDraft.trim()
                  setCartesiaKey(trimmed)
                  localStorage.setItem(CARTESIA_KEY, trimmed)
                  setSettingsOpen(false)
                }}
              >
                Save
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

// ---------------------------------------------------------------------------
// EntryRow — collapsed preview that expands inline
// ---------------------------------------------------------------------------

function EntryRow({
  entry,
  open,
  onToggle,
  onSave,
  onDelete,
}: {
  entry: Entry
  open: boolean
  onToggle: () => void
  onSave: (text: string) => void
  onDelete: () => void
}) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(entry.text)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    if (!open) setEditing(false)
  }, [open])

  useEffect(() => {
    setDraft(entry.text)
  }, [entry.text])

  const preview = useMemo(() => {
    const t = entry.text.trim()
    if (!t) return 'Empty recording'
    return t.length > 80 ? `${t.slice(0, 80)}…` : t
  }, [entry.text])

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(entry.text)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      /* clipboard unavailable */
    }
  }

  return (
    <div style={{ ...rowCard, ...(open ? rowCardOpen : null) }}>
      <button style={rowHead} onClick={onToggle}>
        <span style={rowPreview}>{open ? entry.text || 'Empty recording' : preview}</span>
        <span style={rowMeta}>
          {formatDate(entry.createdAt)} · {formatTimer(entry.durationMs)}
        </span>
      </button>

      {open && (
        <div style={rowBody}>
          {editing && (
            <textarea
              value={draft}
              onChange={(e) => setDraft(e.target.value)}
              style={textarea}
              autoFocus
            />
          )}
          <div style={{ display: 'flex', gap: 8 }}>
            <button style={textButton} onClick={copy}>
              {copied ? 'Copied' : 'Copy'}
            </button>
            {editing ? (
              <button
                style={textButton}
                onClick={() => {
                  onSave(draft)
                  setEditing(false)
                }}
              >
                Save
              </button>
            ) : (
              <button style={textButton} onClick={() => setEditing(true)}>
                Edit
              </button>
            )}
            <button style={{ ...textButton, color: '#e06c75' }} onClick={onDelete}>
              Delete
            </button>
          </div>
        </div>
      )}
    </div>
  )
}

function MicIcon() {
  return (
    <svg width="26" height="26" viewBox="0 0 24 24" fill="none">
      <rect x="9" y="2" width="6" height="12" rx="3" fill="#0a0b14" />
      <path d="M5 11a7 7 0 0 0 14 0" stroke="#0a0b14" strokeWidth="2" strokeLinecap="round" />
      <line x1="12" y1="18" x2="12" y2="22" stroke="#0a0b14" strokeWidth="2" strokeLinecap="round" />
    </svg>
  )
}

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

const shell: CSSProperties = {
  height: '100%',
  width: '100%',
  display: 'flex',
  justifyContent: 'center',
  background: 'var(--bg)',
  overflowY: 'auto',
}

const column: CSSProperties = {
  width: '100%',
  maxWidth: 560,
  padding: '0 24px 64px',
  display: 'flex',
  flexDirection: 'column',
}

const header: CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  padding: '22px 0',
}

const recorder: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
  justifyContent: 'center',
  gap: 18,
  minHeight: 180,
  padding: '12px 0 28px',
}

const recordButton: CSSProperties = {
  width: 76,
  height: 76,
  borderRadius: '50%',
  background: 'var(--amber)',
  border: 'none',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  transition: 'transform 0.15s ease',
}

const timerRow: CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 10,
}

const timerText: CSSProperties = {
  fontVariantNumeric: 'tabular-nums',
  fontSize: 20,
  fontWeight: 600,
}

const transcribing: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
  gap: 14,
}

const list: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 8,
}

const emptyText: CSSProperties = {
  textAlign: 'center',
  color: '#5a6078',
  fontSize: 14,
  margin: '8px 0',
}

const rowCard: CSSProperties = {
  border: '1px solid #16182a',
  borderRadius: 12,
  background: 'transparent',
  overflow: 'hidden',
}

const rowCardOpen: CSSProperties = {
  background: '#0d0e18',
  borderColor: '#1f2235',
}

const rowHead: CSSProperties = {
  width: '100%',
  textAlign: 'left',
  background: 'transparent',
  border: 'none',
  display: 'flex',
  flexDirection: 'column',
  gap: 5,
  padding: '13px 15px',
}

const rowPreview: CSSProperties = {
  fontSize: 14,
  lineHeight: 1.6,
  color: '#e8e8ed',
  whiteSpace: 'pre-wrap',
}

const rowMeta: CSSProperties = {
  fontSize: 11,
  color: '#5a6078',
}

const rowBody: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 12,
  padding: '0 15px 14px',
}

const textarea: CSSProperties = {
  background: '#0a0b14',
  border: '1px solid #24263a',
  borderRadius: 10,
  padding: 12,
  color: '#e8e8ed',
  fontSize: 14,
  lineHeight: 1.6,
  minHeight: 120,
  resize: 'vertical',
  outline: 'none',
}

const amberButton: CSSProperties = {
  background: 'var(--amber)',
  color: '#1a1300',
  border: 'none',
  borderRadius: 10,
  padding: '9px 20px',
  fontSize: 14,
  fontWeight: 600,
}

const ghostButton: CSSProperties = {
  background: 'transparent',
  color: '#9aa0b4',
  border: '1px solid #24263a',
  borderRadius: 10,
  padding: '9px 20px',
  fontSize: 14,
  fontWeight: 500,
}

const textButton: CSSProperties = {
  background: 'transparent',
  color: '#9aa0b4',
  border: 'none',
  padding: '6px 6px',
  fontSize: 13,
  fontWeight: 500,
}

const textInput: CSSProperties = {
  background: '#0a0b14',
  border: '1px solid #24263a',
  borderRadius: 10,
  padding: '10px 12px',
  color: '#e8e8ed',
  fontSize: 14,
  outline: 'none',
}

const backdrop: CSSProperties = {
  position: 'fixed',
  inset: 0,
  background: 'rgba(4,5,12,0.6)',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  zIndex: 50,
  padding: 24,
}

const modalCard: CSSProperties = {
  width: '100%',
  maxWidth: 380,
  background: 'var(--sidebar-bg)',
  border: '1px solid #1f2235',
  borderRadius: 16,
  padding: 22,
  display: 'flex',
  flexDirection: 'column',
  gap: 10,
}

const pulsingDot: CSSProperties = {
  width: 10,
  height: 10,
  borderRadius: '50%',
  background: 'var(--amber)',
  animation: 'voi-pulse 1.1s ease-in-out infinite',
}

const spinner: CSSProperties = {
  width: 28,
  height: 28,
  borderRadius: '50%',
  border: '3px solid #1f2235',
  borderTopColor: 'var(--amber)',
  animation: 'voi-spin 0.8s linear infinite',
}

const errorBanner: CSSProperties = {
  margin: '0 0 12px',
  padding: '10px 14px',
  borderRadius: 10,
  background: 'rgba(224,108,117,0.1)',
  border: '1px solid rgba(224,108,117,0.35)',
  color: '#e06c75',
  fontSize: 13,
}

// Inject keyframes once
const styleId = 'voi-keyframes'
if (typeof document !== 'undefined' && !document.getElementById(styleId)) {
  const style = document.createElement('style')
  style.id = styleId
  style.textContent = `
    @keyframes voi-pulse { 0%, 100% { opacity: 1; transform: scale(1); } 50% { opacity: 0.4; transform: scale(0.8); } }
    @keyframes voi-spin { to { transform: rotate(360deg); } }
  `
  document.head.appendChild(style)
}
