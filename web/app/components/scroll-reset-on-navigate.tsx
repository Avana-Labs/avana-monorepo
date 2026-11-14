"use client"

import { useEffect, useRef } from "react"
import { usePathname } from "next/navigation"

/**
 * Reset window scroll to the top on forward navigation.
 *
 * Next's App Router normally scrolls to the top on navigation, but it skips the
 * reset when the destination page is *shorter* than the current scroll offset:
 * the browser clamps the scroll to the new (short) page's max, Next sees the new
 * content's top as "already visible", and leaves you mid-scroll — so short pages
 * and the full-screen action flows open cut off at the top. This guarantees the
 * top on every push/replace.
 *
 * Back/forward (POP) navigations are left alone so the browser's own scroll
 * restoration still returns you to where you were. Keyed on pathname only, so
 * query-only transitions (e.g. dashboard `?tab=` switches) don't force a reset.
 */
export function ScrollResetOnNavigate() {
  const pathname = usePathname()
  const isPopRef = useRef(false)

  useEffect(() => {
    const onPopState = () => {
      isPopRef.current = true
    }
    window.addEventListener("popstate", onPopState)
    return () => window.removeEventListener("popstate", onPopState)
  }, [])

  useEffect(() => {
    if (isPopRef.current) {
      // Back/forward — defer to native/Next scroll restoration.
      isPopRef.current = false
      return
    }
    // An anchored (#hash) navigation should scroll to its target, not the top.
    if (window.location.hash) return
    window.scrollTo(0, 0)
  }, [pathname])

  return null
}
