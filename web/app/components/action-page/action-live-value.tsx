"use client"

import { useEffect, useRef, useState } from "react"
import { LANGUAGE_HTML_LANG } from "@/app/lib/i18n/language-html-lang"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { cn } from "@/lib/utils"

type ParsedValue = {
  prefix: string
  numeric: number
  suffix: string
  decimals: number
  locale: string
}

function parseAnimatedValue(text: string, locale: string): ParsedValue | null {
  const trimmed = text.trim()
  if (!trimmed || trimmed === "—" || trimmed === "∞") return null

  const match = trimmed.match(/^([^0-9.-]*)(-?\d[\d,]*(?:\.\d+)?)(.*)$/)
  if (!match) return null

  const prefix = match[1] ?? ""
  const numericText = match[2] ?? ""
  const suffix = match[3] ?? ""
  const numeric = Number.parseFloat(numericText.replace(/,/g, ""))
  if (!Number.isFinite(numeric)) return null

  const decimals = numericText.includes(".") ? (numericText.split(".")[1]?.length ?? 0) : 0

  return { prefix, numeric, suffix, decimals, locale }
}

function formatAnimatedValue(parsed: ParsedValue, value: number) {
  const formatted = new Intl.NumberFormat(parsed.locale, {
    minimumFractionDigits: parsed.decimals,
    maximumFractionDigits: parsed.decimals,
  }).format(value)

  return `${parsed.prefix}${formatted}${parsed.suffix}`
}

function easeOutCubic(value: number) {
  return 1 - (1 - value) ** 3
}

export function AnimatedTextValue({
  text,
  className,
  durationMs = 520,
  disabled = false,
  animateOnMount = false,
  ariaLive,
  ariaAtomic = true,
}: {
  text: string
  className?: string
  durationMs?: number
  disabled?: boolean
  animateOnMount?: boolean
  ariaLive?: "off" | "polite" | "assertive"
  ariaAtomic?: boolean
}) {
  const { language } = useTranslation()
  const locale = LANGUAGE_HTML_LANG[language] ?? "en"
  const [displayText, setDisplayText] = useState(() => {
    const parsed = parseAnimatedValue(text, locale)
    if (!animateOnMount || !parsed) return text
    return formatAnimatedValue(parsed, 0)
  })
  const previousTextRef = useRef<string | null>(null)
  const hasMountedRef = useRef(false)
  const reducedMotionRef = useRef(false)
  const frameRef = useRef<number | null>(null)

  useEffect(() => {
    if (typeof window === "undefined" || !window.matchMedia) return undefined

    const media = window.matchMedia("(prefers-reduced-motion: reduce)")
    const updateReducedMotion = () => {
      reducedMotionRef.current = media.matches
    }

    updateReducedMotion()
    media.addEventListener("change", updateReducedMotion)

    return () => media.removeEventListener("change", updateReducedMotion)
  }, [])

  useEffect(() => {
    const previous = previousTextRef.current
    previousTextRef.current = text

    if (frameRef.current != null) {
      window.cancelAnimationFrame(frameRef.current)
      frameRef.current = null
    }

    if (disabled || reducedMotionRef.current) {
      setDisplayText(text)
      hasMountedRef.current = true
      return undefined
    }

    if (previous === text && (hasMountedRef.current || !animateOnMount)) {
      setDisplayText(text)
      hasMountedRef.current = true
      return undefined
    }

    const to = parseAnimatedValue(text, locale)
    if (!to) {
      setDisplayText(text)
      hasMountedRef.current = true
      return undefined
    }

    const from = previous ? parseAnimatedValue(previous, locale) : null
    if (from && (from.prefix !== to.prefix || from.suffix !== to.suffix)) {
      setDisplayText(text)
      hasMountedRef.current = true
      return undefined
    }

    const source =
      from ??
      (!hasMountedRef.current && animateOnMount
        ? { prefix: to.prefix, numeric: 0, suffix: to.suffix, decimals: to.decimals }
        : null)

    if (!source) {
      setDisplayText(text)
      hasMountedRef.current = true
      return undefined
    }

    const delta = to.numeric - source.numeric
    if (delta === 0) {
      setDisplayText(text)
      hasMountedRef.current = true
      return undefined
    }

    hasMountedRef.current = true
    setDisplayText(formatAnimatedValue(to, source.numeric))

    const start = window.performance.now()

    const tick = (now: number) => {
      const progress = Math.max(0, Math.min(1, (now - start) / durationMs))
      const eased = easeOutCubic(progress)
      const current = source.numeric + delta * eased
      setDisplayText(formatAnimatedValue(to, current))

      if (progress < 1) {
        frameRef.current = window.requestAnimationFrame(tick)
        return
      }

      frameRef.current = null
      setDisplayText(text)
    }

    frameRef.current = window.requestAnimationFrame(tick)

    return () => {
      if (frameRef.current != null) {
        window.cancelAnimationFrame(frameRef.current)
        frameRef.current = null
      }
    }
  }, [animateOnMount, disabled, durationMs, locale, text])

  return (
    <span aria-live={ariaLive} aria-atomic={ariaAtomic} className={cn("inline-block", className)}>
      {displayText}
    </span>
  )
}
