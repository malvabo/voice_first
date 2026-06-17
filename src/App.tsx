import {
  useCallback,
  useEffect,
  useState,
  type CSSProperties,
  type ReactNode,
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

function smartDate(ts: number): string {
  const d = new Date(ts)
  const now = new Date()
  const time = d.toLocaleTimeString(undefined, { hour: 'numeric', minute: '2-digit' })
  const sameDay = d.toDateString() === now.toDateString()
  const yest = new Date(now)
  yest.setDate(now.getDate() - 1)
  if (sameDay) return `Today ${time}`
  if (d.toDateString() === yest.toDateString()) return `Yesterday ${time}`
  return `${d.toLocaleDateString(undefined, { month: 'short', day: 'numeric' })} · ${time}`
}

// macOS system-ish tokens
const C = {
  accent: '#ffb340', // warm brand amber, slightly desaturated for dark UI
  accentText: '#241700',
  green: '#30d158',
  red: '#ff453a',
  label: 'rgba(255,255,255,0.92)',
  secondary: 'rgba(235,235,245,0.6)',
  tertiary: 'rgba(235,235,245,0.3)',
  hairline: 'rgba(255,255,255,0.08)',
  fill: 'rgba(255,255,255,0.06)',
  fillStrong: 'rgba(255,255,255,0.1)',
  surface: 'rgba(255,255,255,0.04)',
}

const drag = { WebkitAppRegion: 'drag' } as unknown as CSSProperties
const noDrag = { WebkitAppRegion: 'no-drag' } as unknown as CSSProperties

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

type Tab = 'overview' | 'settings'

export default function App() {
  const [tab, setTab] = useState<Tab>('overview')
  const [entries, setEntries] = useState<Entry[]>(() => loadEntries())
  const [apiKey, setApiKey] = useState<string>(() => localStorage.getItem(KEY_KEY) ?? '')
  const [keyDraft, setKeyDraft] = useState('')
  const [autoPaste, setAutoPaste] = useState<boolean>(
    () => localStorage.getItem(AUTOPASTE_KEY) !== 'off',
  )
  const [micStatus, setMicStatus] = useState<PermissionState | 'unknown'>('unknown')

  useEffect(() => {
    if (tab === 'settings') setKeyDraft(apiKey)
  }, [tab, apiKey])

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

      {/* Toolbar (draggable, clears traffic lights) */}
      <header style={{ ...toolbar, ...drag }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
          <Logo />
          <span style={brandText}>Voi</span>
        </div>

        <div style={{ ...noDrag, display: 'flex', alignItems: 'center', gap: 10 }}>
          <Segmented tab={tab} onChange={setTab} />
          <StatusPill />
        </div>
      </header>

      <div style={scroll}>
        <div style={page}>
          {tab === 'overview' ? (
            <Overview entries={entries} latest={latest} onDelete={deleteEntry} />
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
    </div>
  )
}

// ---------------------------------------------------------------------------
// Toolbar pieces
// ---------------------------------------------------------------------------

function Segmented({ tab, onChange }: { tab: Tab; onChange: (t: Tab) => void }) {
  return (
    <div style={segmented}>
      <span
        style={{
          ...segThumb,
          transform: tab === 'overview' ? 'translateX(0)' : 'translateX(100%)',
        }}
      />
      {(['overview', 'settings'] as Tab[]).map((t) => (
        <button
          key={t}
          onClick={() => onChange(t)}
          style={{ ...segItem, color: tab === t ? C.label : C.secondary }}
        >
          {t === 'overview' ? 'Overview' : 'Settings'}
        </button>
      ))}
    </div>
  )
}

function StatusPill() {
  return (
    <span style={statusPill}>
      <span style={statusDot} />
      Ready
    </span>
  )
}

// ---------------------------------------------------------------------------
// Overview
// ---------------------------------------------------------------------------

function Overview({
  entries,
  latest,
  onDelete,
}: {
  entries: Entry[]
  latest: Entry | null
  onDelete: (id: string) => void
}) {
  const [copied, setCopied] = useState(false)
  const copyLatest = async () => {
    if (!latest) return
    try {
      await navigator.clipboard.writeText(latest.text)
      setCopied(true)
      setTimeout(() => setCopied(false), 1400)
    } catch {
      /* clipboard unavailable */
    }
  }

  const rest = entries.slice(1)

  return (
    <main style={{ display: 'flex', flexDirection: 'column', gap: 40 }}>
      <div>
        <h1 style={headline}>Voice where you work</h1>
        <p style={subhead}>
          Hold <Kbd>fn</Kbd> <span style={{ color: C.tertiary }}>/</span>{' '}
          <Kbd>Globe</Kbd>, speak, release to paste.
        </p>
      </div>

      <section style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
        <span style={eyebrow}>Latest note</span>
        {latest ? (
          <>
            <p style={latestText}>{latest.text}</p>
            <div style={latestFoot}>
              <span style={{ fontSize: 13, color: C.tertiary }}>{smartDate(latest.createdAt)}</span>
              <button
                style={copied ? copyButtonDone : copyButton}
                onClick={copyLatest}
                onMouseEnter={(e) => !copied && (e.currentTarget.style.background = '#ffc05c')}
                onMouseLeave={(e) => !copied && (e.currentTarget.style.background = C.accent)}
              >
                {copied ? 'Copied' : 'Copy'}
              </button>
            </div>
          </>
        ) : (
          <div style={emptyHero}>
            <p style={{ margin: 0, fontSize: 20, color: C.secondary }}>
              Nothing dictated yet.
            </p>
            <p style={{ margin: 0, fontSize: 14, color: C.tertiary }}>
              Hold <Kbd>fn</Kbd> and start speaking — your words land here.
            </p>
          </div>
        )}
      </section>

      {rest.length > 0 && (
        <section style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
          <span style={eyebrow}>Earlier</span>
          <div>
            {rest.map((entry, i) => (
              <NoteRow
                key={entry.id}
                entry={entry}
                first={i === 0}
                onDelete={() => onDelete(entry.id)}
              />
            ))}
          </div>
        </section>
      )}
    </main>
  )
}

function NoteRow({
  entry,
  first,
  onDelete,
}: {
  entry: Entry
  first: boolean
  onDelete: () => void
}) {
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
      style={{
        ...noteRow,
        borderTop: first ? 'none' : `1px solid ${C.hairline}`,
        background: hover ? C.surface : 'transparent',
      }}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
    >
      <div style={{ minWidth: 0 }}>
        <div style={{ fontSize: 12, color: C.tertiary, marginBottom: 5 }}>
          {smartDate(entry.createdAt)}
        </div>
        <div style={noteText}>{entry.text}</div>
      </div>
      <div style={{ display: 'flex', gap: 2, opacity: hover ? 1 : 0, transition: 'opacity .12s' }}>
        <button style={rowAction} onClick={copy}>
          {copied ? 'Copied' : 'Copy'}
        </button>
        <button style={{ ...rowAction, color: C.red }} onClick={onDelete}>
          Delete
        </button>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Settings — macOS System-Settings-style grouped inset lists
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
  const mic =
    micStatus === 'granted'
      ? { label: 'Allowed', tone: C.green }
      : micStatus === 'denied'
        ? { label: 'Blocked', tone: C.red }
        : { label: 'Not granted', tone: C.secondary }

  return (
    <main style={{ display: 'flex', flexDirection: 'column', gap: 28, maxWidth: 560 }}>
      <Group title="Setup health">
        <Row label="Microphone">
          <StatusValue label={mic.label} tone={mic.tone} />
        </Row>
        <Row label="Auto-Paste">
          <StatusValue label={autoPaste ? 'On' : 'Off'} tone={autoPaste ? C.green : C.secondary} />
        </Row>
        <Row label="API key">
          <StatusValue label={hasKey ? 'Saved' : 'Missing'} tone={hasKey ? C.green : C.red} />
        </Row>
      </Group>

      <Group title="Dictation">
        <Row label="Auto-Paste after dictation" sub="Paste the transcript the moment you release the key.">
          <Switch checked={autoPaste} onChange={setAutoPaste} />
        </Row>
      </Group>

      <Group title="Cartesia API key" footer="Stored only on this device.">
        <div style={{ display: 'flex', gap: 10, padding: '14px 16px' }}>
          <input
            type="password"
            value={keyDraft}
            onChange={(e) => setKeyDraft(e.target.value)}
            placeholder="sk_car_…"
            style={textInput}
          />
          <button
            style={amberButton}
            onClick={() => {
              onSaveKey()
              setSaved(true)
              setTimeout(() => setSaved(false), 1400)
            }}
          >
            {saved ? 'Saved' : 'Save'}
          </button>
        </div>
      </Group>
    </main>
  )
}

function Group({
  title,
  footer,
  children,
}: {
  title: string
  footer?: string
  children: ReactNode
}) {
  return (
    <section style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <span style={eyebrow}>{title}</span>
      <div style={groupCard} data-voi-group>{children}</div>
      {footer && <span style={{ fontSize: 12, color: C.tertiary, paddingLeft: 4 }}>{footer}</span>}
    </section>
  )
}

function Row({
  label,
  sub,
  children,
}: {
  label: string
  sub?: string
  children: ReactNode
}) {
  return (
    <div style={settingsRow}>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 2, minWidth: 0 }}>
        <span style={{ fontSize: 14, color: C.label }}>{label}</span>
        {sub && <span style={{ fontSize: 12, color: C.tertiary }}>{sub}</span>}
      </div>
      {children}
    </div>
  )
}

function StatusValue({ label, tone }: { label: string; tone: string }) {
  return (
    <span style={{ display: 'flex', alignItems: 'center', gap: 7, fontSize: 13, color: tone }}>
      <span style={{ width: 7, height: 7, borderRadius: '50%', background: tone }} />
      {label}
    </span>
  )
}

function Switch({ checked, onChange }: { checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <button
      role="switch"
      aria-checked={checked}
      onClick={() => onChange(!checked)}
      style={{
        position: 'relative',
        width: 38,
        height: 23,
        borderRadius: 999,
        border: 'none',
        padding: 0,
        background: checked ? C.green : 'rgba(255,255,255,0.16)',
        transition: 'background .18s ease',
        flexShrink: 0,
      }}
    >
      <span
        style={{
          position: 'absolute',
          top: 2,
          left: 2,
          width: 19,
          height: 19,
          borderRadius: '50%',
          background: '#fff',
          boxShadow: '0 1px 3px rgba(0,0,0,0.3)',
          transform: checked ? 'translateX(15px)' : 'translateX(0)',
          transition: 'transform .18s ease',
        }}
      />
    </button>
  )
}

function Kbd({ children }: { children: ReactNode }) {
  return <span style={kbd}>{children}</span>
}

function Logo() {
  return (
    <svg width="22" height="22" viewBox="0 0 24 24" fill="none">
      <rect x="2" y="9" width="2.5" height="6" rx="1.25" fill={C.accent} />
      <rect x="6.5" y="5" width="2.5" height="14" rx="1.25" fill={C.accent} />
      <rect x="11" y="2" width="2.5" height="20" rx="1.25" fill={C.accent} />
      <rect x="15.5" y="5" width="2.5" height="14" rx="1.25" fill={C.accent} />
      <rect x="20" y="9" width="2.5" height="6" rx="1.25" fill={C.accent} />
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
  display: 'flex',
  flexDirection: 'column',
  background: 'linear-gradient(180deg, #232228 0%, #1a1a1f 220px, #161619 100%)',
  color: C.label,
  overflow: 'hidden',
}

const glow: CSSProperties = {
  position: 'absolute',
  top: -200,
  left: '50%',
  transform: 'translateX(-50%)',
  width: 760,
  height: 420,
  background: 'radial-gradient(ellipse at center, rgba(255,179,64,0.14), transparent 70%)',
  pointerEvents: 'none',
}

const toolbar: CSSProperties = {
  position: 'relative',
  zIndex: 2,
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  height: 52,
  padding: '0 18px 0 88px', // clear macOS traffic lights
  borderBottom: `1px solid ${C.hairline}`,
  flexShrink: 0,
}

const brandText: CSSProperties = {
  fontSize: 15,
  fontWeight: 600,
  letterSpacing: '-0.01em',
}

const segmented: CSSProperties = {
  position: 'relative',
  display: 'flex',
  padding: 2,
  borderRadius: 9,
  background: C.fill,
  border: `1px solid ${C.hairline}`,
}

const segThumb: CSSProperties = {
  position: 'absolute',
  top: 2,
  left: 2,
  width: 'calc(50% - 2px)',
  height: 'calc(100% - 4px)',
  borderRadius: 7,
  background: C.fillStrong,
  boxShadow: '0 1px 2px rgba(0,0,0,0.25)',
  transition: 'transform .2s cubic-bezier(0.32,0.72,0,1)',
}

const segItem: CSSProperties = {
  position: 'relative',
  zIndex: 1,
  background: 'transparent',
  border: 'none',
  padding: '5px 16px',
  fontSize: 13,
  fontWeight: 600,
  transition: 'color .15s',
}

const statusPill: CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  gap: 7,
  padding: '6px 13px',
  borderRadius: 999,
  background: C.fill,
  border: `1px solid ${C.hairline}`,
  fontSize: 13,
  color: C.secondary,
}

const statusDot: CSSProperties = {
  width: 7,
  height: 7,
  borderRadius: '50%',
  background: C.green,
  boxShadow: `0 0 0 3px ${C.green}22`,
}

const scroll: CSSProperties = {
  position: 'relative',
  zIndex: 1,
  flex: 1,
  overflowY: 'auto',
}

const page: CSSProperties = {
  maxWidth: 720,
  margin: '0 auto',
  padding: '44px 40px 72px',
}

const headline: CSSProperties = {
  margin: 0,
  fontSize: 46,
  fontWeight: 700,
  letterSpacing: '-0.035em',
  lineHeight: 1.05,
}

const subhead: CSSProperties = {
  margin: '16px 0 0',
  fontSize: 17,
  color: C.secondary,
  display: 'flex',
  alignItems: 'center',
  gap: 6,
  flexWrap: 'wrap',
}

const eyebrow: CSSProperties = {
  fontSize: 12,
  fontWeight: 600,
  letterSpacing: '0.06em',
  textTransform: 'uppercase',
  color: C.tertiary,
}

const latestText: CSSProperties = {
  margin: 0,
  fontSize: 26,
  lineHeight: 1.42,
  fontWeight: 500,
  letterSpacing: '-0.01em',
  color: C.label,
  maxWidth: 640,
}

const latestFoot: CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  gap: 16,
}

