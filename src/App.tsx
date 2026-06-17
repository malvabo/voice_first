import {
  useCallback,
  useEffect,
  useState,
  type CSSProperties,
} from 'react'

// ---------------------------------------------------------------------------
// Types & storage
// ---------------------------------------------------------------------------

interface Entry {
  id: string
  text: string
  createdAt: number
}

const ENTRIES_KEY = 'voi-entries'
const KEY_KEY = 'voi-api-key'
const AUTOPASTE_KEY = 'voi-auto-paste'

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

function formatDate(ts: number): string {
  return new Date(ts).toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    year: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  })
}

// ---------------------------------------------------------------------------
// App — the macOS app window. Recording is handled outside the app by the
// fn/Globe shortcut; this window shows status, the latest note, history,
// and settings.
// ---------------------------------------------------------------------------

type Tab = 'overview' | 'settings'

export default function App() {
  const [tab, setTab] = useState<Tab>('overview')
  const [entries, setEntries] = useState<Entry[]>(() => loadEntries())
  const [apiKey, setApiKey] = useState<string>(
    () => localStorage.getItem(KEY_KEY) ?? '',
  )
  const [keyDraft, setKeyDraft] = useState('')
  const [autoPaste, setAutoPaste] = useState<boolean>(
    () => localStorage.getItem(AUTOPASTE_KEY) !== 'off',
  )
  const [micStatus, setMicStatus] = useState<PermissionState | 'unknown'>('unknown')
  const [copied, setCopied] = useState(false)

  // Keep the settings draft in sync when entering the tab.
  useEffect(() => {
    if (tab === 'settings') setKeyDraft(apiKey)
  }, [tab, apiKey])

  // Track microphone permission for the Setup health panel.
  useEffect(() => {
    let status: PermissionStatus | null = null
    const update = () => status && setMicStatus(status.state)
    navigator.permissions
      ?.query({ name: 'microphone' as PermissionName })
      .then((s) => {
        status = s
        setMicStatus(s.state)
        s.addEventListener('change', update)
      })
      .catch(() => setMicStatus('unknown'))
    return () => status?.removeEventListener('change', update)
  }, [])

  const latest = entries[0] ?? null

  const copyLatest = useCallback(async () => {
    if (!latest) return
    try {
      await navigator.clipboard.writeText(latest.text)
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      /* clipboard unavailable */
    }
  }, [latest])

  const deleteEntry = useCallback((id: string) => {
    setEntries((prev) => {
      const next = prev.filter((e) => e.id !== id)
      localStorage.setItem(ENTRIES_KEY, JSON.stringify(next))
      return next
    })
  }, [])

  const saveKey = () => {
    const trimmed = keyDraft.trim()
    setApiKey(trimmed)
    localStorage.setItem(KEY_KEY, trimmed)
  }

  return (
    <div style={shell}>
      <div style={glow} />
      <div style={content}>
        {/* Top bar */}
        <header style={topBar}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 11 }}>
            <Logo />
            <span style={{ fontSize: 20, fontWeight: 700, letterSpacing: '-0.02em' }}>
              Voi
            </span>
          </div>

          <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
            <div style={segmented}>
              <button
                style={tab === 'overview' ? segActive : segItem}
                onClick={() => setTab('overview')}
              >
                Overview
              </button>
              <button
                style={tab === 'settings' ? segActive : segItem}
                onClick={() => setTab('settings')}
              >
                Settings
              </button>
            </div>
            <span style={readyPill}>
              <span style={readyDot} />
              Ready
            </span>
          </div>
        </header>

        {tab === 'overview' ? (
          <Overview
            entries={entries}
            latest={latest}
            copied={copied}
            onCopy={copyLatest}
            onDelete={deleteEntry}
          />
        ) : (
          <Settings
            micStatus={micStatus}
            hasKey={Boolean(apiKey)}
            keyDraft={keyDraft}
            setKeyDraft={setKeyDraft}
            onSaveKey={saveKey}
            autoPaste={autoPaste}
            setAutoPaste={(v) => {
              setAutoPaste(v)
              localStorage.setItem(AUTOPASTE_KEY, v ? 'on' : 'off')
            }}
          />
        )}
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Overview
// ---------------------------------------------------------------------------

function Overview({
  entries,
  latest,
  copied,
  onCopy,
  onDelete,
}: {
  entries: Entry[]
  latest: Entry | null
  copied: boolean
  onCopy: () => void
  onDelete: (id: string) => void
}) {
  return (
    <main style={overview}>
      <div>
        <h1 style={headline}>Voice where you work</h1>
        <p style={subhead}>Hold fn/Globe, speak, release to paste.</p>
      </div>

      <section style={latestBlock}>
        <span style={sectionLabel}>Latest note</span>
        <p style={latestText}>
          {latest ? latest.text : 'Your most recent dictation will appear here.'}
        </p>
        <div style={latestFoot}>
          <span style={{ fontSize: 14, color: '#6b7186' }}>
            {latest
              ? formatDate(latest.createdAt)
              : 'Hold fn/Globe and start speaking.'}
          </span>
          <button style={copyButton} onClick={onCopy} disabled={!latest}>
            {copied ? 'Copied' : 'Copy'}
          </button>
        </div>
      </section>

      <section style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
        <span style={sectionLabel}>Recorded notes</span>
        <div style={notesList}>
          {entries.length === 0 ? (
            <p style={{ color: '#5a6078', fontSize: 15, margin: '10px 0' }}>
              No notes yet.
            </p>
          ) : (
            entries.map((entry) => (
              <NoteRow key={entry.id} entry={entry} onDelete={() => onDelete(entry.id)} />
            ))
          )}
        </div>
      </section>
    </main>
  )
}

