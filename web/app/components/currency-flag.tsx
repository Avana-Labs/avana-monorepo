"use client"

import type { CurrencyCode } from "./display-preferences"

type CurrencyFlagProps = {
  code: CurrencyCode
  className?: string
}

export function CurrencyFlag({ code, className = "h-6 w-6" }: CurrencyFlagProps) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className={className}>
      <defs>
        <clipPath id={`flag-${code}`}>
          <circle cx="12" cy="12" r="10" />
        </clipPath>
      </defs>
      <g clipPath={`url(#flag-${code})`}>
        {code === "USD" ? <UsdFlag /> : null}
        {code === "ARS" ? <ArsFlag /> : null}
        {code === "AUD" ? <AudFlag /> : null}
        {code === "BRL" ? <BrlFlag /> : null}
        {code === "CAD" ? <CadFlag /> : null}
        {code === "CNY" ? <CnyFlag /> : null}
        {code === "COP" ? <CopFlag /> : null}
        {code === "EUR" ? <EurFlag /> : null}
        {code === "GBP" ? <GbpFlag /> : null}
        {code === "HKD" ? <HkdFlag /> : null}
        {code === "IDR" ? <IdrFlag /> : null}
        {code === "INR" ? <InrFlag /> : null}
        {code === "JPY" ? <JpyFlag /> : null}
        {code === "KRW" ? <KrwFlag /> : null}
      </g>
      <circle cx="12" cy="12" r="10" fill="none" stroke="rgba(15,23,42,0.08)" />
    </svg>
  )
}

function UsdFlag() {
  const stars: JSX.Element[] = []
  for (const y of [2, 5, 8]) {
    for (const x of [2.2, 5.3, 8.4]) {
      stars.push(<circle key={`${x}-${y}`} cx={x} cy={y} r="0.55" fill="#fff" />)
    }
  }
  return (
    <>
      <rect width="24" height="24" fill="#fff" />
      {[0, 4, 8, 12, 16, 20].map((y) => (
        <rect key={y} y={y} width="24" height="2" fill="#d94b5a" />
      ))}
      <rect width="11" height="10" fill="#28407a" />
      {stars}
    </>
  )
}

function ArsFlag() {
  return (
    <>
      <rect width="24" height="8" fill="#8ec5ff" />
      <rect y="8" width="24" height="8" fill="#fff" />
      <rect y="16" width="24" height="8" fill="#8ec5ff" />
      <circle cx="12" cy="12" r="2" fill="#f2b632" />
    </>
  )
}

function AudFlag() {
  return (
    <>
      <rect width="24" height="24" fill="#1e2f97" />
      <rect width="10" height="10" fill="#163a8a" />
      <path d="M0 0h10v2.2H0zm0 7.8h10V10H0zM3.9 0h2.2v10H3.9z" fill="#fff" />
      <path d="M0 4.4h10v1.2H0zm4.4 0V0h1.2v10H4.4z" fill="#ef4444" />
      {[15.5, 18.4, 20.3].map((x, i) => (
        <circle key={i} cx={x} cy={6 + i * 4.2} r="1.1" fill="#fff" />
      ))}
    </>
  )
}

function BrlFlag() {
  return (
    <>
      <rect width="24" height="24" fill="#239b56" />
      <path d="M12 4l7 8-7 8-7-8z" fill="#f4d03f" />
      <circle cx="12" cy="12" r="3.4" fill="#2e4d9b" />
    </>
  )
}

function CadFlag() {
  return (
    <>
      <rect width="24" height="24" fill="#fff" />
      <rect width="5" height="24" fill="#e53935" />
      <rect x="19" width="5" height="24" fill="#e53935" />
      <path d="M12 6l1.4 2.6 2.8-.4-1.8 2.2 1.1 2.7-2.5-1.1L10.5 13l1.1-2.7-1.8-2.2 2.8.4z" fill="#e53935" />
    </>
  )
}

function CnyFlag() {
  return (
    <>
      <rect width="24" height="24" fill="#de1f3f" />
      <path d="M7 5.5l.9 2.1 2.3.2-1.7 1.4.6 2.2L7 10.1 5 11.4l.6-2.2-1.7-1.4 2.3-.2z" fill="#f6d04d" />
    </>
  )
}

function CopFlag() {
  return (
    <>
      <rect width="24" height="12" fill="#f4d03f" />
      <rect y="12" width="24" height="6" fill="#1f4aa8" />
      <rect y="18" width="24" height="6" fill="#d8223a" />
    </>
  )
}

function EurFlag() {
  return (
    <>
      <rect width="24" height="24" fill="#1546b0" />
      {[0, 60, 120, 180, 240, 300].map((deg, index) => {
        const radians = (deg * Math.PI) / 180
        const x = 12 + Math.cos(radians) * 4.2
        const y = 12 + Math.sin(radians) * 4.2
        return <circle key={index} cx={x} cy={y} r="0.9" fill="#f6d04d" />
      })}
    </>
  )
}

function GbpFlag() {
  return (
    <>
      <rect width="24" height="24" fill="#1f3d95" />
      <path d="M0 3l3-3 21 21-3 3zM21 0l3 3L3 24l-3-3z" fill="#fff" />
      <path
        d="M0 4.4L4.4 0h2.3L0 6.7zm17.3 19.6L24 17.3v-2.3L15 24zM24 6.7L17.3 0H15l9 9zm-19.6 17.3L0 19.6V17.3L6.7 24z"
        fill="#ef4444"
      />
      <rect x="9" width="6" height="24" fill="#fff" />
      <rect y="9" width="24" height="6" fill="#fff" />
      <rect x="10.2" width="3.6" height="24" fill="#ef4444" />
      <rect y="10.2" width="24" height="3.6" fill="#ef4444" />
    </>
  )
}

function HkdFlag() {
  return (
    <>
      <rect width="24" height="24" fill="#c81e1e" />
      {[0, 72, 144, 216, 288].map((deg, index) => {
        const radians = (deg * Math.PI) / 180
        const x = 12 + Math.cos(radians) * 2.3
        const y = 12 + Math.sin(radians) * 2.3
        return <circle key={index} cx={x} cy={y} r="1.5" fill="#fff" />
      })}
    </>
  )
}

function IdrFlag() {
  return (
    <>
      <rect width="24" height="12" fill="#e11d2e" />
      <rect y="12" width="24" height="12" fill="#fff" />
    </>
  )
}

function InrFlag() {
  return (
    <>
      <rect width="24" height="8" fill="#f59e42" />
      <rect y="8" width="24" height="8" fill="#fff" />
      <rect y="16" width="24" height="8" fill="#1f8b3c" />
      <circle cx="12" cy="12" r="1.7" fill="none" stroke="#2451b2" strokeWidth="1" />
    </>
  )
}

function JpyFlag() {
  return (
    <>
      <rect width="24" height="24" fill="#fff" />
      <circle cx="12" cy="12" r="4.1" fill="#d61f2c" />
    </>
  )
}

function KrwFlag() {
  return (
    <>
      <rect width="24" height="24" fill="#fff" />
      <path d="M12 8a4 4 0 0 1 0 8 4 4 0 0 0 0-8z" fill="#d62839" />
      <path d="M12 16a4 4 0 0 1 0-8 4 4 0 0 0 0 8z" fill="#2563eb" />
      <path d="M5 7h3M5.5 8.3h3M16 15.7h3M15.5 17h3" stroke="#111827" strokeWidth="1" strokeLinecap="round" />
    </>
  )
}
