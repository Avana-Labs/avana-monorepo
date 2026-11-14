"use client"

import { useEffect, useState } from "react"

/**
 * Ticks once per minute so cooldown chips update without a Convex round-trip.
 * Callers should pass position.cooldownEndsAt (or withdrawalWindowEndsAt) as
 * a UTC ms timestamp; when it's undefined the hook stays quiet and returns 0.
 */
export function useCooldownCountdown(endsAt: number | undefined | null): {
  remainingMs: number
  remainingLabel: string
} {
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (!endsAt) return
    const interval = setInterval(() => setNow(Date.now()), 60_000)
    return () => clearInterval(interval)
  }, [endsAt])
  const remainingMs = endsAt ? Math.max(0, endsAt - now) : 0
  const totalHours = Math.ceil(remainingMs / (60 * 60 * 1000))
  const days = Math.floor(totalHours / 24)
  const hours = totalHours % 24
  const remainingLabel = remainingMs > 0 ? `${days}d ${hours}h` : "Ready"
  return { remainingMs, remainingLabel }
}
