import { useState, type CSSProperties } from 'react'
import StarClouds from './StarClouds'

// ---------------------------------------------------------------------------
// Oula — iOS onboarding
// ---------------------------------------------------------------------------
// Both screens share ONE persistent star canvas (StarClouds). Advancing from
// screen 1 → 2 only animates a `progress` value, so the big cloud smoothly
// zooms out to become the small central cloud and the satellite clouds drift
// in — no element ever unmounts, so nothing pops or disappears.
// ---------------------------------------------------------------------------

export default function OulaOnboarding({
  onExplore,
}: {
  onExplore?: () => void
}) {
  const [screen, setScreen] = useState<0 | 1>(0)

  return (
    <div style={stage}>
      <div style={screenFrame}>
        {/* persistent, shared across both screens */}
        <StarClouds progress={screen} />

        {/* Screen 1 content */}
        <div
          style={{
            ...contentLayer,
            opacity: screen === 0 ? 1 : 0,
            transform: `scale(${screen === 0 ? 1 : 1.04})`,
            pointerEvents: screen === 0 ? 'auto' : 'none',
          }}
        >
          <div style={{ flex: 1 }} />
          <div style={textBlock}>
            <span style={wordmark}>oula</span>
            <h1 style={headline}>
              Care that grows
              <br />
              with you
            </h1>
            <p style={subhead}>
              Pregnancy, birth and beyond — guidance from midwives and doctors,
              in one calm place.
            </p>
          </div>
          <div style={buttonStack}>
            <button style={primaryButton} onClick={() => setScreen(1)}>
              Continue
            </button>
            <button style={ghostButton} onClick={onExplore}>
              Explore the app
            </button>
            <p style={finePrint}>
              By continuing you agree to our Terms&nbsp;of&nbsp;Service and
              Privacy&nbsp;Policy.
            </p>
          </div>
        </div>

        {/* Screen 2 content */}
        <div
          style={{
            ...contentLayer,
            opacity: screen === 1 ? 1 : 0,
            transform: `scale(${screen === 1 ? 1 : 0.96})`,
            pointerEvents: screen === 1 ? 'auto' : 'none',
          }}
        >
          <div style={{ flex: 1 }} />
          <div style={textBlock}>
            <h1 style={headline}>A whole universe of care</h1>
            <p style={subhead}>
              Every question, appointment and milestone — connected, and always
              within reach.
            </p>
          </div>
          <div style={buttonStack}>
            <button style={primaryButton} onClick={onExplore}>
              Get started
            </button>
            <button style={ghostButtonQuiet} onClick={() => setScreen(0)}>
              Back
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}

// ---------------------------------------------------------------------------
// Styles
// ---------------------------------------------------------------------------

const PLUM_BG_TOP = '#231331'
const PLUM_BG_BOT = '#120a1c'
const CORAL = '#E8794A'
const CREAM = '#F7EFE6'

const stage: CSSProperties = {
  minHeight: '100dvh',
  width: '100%',
  display: 'flex',
  alignItems: 'stretch',
  justifyContent: 'center',
  background: '#0b0712',
}

const screenFrame: CSSProperties = {
  position: 'relative',
  width: '100%',
  maxWidth: 430,
  minHeight: '100dvh',
  overflow: 'hidden',
  background: `radial-gradient(120% 80% at 50% 22%, ${PLUM_BG_TOP} 0%, ${PLUM_BG_BOT} 70%)`,
}

const contentLayer: CSSProperties = {
  position: 'absolute',
  inset: 0,
  display: 'flex',
  flexDirection: 'column',
  padding:
    'calc(env(safe-area-inset-top, 0px) + 28px) 26px calc(env(safe-area-inset-bottom, 0px) + 22px)',
  transition: 'opacity 0.55s ease, transform 0.7s ease',
  zIndex: 1,
}

const textBlock: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  alignItems: 'center',
  gap: 12,
  textAlign: 'center',
  paddingBottom: 30,
}

const wordmark: CSSProperties = {
  fontSize: 26,
  fontWeight: 600,
  letterSpacing: '0.06em',
  color: CREAM,
  opacity: 0.9,
  marginBottom: 6,
}

const headline: CSSProperties = {
  margin: 0,
  fontFamily: 'Georgia, "Times New Roman", serif',
  fontSize: 32,
  lineHeight: 1.18,
  fontWeight: 500,
  letterSpacing: '-0.01em',
  color: CREAM,
}

const subhead: CSSProperties = {
  margin: '0 auto',
  maxWidth: 300,
  fontSize: 15.5,
  lineHeight: 1.5,
  color: 'rgba(247,239,230,0.72)',
}

const buttonStack: CSSProperties = {
  display: 'flex',
  flexDirection: 'column',
  gap: 11,
}

const buttonBase: CSSProperties = {
  width: '100%',
  height: 54,
  borderRadius: 27,
  fontSize: 17,
  fontWeight: 600,
  border: 'none',
}

const primaryButton: CSSProperties = {
  ...buttonBase,
  background: CORAL,
  color: '#FFF7F0',
  boxShadow: '0 10px 26px rgba(232,121,74,0.4)',
}

const ghostButton: CSSProperties = {
  ...buttonBase,
  background: 'rgba(247,239,230,0.06)',
  color: CREAM,
  border: '1.5px solid rgba(247,239,230,0.28)',
}

const ghostButtonQuiet: CSSProperties = {
  ...buttonBase,
  background: 'transparent',
  color: 'rgba(247,239,230,0.7)',
  fontWeight: 500,
}

const finePrint: CSSProperties = {
  margin: '4px 0 0',
  textAlign: 'center',
  fontSize: 12,
  lineHeight: 1.5,
  color: 'rgba(247,239,230,0.5)',
}
