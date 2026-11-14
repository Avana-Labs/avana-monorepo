"use client"

import { useEffect, useState } from "react"

function getInitialMatch(query: string, defaultValue: boolean) {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
    return defaultValue
  }

  return window.matchMedia(query).matches
}

export function useMediaQuery(query: string, defaultValue = false, hydrateFromDefault = false): boolean {
  // Components rendered on the server can opt into the server-selected default
  // for their first client render. The effect reconciles the real media query
  // immediately after hydration without producing mismatched responsive markup.
  const [matches, setMatches] = useState(() =>
    hydrateFromDefault ? defaultValue : getInitialMatch(query, defaultValue),
  )

  useEffect(() => {
    if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
      return
    }
    const mql = window.matchMedia(query)
    const handler = (event: MediaQueryListEvent) => setMatches(event.matches)
    setMatches(mql.matches)
    mql.addEventListener("change", handler)
    return () => mql.removeEventListener("change", handler)
  }, [query])

  return matches
}
