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

function previewText(text: string): string {
  const trimmed = text.trim()
  if (!trimmed) return 'Empty recording'
  return trimmed.length > 60 ? `${trimmed.slice(0, 60)}…` : trimmed
}

// ---------------------------------------------------------------------------
// VoiLogo
// ---------------------------------------------------------------------------

function VoiLogo() {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
      <svg width="26" height="26" viewBox="0 0 24 24" fill="none">
        <rect x="2" y="9" width="2.5" height="6" rx="1.25" fill="var(--amber)" />
        <rect x="6.5" y="5" width="2.5" height="14" rx="1.25" fill="var(--amber)" />
        <rect x="11" y="2" width="2.5" height="20" rx="1.25" fill="var(--amber)" />
        <rect x="15.5" y="5" width="2.5" height="14" rx="1.25" fill="var(--amber)" />
        <rect x="20" y="9" width="2.5" height="6" rx="1.25" fill="var(--amber)" />
      </svg>
      <span style={{ fontSize: 20, fontWeight: 700, letterSpacing: '-0.02em' }}>
        Voi
      </span>
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
    <div style={dictationShell}>
      <div style={statusPill}>
        <span style={tinyDot} />
        Ready across your Mac
      </div>

      <div style={composer}>
        <textarea
          readOnly
          value={
            latest?.text ??
            'Say it naturally. Voi removes pauses, fixes changed thoughts, and formats the final text.'
          }
          style={{
            ...composerText,
            color: latest ? '#f3f4f8' : '#6b7186',
          }}
        />
        <div style={composerFooter}>
          <span style={{ color: '#6b7186', fontSize: 13 }}>
            {latest
              ? `${formatTimer(latest.durationMs)} clipped to clipboard`
              : 'Try: Let’s meet at 2, actually 3.'}
          </span>
          <button style={toolbarButton} onClick={onCopy} disabled={!latest}>
            {copied ? 'Copied' : 'Copy'}
          </button>
        </div>
      </div>

      <button style={flowMicButton} aria-label="Start dictation" onClick={onStart}>
        <MicIcon />
      </button>
      <span style={{ color: '#9aa0b4', fontSize: 15 }}>
        Click to speak
      </span>
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

      for (let i = 0; i < BAR_COUNT; i++) {
        let amplitude = 0
        if (data && step > 0) {
          amplitude = data[i * step] / 255
        }
        const barHeight = Math.max(2, amplitude * height)
        const x = i * (barWidth + gap)
        const y = (height - barHeight) / 2
        ctx.fillStyle = '#f6b93b'
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

  return (
    <canvas
      ref={canvasRef}
      style={{ width: '100%', height: 64, display: 'block' }}
    />
  )
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
    <div style={overlayBackdrop}>
      <div style={bottomSheet}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <span style={pulsingDot} />
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            <span style={{ color: '#9aa0b4', fontSize: 13 }}>Listening</span>
            <span style={{ fontVariantNumeric: 'tabular-nums', fontSize: 22, fontWeight: 600 }}>
              {formatTimer(elapsedMs)}
            </span>
          </div>
        </div>
        <AmberWave analyser={analyser} />
        <div style={{ display: 'flex', gap: 12, justifyContent: 'center' }}>
          <button style={ghostButton} onClick={onCancel}>
            Cancel
          </button>
          <button style={amberButton} onClick={onDone}>
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
    <div style={overlayBackdrop}>
      <div
        style={{
          ...bottomSheet,
          alignItems: 'center',
          gap: 18,
          paddingBottom: 40,
        }}
      >
        <span style={spinner} />
        <span style={{ letterSpacing: '0.18em', fontSize: 13, color: 'var(--amber)' }}>
          POLISHING
        </span>
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
    <div style={overlayBackdrop} onClick={onClose}>
      <div style={modalCard} onClick={(e) => e.stopPropagation()}>
        <h2 style={{ margin: 0, fontSize: 18 }}>Settings</h2>
        <label style={{ fontSize: 13, color: '#9aa0b4' }}>Cartesia API key</label>
        <input
          type="password"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          placeholder="sk_car_..."
          style={textInput}
          autoFocus
        />
        <span style={{ fontSize: 12, color: '#6b7186' }}>
          Used only in your browser.
        </span>
        <div style={{ display: 'flex', gap: 10, justifyContent: 'flex-end' }}>
          <button style={ghostButton} onClick={onClose}>
            Cancel
          </button>
          <button style={amberButton} onClick={() => onSave(value.trim())}>
            Save
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
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', padding: 32, gap: 18 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
        <span style={{ fontSize: 13, color: '#6b7186' }}>
          {formatDate(entry.createdAt)}
        </span>
        <span style={{ fontSize: 13, color: '#6b7186' }}>
          {formatTimer(entry.durationMs)}
        </span>
      </div>

      <div style={{ display: 'flex', gap: 8 }}>
        <button style={toolbarButton} onClick={copy}>
          {copied ? 'Copied' : 'Copy'}
        </button>
        {editing ? (
          <button
            style={toolbarButton}
            onClick={() => {
              onSave(draft)
              setEditing(false)
            }}
          >
            Save
          </button>
        ) : (
          <button style={toolbarButton} onClick={() => setEditing(true)}>
            Edit
          </button>
        )}
        <button style={{ ...toolbarButton, color: '#e06c75' }} onClick={onDelete}>
          Delete
        </button>
      </div>

      {editing ? (
        <textarea
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          style={transcriptTextarea}
          autoFocus
        />
      ) : (
        <div style={transcriptView}>{entry.text || 'Empty recording'}</div>
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
      setError('Could not access the microphone.')
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

  const deleteEntry = useCallback(
    (id: string) => {
      setEntries((prev) => prev.filter((e) => e.id !== id))
      setSelectedId((cur) => (cur === id ? null : cur))
    },
    [],
  )

  const updateEntry = useCallback((id: string, text: string) => {
    setEntries((prev) => prev.map((e) => (e.id === id ? { ...e, text } : e)))
  }, [])

  return (
    <div style={{ display: 'flex', height: '100%', width: '100%' }}>
      {/* Sidebar */}
      <aside style={sidebar}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
          <VoiLogo />
          <button
            style={iconButton}
            aria-label="Settings"
            onClick={() => setSettingsOpen(true)}
          >
            <GearIcon />
          </button>
        </div>

        <button style={{ ...amberButton, width: '100%' }} onClick={startRecording}>
          Start dictation
        </button>

        <div style={entryList}>
          {entries.length === 0 ? (
            <div style={{ color: '#5a6078', fontSize: 13, padding: '8px 4px' }}>
              No dictations yet.
            </div>
          ) : (
            entries.map((entry) => (
              <button
                key={entry.id}
                onClick={() => setSelectedId(entry.id)}
                style={{
                  ...entryItem,
                  ...(entry.id === selectedId ? entryItemActive : null),
                }}
              >
                <span style={{ fontSize: 14, color: '#e8e8ed' }}>
                  {previewText(entry.text)}
                </span>
                <span style={{ fontSize: 11, color: '#6b7186' }}>
                  {formatDate(entry.createdAt)} · {formatTimer(entry.durationMs)}
                </span>
              </button>
            ))
          )}
        </div>
      </aside>

      {/* Main */}
      <main style={mainArea}>
        {error && <div style={errorBanner}>{error}</div>}
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
    <svg width="34" height="34" viewBox="0 0 24 24" fill="none">
      <rect x="9" y="2" width="6" height="12" rx="3" fill="#0a0b14" />
      <path
        d="M5 11a7 7 0 0 0 14 0"
        stroke="#0a0b14"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <line x1="12" y1="18" x2="12" y2="22" stroke="#0a0b14" strokeWidth="2" strokeLinecap="round" />
    </svg>
  )
}

function GearIcon() {
  return (
    <svg width="18" height="18" viewBox="0 0 24 24" fill="none">
      <circle cx="12" cy="12" r="3" stroke="#9aa0b4" strokeWidth="2" />
      <path
        d="M12 2v3M12 19v3M2 12h3M19 12h3M4.9 4.9l2.1 2.1M17 17l2.1 2.1M19.1 4.9L17 7M7 17l-2.1 2.1"
        stroke="#9aa0b4"
        strokeWidth="2"
        strokeLinecap="round"
      />
    </svg>
  )
}

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

const sidebar: CSSProperties = {
  width: 260,
  flexShrink: 0,
  background: 'var(--sidebar-bg)',
  borderRight: '1px solid #1a1c2b',
  display: 'flex',
  flexDirection: 'column',
  gap: 16,
  padding: 16,
}

const mainArea: CSSProperties = {
  flex: 1,
  background: 'var(--bg)',
  position: 'relative',
  overflow: 'auto',
}

const entryList: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 4,
  overflowY: 'auto',
  flex: 1,
  marginRight: -8,
  paddingRight: 8,
}

const entryItem: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 4,
  textAlign: 'left',
  background: 'transparent',
  border: 'none',
  borderRadius: 8,
  padding: '10px 10px',
}

const entryItemActive: CSSProperties = {
  background: '#16182a',
}

const amberButton: CSSProperties = {
  background: 'var(--amber)',
  color: '#1a1300',
  border: 'none',
  borderRadius: 10,
  padding: '10px 18px',
  fontSize: 14,
  fontWeight: 600,
}

const ghostButton: CSSProperties = {
  background: 'transparent',
  color: '#9aa0b4',
  border: '1px solid #2a2d40',
  borderRadius: 10,
  padding: '10px 18px',
  fontSize: 14,
  fontWeight: 500,
}

const toolbarButton: CSSProperties = {
  background: '#16182a',
  color: '#e8e8ed',
  border: '1px solid #24263a',
  borderRadius: 8,
  padding: '7px 14px',
  fontSize: 13,
  fontWeight: 500,
}

const iconButton: CSSProperties = {
  background: 'transparent',
  border: 'none',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  padding: 6,
  borderRadius: 8,
}

const dictationShell: CSSProperties = {
  height: '100%',
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
  justifyContent: 'center',
  gap: 18,
  padding: 32,
}

const statusPill: CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 8,
  background: '#121420',
  border: '1px solid #23263a',
  borderRadius: 999,
  padding: '7px 12px',
  color: '#b9bfd0',
  fontSize: 13,
  boxShadow: '0 10px 40px rgba(0,0,0,0.18)',
}

