/**
 * Shared i18n type. Kept in its own module so per-locale dictionaries and the
 * translate core can import it without pulling in the (test-only) aggregate
 * `translations.ts` or creating an import cycle.
 */
export type TranslationDictionary = Partial<Record<string, string>>
