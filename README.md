# Oula — iOS onboarding prototype

A Vite + React prototype of the Oula onboarding flow. The app's entry point
(`src/main.tsx`) renders the onboarding directly, so `npm run dev` shows it with
no extra navigation.

> Note: this repo also contains the original **Voi** voice-to-text app
> (`src/App.tsx`). It is kept in the repo but is not the current entry point.

## Run it locally

```bash
npm install
npm run dev
```

Then open the URL Vite prints (usually http://localhost:5173) and click
**Continue** to see the star-cloud zoom-out transition.

For the intended iPhone look, open your browser devtools, toggle the device
toolbar, and choose an iPhone — the screen is laid out as a 430px-wide phone
frame.

## Build / preview a production bundle

```bash
npm run build     # type-check + build into dist/
npm run preview   # serve the built bundle
```

## The onboarding

- `src/oula/OulaOnboarding.tsx` — the two-screen flow. Both screens share one
  persistent star canvas, so advancing only animates a `progress` value.
- `src/oula/StarClouds.tsx` — the shared canvas. It owns every star for the
  whole onboarding: the hero cloud shrinks in place (same stars → a true
  zoom-out) while satellite clouds fade and drift in around it. Nothing mounts
  or unmounts mid-transition, which keeps it seamless.