const tinyDot: CSSProperties = {
  width: 7,
  height: 7,
  borderRadius: '50%',
  background: '#71d38a',
}

const composer: CSSProperties = {
  width: 'min(760px, 100%)',
  minHeight: 260,
  background: '#10121d',
  border: '1px solid #24263a',
  borderRadius: 18,
  display: 'flex',
  flexDirection: 'column',
  boxShadow: '0 28px 90px rgba(0,0,0,0.28)',
  overflow: 'hidden',
}

const composerText: CSSProperties = {
  flex: 1,
  width: '100%',
  minHeight: 210,
  background: 'transparent',
  border: 'none',
  color: '#f3f4f8',
  resize: 'none',
  outline: 'none',
  padding: 24,
  fontSize: 22,
  lineHeight: 1.45,
}

const composerFooter: CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  gap: 16,
  borderTop: '1px solid #202235',
  padding: '12px 14px 12px 18px',
}

const flowMicButton: CSSProperties = {
  width: 78,
  height: 78,
  borderRadius: '50%',
  background: 'var(--amber)',
  border: 'none',
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'center',
  boxShadow: '0 0 0 0 rgba(246,185,59,0.5)',
}

const overlayBackdrop: CSSProperties = {
  position: 'fixed',
  inset: 0,
  background: 'rgba(4,5,12,0.55)',
  display: 'flex',
  alignItems: 'flex-end',
  justifyContent: 'center',
  zIndex: 50,
}

