import {
  CURRENCY_OPTIONS,
  LANGUAGE_OPTIONS,
  type CurrencyCode,
  type LanguageCode,
} from "@/app/components/display-preferences"
import type { Theme } from "@/app/components/theme-provider"

/** Display preferences mirrored between local UI state and Convex wallet profiles. */
export type StoredPreferences = {
  theme?: Theme
  language?: LanguageCode
  currency?: CurrencyCode
  showDollarAmounts?: boolean
}

export type LocalPreferenceState = {
  theme: Theme
  language: LanguageCode
  currency: CurrencyCode
  showDollarAmounts: boolean
}

export type PreferenceSetters = {
  setTheme: (theme: Theme) => void
  setLanguage: (language: LanguageCode) => void
  setCurrency: (currency: CurrencyCode) => void
  setShowDollarAmounts: (value: boolean) => void
}

function isTheme(value: string | undefined): value is Theme {
  return value === "light" || value === "dark" || value === "system"
}

function isLanguage(value: string | undefined): value is LanguageCode {
  return LANGUAGE_OPTIONS.some((option) => option.code === value)
}

function isCurrency(value: string | undefined): value is CurrencyCode {
  return CURRENCY_OPTIONS.some((option) => option.code === value)
}

/** Drop unknown / malformed fields from a Convex (or local) preferences blob. */
export function normalizePreferences(preferences: StoredPreferences | null | undefined): StoredPreferences | null {
  if (!preferences) return null
  const normalized: StoredPreferences = {}
  if (isTheme(preferences.theme)) normalized.theme = preferences.theme
  if (isLanguage(preferences.language)) normalized.language = preferences.language
  if (isCurrency(preferences.currency)) normalized.currency = preferences.currency
  if (typeof preferences.showDollarAmounts === "boolean") {
    normalized.showDollarAmounts = preferences.showDollarAmounts
  }
  return Object.keys(normalized).length > 0 ? normalized : null
}

/** Stable identity string for echo / no-op detection across pull and push. */
export function serializePreferences(preferences: StoredPreferences): string {
  return JSON.stringify({
    theme: preferences.theme ?? null,
    language: preferences.language ?? null,
    currency: preferences.currency ?? null,
    showDollarAmounts: preferences.showDollarAmounts ?? null,
  })
}

export function snapshotLocalPreferences(local: LocalPreferenceState): StoredPreferences {
  return {
    theme: local.theme,
    language: local.language,
    currency: local.currency,
    showDollarAmounts: local.showDollarAmounts,
  }
}

/**
 * Apply remote fields that differ from local UI state.
 * Returns true when at least one setter was called.
 */
export function applyRemotePreferences(
  remote: StoredPreferences,
  local: LocalPreferenceState,
  setters: PreferenceSetters,
): boolean {
  let changed = false
  if (remote.theme && remote.theme !== local.theme) {
    setters.setTheme(remote.theme)
    changed = true
  }
  if (remote.language && remote.language !== local.language) {
    setters.setLanguage(remote.language)
    changed = true
  }
  if (remote.currency && remote.currency !== local.currency) {
    setters.setCurrency(remote.currency)
    changed = true
  }
  if (typeof remote.showDollarAmounts === "boolean" && remote.showDollarAmounts !== local.showDollarAmounts) {
    setters.setShowDollarAmounts(remote.showDollarAmounts)
    changed = true
  }
  return changed
}
