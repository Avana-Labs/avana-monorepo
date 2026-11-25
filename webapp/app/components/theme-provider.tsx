"use client"

import type React from "react"
import { createContext, useContext, useEffect, useLayoutEffect, useMemo, useState } from "react"

export type Theme = "light" | "dark" | "system"

type ThemeContextValue = {
  theme: Theme
  resolvedTheme: "light" | "dark"
  setTheme: (theme: Theme) => void
}

const THEME_STORAGE_KEY = "avana-theme"
const ThemeContext = createContext<ThemeContextValue | null>(null)

function getSystemTheme() {
  if (typeof window === "undefined") {
    return "light" as const
  }

  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light"
}

function getStoredTheme(storageKey: string, fallback: Theme) {
  if (typeof window === "undefined") {
    return fallback
  }

  const storedTheme = window.localStorage.getItem(storageKey) as Theme | null
  if (storedTheme === "light" || storedTheme === "dark" || storedTheme === "system") {
    return storedTheme
  }

  return fallback
}

function applyThemeClass(resolvedTheme: "light" | "dark") {
  const root = document.documentElement
  root.classList.toggle("dark", resolvedTheme === "dark")
  root.style.colorScheme = resolvedTheme
}

function applyThemeWithoutTransitions(resolvedTheme: "light" | "dark") {
  document.head.querySelectorAll('[data-avana-theme-transition="true"]').forEach((node) => node.remove())

  const style = document.createElement("style")
  style.setAttribute("data-avana-theme-transition", "true")
  style.textContent = `
    *,
    *::before,
    *::after {
      transition-property: none !important;
      transition-duration: 0s !important;
      transition-delay: 0s !important;
      animation: none !important;
    }
  `
  document.head.appendChild(style)

  applyThemeClass(resolvedTheme)

  // Force the new theme to compute while transitions are disabled, then remove
  // the guard synchronously. Leaving this style mounted disables every animation
  // in the app, including the global skeleton shimmer.
  void document.documentElement.offsetHeight
  style.remove()
}

type ThemeProviderProps = React.PropsWithChildren<{
  attribute?: string
  defaultTheme?: Theme
  disableTransitionOnChange?: boolean
  enableSystem?: boolean
  storageKey?: string
}>

export function ThemeProvider({
  children,
  defaultTheme = "light",
  disableTransitionOnChange = true,
  storageKey = THEME_STORAGE_KEY,
}: ThemeProviderProps) {
  const [theme, setThemeState] = useState<Theme>(() => getStoredTheme(storageKey, defaultTheme))
  const [systemTheme, setSystemTheme] = useState<"light" | "dark">(() => getSystemTheme())
  const [hydrated, setHydrated] = useState(false)

  useEffect(() => {
    setThemeState(getStoredTheme(storageKey, defaultTheme))
    setSystemTheme(getSystemTheme())
    setHydrated(true)
  }, [defaultTheme, storageKey])

  useEffect(() => {
    if (!hydrated) return
    window.localStorage.setItem(storageKey, theme)
  }, [hydrated, storageKey, theme])

  // Other tabs write the same localStorage key; the `storage` event only fires in
  // sibling documents, so this keeps theme in sync without same-tab echo loops.
  useEffect(() => {
    const handleStorage = (event: StorageEvent) => {
      if (event.key !== storageKey || event.newValue == null) return
      if (event.newValue !== "light" && event.newValue !== "dark" && event.newValue !== "system") return
      const next = event.newValue as Theme
      setThemeState((current) => (current === next ? current : next))
    }

    window.addEventListener("storage", handleStorage)
    return () => window.removeEventListener("storage", handleStorage)
  }, [storageKey])

  useEffect(() => {
    if (typeof window === "undefined") {
      return
    }

    const media = window.matchMedia("(prefers-color-scheme: dark)")
    const handleChange = () => setSystemTheme(getSystemTheme())

    media.addEventListener("change", handleChange)
    return () => media.removeEventListener("change", handleChange)
  }, [])

  const resolvedTheme = theme === "system" ? systemTheme : theme

  useLayoutEffect(() => {
    if (typeof window === "undefined") {
      return
    }

    if (disableTransitionOnChange) {
      applyThemeWithoutTransitions(resolvedTheme)
    } else {
      applyThemeClass(resolvedTheme)
    }
  }, [disableTransitionOnChange, resolvedTheme])

  const value = useMemo<ThemeContextValue>(
    () => ({
      theme,
      resolvedTheme,
      setTheme: setThemeState,
    }),
    [resolvedTheme, theme],
  )

  return <ThemeContext.Provider value={value}>{children}</ThemeContext.Provider>
}

export function useTheme() {
  const context = useContext(ThemeContext)
  if (!context) {
    throw new Error("useTheme must be used within a ThemeProvider")
  }

  return context
}

// Same as useTheme but returns null instead of throwing when no provider is
// mounted, so components that offer a theme toggle can render (without it) in
// contexts that don't wrap ThemeProvider.
export function useThemeOptional() {
  return useContext(ThemeContext)
}
