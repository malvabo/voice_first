import { useEffect, useRef } from 'react'

// ---------------------------------------------------------------------------
// StarClouds
// ---------------------------------------------------------------------------
// A single persistent canvas that owns EVERY star for the whole onboarding.
// Screens do not each draw their own cloud — instead this component animates a
// continuous `progress` value (0 = screen 1, 1 = screen 2) and interpolates:
//
//   • the hero cloud shrinks in place (same stars) → reads as a real zoom-out,
//     never a swap;
//   • satellite clouds fade + drift in from the hero, staggered, so they
//     "arrive" organically rather than popping.
//
// Because the star positions are created ONCE and only their transform changes
// per frame, the transition is perfectly smooth with nothing appearing or
// disappearing.
// ---------------------------------------------------------------------------

interface Star {
  r: number // radial position within cluster, 0..1
  a: number // angle
  size: number // px at unit scale
  base: number // base brightness 0..1
  tw: number // twinkle phase
  tws: number // twinkle speed
  hue: number // 0 cream, 1 coral, tinting
}

interface Cluster {
  isHero: boolean
  stars: Star[]
  // screen-2 placement, as offsets from the hero centre in `unit` fractions
  ox: number
  oy: number
  radius2: number // cluster radius at screen 2, in `unit` fractions
  appearAt: number // progress where this satellite begins to arrive
  rot: number // current rotation
  rotSpeed: number
  driftPhase: number
  driftAmp: number
  driftSpeed: number
}

