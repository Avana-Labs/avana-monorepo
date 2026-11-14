import type { LanguageCode } from "@/app/components/display-preferences"

/**
 * Language code → BCP-47 tag for the document `lang` attribute and Intl formatting.
 * Must stay out of translations.ts: importing that drags ~288KB of locale dictionaries
 * into the caller's bundle instead of loading them lazily.
 */
export const LANGUAGE_HTML_LANG: Record<LanguageCode, string> = {
  EN: "en",
  ZH: "zh-Hans",
  ES: "es",
  AR: "ar",
  DE: "de",
  HI: "hi",
  TR: "tr",
  NL: "nl",
  FR: "fr",
  ID: "id",
  JA: "ja",
  KO: "ko",
  PT: "pt",
  RU: "ru",
}

/** `display-preferences` mirrors this into `document.documentElement.dir`. */
const RTL_LANGUAGES: ReadonlySet<LanguageCode> = new Set(["AR"])

export function isRtlLanguage(language: LanguageCode): boolean {
  return RTL_LANGUAGES.has(language)
}