const bottomSheet: CSSProperties = {
  width: '100%',
  maxWidth: 560,
  background: 'var(--sidebar-bg)',
  borderTop: '1px solid #1f2235',
  borderTopLeftRadius: 20,
  borderTopRightRadius: 20,
  padding: '24px 28px 28px',
  display: 'flex',
  flexDirection: 'column',
  gap: 20,
  animation: 'voi-slide-up 0.22s ease-out',
}

const modalCard: CSSProperties = {
  width: '100%',
  maxWidth: 420,
  margin: 'auto',
  background: 'var(--sidebar-bg)',
  border: '1px solid #1f2235',
  borderRadius: 16,
  padding: 24,
  display: 'flex',
  flexDirection: 'column',
  gap: 12,
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

const transcriptView: CSSProperties = {
  flex: 1,
  fontSize: 16,
  lineHeight: 1.7,
  color: '#e8e8ed',
  whiteSpace: 'pre-wrap',
  overflowY: 'auto',
}

const transcriptTextarea: CSSProperties = {
  flex: 1,
  background: '#0a0b14',
  border: '1px solid #24263a',
  borderRadius: 12,
  padding: 16,
  color: '#e8e8ed',
  fontSize: 16,
  lineHeight: 1.7,
  resize: 'none',
  outline: 'none',
}

const pulsingDot: CSSProperties = {
  width: 12,
  height: 12,
  borderRadius: '50%',
  background: 'var(--amber)',
  animation: 'voi-pulse 1.1s ease-in-out infinite',
}

const spinner: CSSProperties = {
  width: 34,
  height: 34,
  borderRadius: '50%',
  border: '3px solid #2a2d40',
  borderTopColor: 'var(--amber)',
  animation: 'voi-spin 0.8s linear infinite',
}

const errorBanner: CSSProperties = {
  margin: 16,
  padding: '10px 14px',
  borderRadius: 10,
  background: 'rgba(224,108,117,0.12)',
  border: '1px solid rgba(224,108,117,0.4)',
  color: '#e06c75',
  fontSize: 13,
}

// Inject keyframes once
const styleId = 'voi-keyframes'
if (typeof document !== 'undefined' && !document.getElementById(styleId)) {
  const style = document.createElement('style')
  style.id = styleId
  style.textContent = `
    @keyframes voi-slide-up { from { transform: translateY(100%); } to { transform: translateY(0); } }
    @keyframes voi-pulse { 0%, 100% { opacity: 1; transform: scale(1); } 50% { opacity: 0.4; transform: scale(0.8); } }
    @keyframes voi-spin { to { transform: rotate(360deg); } }
  `
  document.head.appendChild(style)
}