// deterministic-ish RNG so a remount looks the same
function mulberry32(seed: number) {
  return function () {
    seed |= 0
    seed = (seed + 0x6d2b79f5) | 0
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

function makeStars(rng: () => number, count: number, bright: number): Star[] {
  const stars: Star[] = []
  for (let i = 0; i < count; i++) {
    // concentrate toward the centre for a "cloud" feel
    const r = Math.pow(rng(), 0.62)
    const isBright = rng() < bright
    stars.push({
      r,
      a: rng() * Math.PI * 2,
      size: isBright ? 1.6 + rng() * 1.6 : 0.6 + rng() * 1.1,
      base: isBright ? 0.85 + rng() * 0.15 : 0.35 + rng() * 0.4,
      tw: rng() * Math.PI * 2,
      tws: 0.6 + rng() * 1.8,
      hue: rng(),
    })
  }
  return stars
}

function easeInOut(t: number): number {
  return t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2
}

function smoothstep(edge0: number, edge1: number, x: number): number {
  const t = Math.min(1, Math.max(0, (x - edge0) / (edge1 - edge0)))
  return t * t * (3 - 2 * t)
}

export default function StarClouds({ progress }: { progress: number }) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const targetRef = useRef(progress)
  targetRef.current = progress

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const ctx = canvas.getContext('2d')
    if (!ctx) return

    const rng = mulberry32(20260707)

    // Hero cloud — the big one that zooms out.
    const hero: Cluster = {
      isHero: true,
      stars: makeStars(rng, 260, 0.16),
      ox: 0,
      oy: 0,
      radius2: 0.19,
      appearAt: 0,
      rot: 0,
      rotSpeed: 0.012,
      driftPhase: 0,
      driftAmp: 0.006,
      driftSpeed: 0.25,
    }

    // Satellites — arrive around the shrunken hero on screen 2.
    const satLayout = [
      { ox: -0.30, oy: -0.30, radius2: 0.085, appearAt: 0.30 },
      { ox: 0.33, oy: -0.24, radius2: 0.070, appearAt: 0.42 },
      { ox: 0.30, oy: 0.30, radius2: 0.080, appearAt: 0.36 },
      { ox: -0.33, oy: 0.28, radius2: 0.062, appearAt: 0.50 },
      { ox: 0.02, oy: 0.42, radius2: 0.055, appearAt: 0.58 },
      { ox: -0.42, oy: 0.02, radius2: 0.050, appearAt: 0.46 },
    ]
    const satellites: Cluster[] = satLayout.map((s) => ({
      isHero: false,
      stars: makeStars(rng, 42, 0.22),
      ox: s.ox,
      oy: s.oy,
      radius2: s.radius2,
      appearAt: s.appearAt,
      rot: rng() * Math.PI * 2,
      rotSpeed: (rng() - 0.5) * 0.05,
      driftPhase: rng() * Math.PI * 2,
      driftAmp: 0.01 + rng() * 0.012,
      driftSpeed: 0.3 + rng() * 0.4,
    }))

    const clusters = [hero, ...satellites]

    // spring-eased progress for a premium, continuous feel
    let current = targetRef.current
    let velocity = 0
    const stiffness = 46
    const damping = 13

    let raf = 0
    let last = performance.now()

    const drawCluster = (
      cx: number,
      cy: number,
      radiusPx: number,
      opacity: number,
      c: Cluster,
      t: number,
    ) => {
      if (opacity <= 0.001 || radiusPx <= 0.5) return
      const cosR = Math.cos(c.rot)
      const sinR = Math.sin(c.rot)
      for (let i = 0; i < c.stars.length; i++) {
        const s = c.stars[i]
        const rr = s.r * radiusPx
        const px = Math.cos(s.a) * rr
        const py = Math.sin(s.a) * rr
        const x = cx + px * cosR - py * sinR
        const y = cy + px * sinR + py * cosR
        const twinkle = 0.62 + 0.38 * Math.sin(t * s.tws + s.tw)
        const alpha = s.base * twinkle * opacity
        if (alpha <= 0.01) continue
        // warm cream → coral tint
        const rC = 247
        const gC = Math.round(239 - s.hue * 90)
        const bC = Math.round(230 - s.hue * 110)
        ctx.beginPath()
        ctx.fillStyle = `rgba(${rC},${gC},${bC},${alpha})`
        ctx.arc(x, y, s.size, 0, Math.PI * 2)
        ctx.fill()
        // soft glow for the brightest
        if (s.size > 1.7) {
          ctx.beginPath()
          ctx.fillStyle = `rgba(${rC},${gC},${bC},${alpha * 0.18})`
          ctx.arc(x, y, s.size * 3.4, 0, Math.PI * 2)
          ctx.fill()
        }
      }
    }

    const render = (now: number) => {
      const dt = Math.min(0.05, (now - last) / 1000)
      last = now
      const t = now / 1000

      // integrate spring toward target
      const target = targetRef.current
      velocity += (target - current) * stiffness * dt
      velocity *= Math.exp(-damping * dt)
      current += velocity * dt
      const p = easeInOut(Math.min(1, Math.max(0, current)))

      const dpr = window.devicePixelRatio || 1
      const w = canvas.clientWidth
      const h = canvas.clientHeight
      if (canvas.width !== w * dpr || canvas.height !== h * dpr) {
        canvas.width = w * dpr
        canvas.height = h * dpr
      }
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
      ctx.clearRect(0, 0, w, h)

      const unit = Math.min(w, h)

      // hero centre glides slightly up as it shrinks, making room for content
      const heroCx = w * 0.5
      const heroCy = h * (0.46 - 0.08 * p)

      // hero radius: big (screen 1) → small (screen 2). Same stars throughout.
      const heroRadius = unit * (0.46 - (0.46 - hero.radius2) * p)

      // advance rotations continuously
      for (const c of clusters) c.rot += c.rotSpeed * dt

      // hero drift
      const hDriftX = Math.sin(t * hero.driftSpeed + hero.driftPhase) * hero.driftAmp * unit
      const hDriftY = Math.cos(t * hero.driftSpeed * 0.8 + hero.driftPhase) * hero.driftAmp * unit
      drawCluster(heroCx + hDriftX, heroCy + hDriftY, heroRadius, 1, hero, t)

      // satellites: fade + settle inward as they arrive
      for (const c of satellites) {
        const arrive = smoothstep(c.appearAt, Math.min(1, c.appearAt + 0.45), p)
        if (arrive <= 0) continue
        const settle = easeInOut(arrive)
        // start a touch further out, ease to final offset
        const spread = 1 + (1 - settle) * 0.35
        const driftX = Math.sin(t * c.driftSpeed + c.driftPhase) * c.driftAmp * unit
        const driftY = Math.cos(t * c.driftSpeed * 0.9 + c.driftPhase) * c.driftAmp * unit
        const cx = heroCx + c.ox * unit * spread + driftX
        const cy = heroCy + c.oy * unit * spread + driftY
        const radiusPx = unit * c.radius2 * (0.6 + 0.4 * settle)
        drawCluster(cx, cy, radiusPx, arrive, c, t)
      }

      raf = requestAnimationFrame(render)
    }

    raf = requestAnimationFrame(render)
    return () => cancelAnimationFrame(raf)
  }, [])

  return (
    <canvas
      ref={canvasRef}
      style={{
        position: 'absolute',
        inset: 0,
        width: '100%',
        height: '100%',
        display: 'block',
        pointerEvents: 'none',
      }}
    />
  )
}