const copyButton: CSSProperties = {
  background: C.accent,
  color: C.accentText,
  border: 'none',
  borderRadius: 10,
  padding: '10px 24px',
  fontSize: 14,
  fontWeight: 600,
  transition: 'background .15s',
}

const copyButtonDone: CSSProperties = {
  ...copyButton,
  background: C.green,
  color: '#06230f',
}

const emptyHero: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 8,
  padding: '28px 0',
}

const noteRow: CSSProperties = {
  display: 'flex',
  alignItems: 'flex-start',
  justifyContent: 'space-between',
  gap: 16,
  padding: '14px 12px',
  margin: '0 -12px',
  borderRadius: 10,
  transition: 'background .12s',
}

const noteText: CSSProperties = {
  fontSize: 14.5,
  lineHeight: 1.5,
  color: C.secondary,
}

const rowAction: CSSProperties = {
  background: 'transparent',
  border: 'none',
  color: C.secondary,
  fontSize: 12.5,
  fontWeight: 500,
  padding: '4px 8px',
  borderRadius: 6,
  whiteSpace: 'nowrap',
}

const groupCard: CSSProperties = {
  borderRadius: 12,
  background: C.surface,
  border: `1px solid ${C.hairline}`,
  overflow: 'hidden',
}

const settingsRow: CSSProperties = {
  display: 'flex',
  alignItems: 'center',
  justifyContent: 'space-between',
  gap: 16,
  padding: '14px 16px',
  borderTop: `1px solid ${C.hairline}`,
}