function NoteRow({ entry, onDelete }: { entry: Entry; onDelete: () => void }) {
  const [hover, setHover] = useState(false)
  const [copied, setCopied] = useState(false)

  const copy = async () => {
    try {
      await navigator.clipboard.writeText(entry.text)
      setCopied(true)
      setTimeout(() => setCopied(false), 1200)
    } catch {
      /* clipboard unavailable */
    }
  }

  return (
    <div
      style={noteRow}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
    >
      <div style={{ minWidth: 0 }}>
        <div style={noteDate}>{formatDate(entry.createdAt)}</div>
        <div style={noteText}>{entry.text}</div>
      </div>
      <div style={{ display: 'flex', gap: 4, opacity: hover ? 1 : 0, transition: 'opacity 0.12s' }}>
        <button style={rowAction} onClick={copy}>
          {copied ? 'Copied' : 'Copy'}
        </button>
        <button style={{ ...rowAction, color: '#e06c75' }} onClick={onDelete}>
          Delete
        </button>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Settings — Setup health + Cartesia API key
// ---------------------------------------------------------------------------

function Settings({
  micStatus,
  hasKey,
  keyDraft,
  setKeyDraft,
  onSaveKey,
  autoPaste,
  setAutoPaste,
}: {
  micStatus: PermissionState | 'unknown'
  hasKey: boolean
  keyDraft: string
  setKeyDraft: (v: string) => void
  onSaveKey: () => void
  autoPaste: boolean
  setAutoPaste: (v: boolean) => void
}) {
  const [saved, setSaved] = useState(false)
  return (
    <main style={settings}>
      <section style={settingsBlock}>
        <span style={sectionLabel}>Setup health</span>
        <div style={pillStack}>
          <HealthPill
            tone={micStatus === 'granted' ? 'ok' : micStatus === 'denied' ? 'bad' : 'warn'}
            label={
              micStatus === 'granted'
                ? 'Mic: allowed'
                : micStatus === 'denied'
                  ? 'Mic: blocked'
                  : 'Mic: not yet granted'
            }
          />
          <HealthPill
            tone={autoPaste ? 'ok' : 'warn'}
            label={autoPaste ? 'Auto-Paste: on' : 'Auto-Paste: off'}
          />
          <HealthPill tone={hasKey ? 'ok' : 'bad'} label={hasKey ? 'API key: saved' : 'API key: missing'} />
        </div>
      </section>

      <section style={settingsBlock}>
        <span style={sectionLabel}>Preferences</span>
        <label style={toggleRow}>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 2 }}>
            <span style={{ fontSize: 15 }}>Auto-Paste after dictation</span>
            <span style={{ fontSize: 13, color: '#6b7186' }}>
              Paste the transcript as soon as you release the key.
            </span>
          </div>
          <input
            type="checkbox"
            checked={autoPaste}
            onChange={(e) => setAutoPaste(e.target.checked)}
            style={{ width: 18, height: 18 }}
          />
        </label>
      </section>

      <section style={settingsBlock}>
        <span style={sectionLabel}>Cartesia API key</span>
        <div style={{ display: 'flex', gap: 10, maxWidth: 460 }}>
          <input
            type="password"
            value={keyDraft}
            onChange={(e) => setKeyDraft(e.target.value)}
            placeholder="sk_car_..."
            style={textInput}
          />
          <button
            style={amberButton}
            onClick={() => {
              onSaveKey()
              setSaved(true)
              setTimeout(() => setSaved(false), 1500)
            }}
          >
            {saved ? 'Saved' : 'Save key'}
          </button>
        </div>
        <span style={{ fontSize: 13, color: '#5a6078' }}>Stored only on this device.</span>
      </section>
    </main>
  )
}

function HealthPill({ tone, label }: { tone: 'ok' | 'warn' | 'bad'; label: string }) {
  const color = tone === 'ok' ? '#4ade80' : tone === 'warn' ? '#f6b93b' : '#e06c75'
  return (
    <div
      style={{
        display: 'flex',
        alignItems: 'center',
        gap: 9,
        padding: '10px 16px',
        borderRadius: 999,
        border: `1px solid ${color}33`,
        background: `${color}12`,
        fontSize: 14,
        color,
      }}
    >
      <span style={{ width: 8, height: 8, borderRadius: '50%', background: color }} />
      {label}
    </div>
  )
}

