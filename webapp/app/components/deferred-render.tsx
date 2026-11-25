"use client"

import { createElement, type ReactNode, useEffect, useRef, useState } from "react"

type DeferredRenderProps = {
  children: ReactNode
  fallback: ReactNode
  rootMargin?: string
}

/** Mounts expensive UI only after the section approaches the viewport. */
export function DeferredRender({ children, fallback, rootMargin = "200px 0px" }: DeferredRenderProps) {
  const containerRef = useRef<HTMLDivElement | null>(null)
  const [shouldRender, setShouldRender] = useState(false)

  useEffect(() => {
    const element = containerRef.current

    if (!element || shouldRender) {
      return
    }

    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          setShouldRender(true)
          observer.disconnect()
        }
      },
      { rootMargin },
    )

    observer.observe(element)

    return () => observer.disconnect()
  }, [rootMargin, shouldRender])

  return createElement("div", { ref: containerRef }, shouldRender ? children : fallback)
}