const textInput: CSSProperties = {
  flex: 1,
  background: 'rgba(0,0,0,0.25)',
  border: `1px solid ${C.hairline}`,
  borderRadius: 9,
  padding: '10px 13px',
  color: C.label,
  fontSize: 14,
  outline: 'none',
}

const amberButton: CSSProperties = {
  background: C.accent,
  color: C.accentText,
  border: 'none',
  borderRadius: 9,
  padding: '10px 20px',
  fontSize: 14,
  fontWeight: 600,
  whiteSpace: 'nowrap',
}

const kbd: CSSProperties = {
  display: 'inline-flex',
  alignItems: 'center',
  padding: '2px 8px',
  borderRadius: 6,
  background: C.fill,
  border: `1px solid ${C.hairline}`,
  fontSize: 13,
  fontWeight: 600,
  color: C.label,
  boxShadow: '0 1px 0 rgba(0,0,0,0.3)',
}

// The first row in a group shouldn't show a top divider.
const firstRowFix = 'voi-settings-fix'
if (typeof document !== 'undefined' && !document.getElementById(firstRowFix)) {
  const s = document.createElement('style')
  s.id = firstRowFix
  s.textContent = `[data-voi-group] > *:first-child { border-top: none !important; }`
  document.head.appendChild(s)
}
