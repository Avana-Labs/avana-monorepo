"use client"

import { useEffect, useState, type ComponentType } from "react"
import { SearchTrigger } from "./search-trigger"

type SearchComponent = ComponentType<{ iconOnly?: boolean; tone?: "nav" | "brand"; initialOpen?: boolean }>
let searchPromise: Promise<SearchComponent> | null = null
const loadSearchCommand = () => {
  searchPromise ??= import("./search-command").then((mod) => mod.SearchCommand)
  return searchPromise
}

const shortcutOpeners = new Set<() => void>()
let shortcutListening = false

function onSlash(event: KeyboardEvent) {
  const target = event.target
  if (
    event.key !== "/" ||
    event.metaKey ||
    event.ctrlKey ||
    event.altKey ||
    (target instanceof HTMLElement &&
      (target.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(target.tagName)))
  ) {
    return
  }
  const open = shortcutOpeners.values().next().value
  if (!open) return
  event.preventDefault()
  open()
}

function registerShortcut(open: () => void) {
  shortcutOpeners.add(open)
  if (!shortcutListening) {
    window.addEventListener("keydown", onSlash)
    shortcutListening = true
  }
  return () => {
    shortcutOpeners.delete(open)
    if (shortcutOpeners.size === 0 && shortcutListening) {
      window.removeEventListener("keydown", onSlash)
      shortcutListening = false
    }
  }
}

function IntentLoadedSearch({ iconOnly = false, tone = "nav" }: { iconOnly?: boolean; tone?: "nav" | "brand" }) {
  const [requested, setRequested] = useState(false)
  const [Loaded, setLoaded] = useState<SearchComponent | null>(null)
  const request = () => setRequested(true)

  useEffect(() => {
    if (requested) return
    return registerShortcut(request)
  }, [requested])

  useEffect(() => {
    if (!requested) return
    let active = true
    void loadSearchCommand().then((Component) => {
      if (active) setLoaded(() => Component)
    })
    return () => {
      active = false
    }
  }, [requested])

  if (Loaded) return <Loaded iconOnly={iconOnly} tone={tone} initialOpen />
  return <SearchTrigger iconOnly={iconOnly} tone={tone} onIntent={() => void loadSearchCommand()} onClick={request} />
}

export function LazySearchCommand() {
  return <IntentLoadedSearch />
}

export function LazySearchCommandIconOnly({ tone = "nav" }: { tone?: "nav" | "brand" } = {}) {
  return <IntentLoadedSearch iconOnly tone={tone} />
}
