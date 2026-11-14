import type { LanguageCode } from "@/app/components/display-preferences"
import type { TranslationDictionary } from "./types"
import { translateWith } from "./translate-core"
import ZH from "./locales/zh"
import ES from "./locales/es"
import AR from "./locales/ar"
import DE from "./locales/de"
import HI from "./locales/hi"
import TR from "./locales/tr"
import NL from "./locales/nl"
import FR from "./locales/fr"
import ID from "./locales/id"
import JA from "./locales/ja"
import KO from "./locales/ko"
import PT from "./locales/pt"
import RU from "./locales/ru"

export type { TranslationDictionary } from "./types"

/**
 * Aggregate of every locale dictionary. This module statically pulls in ALL locales,
 * so it is intended for tests and non-client callers only. The app itself localizes
 * through the per-locale lazy loader in `use-translation.ts`, which downloads just the
 * viewer's active language — nothing in the client bundle imports this file.
 */
export const TRANSLATIONS: Partial<Record<LanguageCode, TranslationDictionary>> = {
  EN: {},
  ZH,
  ES,
  AR,
  DE,
  HI,
  TR,
  NL,
  FR,
  ID,
  JA,
  KO,
  PT,
  RU,
}

/** Synchronous, all-locales translator. Behaviour matches the per-locale
 *  `translateWith` used at runtime (exact hit, then the successful/processed sinks). */
export function translate(language: LanguageCode, key: string): string {
  if (language === "EN") return key
  return translateWith(TRANSLATIONS[language], key)
}
