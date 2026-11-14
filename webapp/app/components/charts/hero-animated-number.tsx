"use client"

import { animate, useMotionValue, useMotionValueEvent, useReducedMotion } from "framer-motion"
import { useEffect, useRef, useState } from "react"
import { cn } from "@/lib/utils"

type HeroAnimatedNumberProps = {
  /** Target numeric value to chase. */
  value: number
  /** Format the live spring value for display. */
  format: (value: number) => string
  className?: string
  /**
   * Spring settle target in ms-ish feel. Higher stiffness = snappier Uniswap scrub.
   * Defaults tuned for ~40–120ms visual settle while still reading as continuous.
   */
  stiffness?: number
  damping?: number
  mass?: number
}

/**
 * Millisecond-smooth headline number: a high-stiffness spring that retargets on
 * every scrub/frame update. Not a fixed-duration count-up (those feel laggy while
 * the cursor is moving).
 */
export function HeroAnimatedNumber({
  value,
  format,
  className,
  stiffness = 680,
  damping = 48,
  mass = 0.55,
}: HeroAnimatedNumberProps) {
  const reduceMotion = useReducedMotion()
  const motionValue = useMotionValue(value)
  const formatRef = useRef(format)
  formatRef.current = format
  const [display, setDisplay] = useState(() => format(value))

  useMotionValueEvent(motionValue, "change", (latest) => {
    setDisplay(formatRef.current(latest))
  })

  useEffect(() => {
    if (reduceMotion) {
      motionValue.set(value)
      setDisplay(formatRef.current(value))
      return
    }

    const controls = animate(motionValue, value, {
      type: "spring",
      stiffness,
      damping,
      mass,
      restDelta: 0.001,
      restSpeed: 0.01,
    })

    return () => controls.stop()
  }, [damping, mass, motionValue, reduceMotion, stiffness, value])

  return <span className={cn("tabular-nums", className)}>{display}</span>
}
