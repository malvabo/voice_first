import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import OulaOnboarding from './oula/OulaOnboarding.tsx'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <OulaOnboarding />
  </StrictMode>,
)