function Logo() {
  return (
    <svg width="24" height="24" viewBox="0 0 24 24" fill="none">
      <rect x="2" y="9" width="2.5" height="6" rx="1.25" fill="var(--amber)" />
      <rect x="6.5" y="5" width="2.5" height="14" rx="1.25" fill="var(--amber)" />
      <rect x="11" y="2" width="2.5" height="20" rx="1.25" fill="var(--amber)" />
      <rect x="15.5" y="5" width="2.5" height="14" rx="1.25" fill="var(--amber)" />
      <rect x="20" y="9" width="2.5" height="6" rx="1.25" fill="var(--amber)" />
    </svg>
  )
}

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

const shell: CSSProperties = {
  position: 'relative',
  height: '100%',
  width: '100%',
  background: '#08090f',
  overflowY: 'auto',
}

const glow: CSSProperties = {
  position: 'absolute',
  top: -160,
  left: '50%',
  transform: 'translateX(-50%)',
  width: 900,
  height: 460,
  background: 'radial-gradient(ellipse at center, rgba(246,185,59,0.16), transparent 68%)',
  pointerEvents: 'none',
}

const content: CSSProperties = {
  position: 'relative',
  maxWidth: 1040,
  margin: '0 auto',
  padding: '24px 48px 64px',
  display: 'flex',
  flexDirection: 'column',
  gap: 16,
}

const topBar: CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  paddingBottom: 36,
}

const segmented: CSSProperties = {
  display: 'flex',
  gap: 4,
  padding: 4,
  borderRadius: 12,
  background: '#15161e',
  border: '1px solid #1d1f2b',
}

const segItem: CSSProperties = {
  background: 'transparent',
  color: '#9aa0b4',
  border: 'none',
  borderRadius: 9,
  padding: '8px 20px',
  fontSize: 15,
  fontWeight: 600,
}

const segActive: CSSProperties = {
  ...segItem,
  background: 'var(--amber)',
  color: '#1a1300',
}

const readyPill: CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 8,
  padding: '9px 16px',
  borderRadius: 999,
  background: '#15161e',
  border: '1px solid #1d1f2b',
  fontSize: 14,
  color: '#c0c4d0',
}

const readyDot: CSSProperties = {
  width: 8,
  height: 8,
  borderRadius: '50%',
  background: '#4ade80',
}

const overview: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 44,
}

const headline: CSSProperties = {
  margin: 0,
  fontSize: 52,
  fontWeight: 700,
  letterSpacing: '-0.03em',
  lineHeight: 1.04,
}

const subhead: CSSProperties = {
  margin: '14px 0 0',
  fontSize: 19,
  color: '#9aa0b4',
}

const sectionLabel: CSSProperties = {
  fontSize: 13,
  fontWeight: 600,
  letterSpacing: '0.02em',
  color: '#6b7186',
}

const latestBlock: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 16,
}

const latestText: CSSProperties = {
  margin: 0,
  fontSize: 27,
  lineHeight: 1.4,
  fontWeight: 500,
  color: '#f1f1f5',
  maxWidth: 820,
}

const latestFoot: CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  gap: 16,
  borderTop: '1px solid #15161e',
  paddingTop: 16,
}

const copyButton: CSSProperties = {
  background: '#1b1c25',
  color: '#e8e8ed',
  border: '1px solid #262838',
  borderRadius: 12,
  padding: '11px 26px',
  fontSize: 15,
  fontWeight: 600,
}

const notesList: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
}

const noteRow: CSSProperties = {
  display: 'flex',
  alignItems: 'flex-start',
  justifyContent: 'space-between',
  gap: 16,
  padding: '16px 0',
  borderBottom: '1px solid #111219',
}

const noteDate: CSSProperties = {
  fontSize: 15,
  color: '#e8e8ed',
  marginBottom: 4,
}

const noteText: CSSProperties = {
  fontSize: 15,
  lineHeight: 1.5,
  color: '#9aa0b4',
}

const rowAction: CSSProperties = {
  background: 'transparent',
  border: 'none',
  color: '#9aa0b4',
  fontSize: 13,
  fontWeight: 500,
  padding: '4px 6px',
  whiteSpace: 'nowrap',
}

const settings: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 36,
  maxWidth: 640,
}

const settingsBlock: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 14,
}

const pillStack: CSSProperties = {
  display: 'flex',
  flexWrap: 'wrap',
  gap: 10,
}

const toggleRow: CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  gap: 20,
  padding: '14px 16px',
  borderRadius: 12,
  border: '1px solid #15161e',
  background: '#0d0e16',
}

const textInput: CSSProperties = {
  flex: 1,
  background: '#0a0b14',
  border: '1px solid #24263a',
  borderRadius: 12,
  padding: '12px 14px',
  color: '#e8e8ed',
  fontSize: 15,
  outline: 'none',
}

const amberButton: CSSProperties = {
  background: 'var(--amber)',
  color: '#1a1300',
  border: 'none',
  borderRadius: 12,
  padding: '12px 22px',
  fontSize: 15,
  fontWeight: 600,
  whiteSpace: 'nowrap',
}
