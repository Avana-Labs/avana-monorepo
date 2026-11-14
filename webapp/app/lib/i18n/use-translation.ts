"use client"

import { useCallback, useEffect, useSyncExternalStore } from "react"
import { useOptionalLocaleDisplayPreferences, type LanguageCode } from "@/app/components/display-preferences"
import { translateWith } from "@/app/lib/i18n/translate-core"
import type { TranslationDictionary } from "@/app/lib/i18n/types"

/**
 * Per-locale lazy loading. Each language is its own chunk (see ./locales/*), so a
 * viewer downloads ONLY their active language (~1/13th of the old ~1MB monolith).
 * English is the source language (t(key) === key), so it ships zero locale data.
 * Until a non-English chunk lands, keys fall back to their English source — exactly
 * what the app already does for any untranslated string — and when it lands every
 * mounted useTranslation re-renders and swaps in the real translation. SSR renders
 * English, the client hydrates English, then upgrades: no mismatch.
 */
const LOADERS: Partial<Record<LanguageCode, () => Promise<{ default: TranslationDictionary }>>> = {
  ZH: () => import("@/app/lib/i18n/locales/zh"),
  ES: () => import("@/app/lib/i18n/locales/es"),
  AR: () => import("@/app/lib/i18n/locales/ar"),
  DE: () => import("@/app/lib/i18n/locales/de"),
  HI: () => import("@/app/lib/i18n/locales/hi"),
  TR: () => import("@/app/lib/i18n/locales/tr"),
  NL: () => import("@/app/lib/i18n/locales/nl"),
  FR: () => import("@/app/lib/i18n/locales/fr"),
  ID: () => import("@/app/lib/i18n/locales/id"),
  JA: () => import("@/app/lib/i18n/locales/ja"),
  KO: () => import("@/app/lib/i18n/locales/ko"),
  PT: () => import("@/app/lib/i18n/locales/pt"),
  RU: () => import("@/app/lib/i18n/locales/ru"),
}

const loaded: Partial<Record<LanguageCode, TranslationDictionary>> = {}
const loading = new Set<LanguageCode>()
let version = 0
const listeners = new Set<() => void>()

function ensureLocaleLoaded(language: LanguageCode) {
  if (language === "EN" || loaded[language] || loading.has(language)) return
  const loader = LOADERS[language]
  if (!loader) return
  loading.add(language)
  loader()
    .then((mod) => {
      loaded[language] = mod.default
      version += 1
      listeners.forEach((notify) => notify())
    })
    .catch(() => {
      // Keep the English fallback and allow a later retry rather than hard-failing the UI.
      loading.delete(language)
    })
}

function subscribe(notify: () => void) {
  listeners.add(notify)
  return () => {
    listeners.delete(notify)
  }
}

/**
 * Returns a `t(englishString)` translator bound to the user's selected language (from the header
 * switcher). English renders synchronously with no locale download; other languages fall back to
 * English until their dictionary chunk loads, then re-render translated.
 */
export function useTranslation() {
  const preferences = useOptionalLocaleDisplayPreferences()
  const language = preferences?.language ?? "EN"
  // Re-render when the active locale's chunk lands (module-level version bump).
  const loadedVersion = useSyncExternalStore(
    subscribe,
    () => version,
    () => 0,
  )
  useEffect(() => {
    ensureLocaleLoaded(language)
  }, [language])
  const t = useCallback(
    (key: string) => (language === "EN" ? key : translateWith(loaded[language], key)),
    [language, loadedVersion],
  )
  return { t, language }
}
