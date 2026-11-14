"use client"

import { useEffect, useState } from "react"

/** Returns false on the server and first client render, then true after mount. */
export function useHasMounted() {
  const [mounted, setMounted] = useState(false)

  useEffect(() => {
    setMounted(true)
  }, [])

  return mounted
}
