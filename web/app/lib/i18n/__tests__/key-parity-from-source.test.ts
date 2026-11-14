import { describe, expect, it } from "vitest"
import { translate, TRANSLATIONS } from "@/app/lib/i18n/translations"
import { extractTranslationKeys } from "./extract-t-keys"
import { KNOWN_UNTRANSLATED } from "./known-untranslated"

/**
 * Code-derived key-parity guard.
 *
 * Sibling suites (translation-completeness, umbrella-completeness) check the
 * locale dictionaries against each other or against a hand-curated list. None of
 * them close the real hole: a `t("…")` literal that lives in the SOURCE but is
 * absent from the locale dicts renders the English fallback forever, and no test
 * notices. This suite extracts every literal `t("…")` key straight from app/ +
 * components/ and asserts each one resolves (i.e. produces non-English output) in
 * all 13 non-English locales — with a shrink-only KNOWN_UNTRANSLATED allowlist
 * for the keys still awaiting the translation backfill (waves B2–B6).
 *
 * "Resolves" mirrors runtime exactly: a locale shows the English fallback for a
 * key `k` iff `translate(lang, k) === k`. This folds in the generated-copy
 * fallbacks ("{verb} successful", "{amount} processed.") the same way the app
 * does, so composed keys are not falsely flagged.
 */

const NON_EN = Object.keys(TRANSLATIONS).filter((lang) => lang !== "EN") as Array<keyof typeof TRANSLATIONS>

/** Locales in which `key` still renders the English source (the fallback). */
function unresolvedLocales(key: string): string[] {
  return NON_EN.filter((lang) => translate(lang, key) === key)
}

const { keys: CODE_KEYS, dynamicCallCount } = extractTranslationKeys()
const codeKeySet = new Set(CODE_KEYS)
const allowlist = new Set(KNOWN_UNTRANSLATED)

describe("key parity from source", () => {
  it("extracts a non-trivial set of literal keys (extractor sanity)", () => {
    // Guards against the extractor silently returning nothing (e.g. a moved dir
    // or a broken scan), which would make every assertion below vacuously pass.
    expect(CODE_KEYS.length).toBeGreaterThan(400)
    // Purely dynamic `t(variable)` calls carry no literal and cannot be asserted
    // on; they are excluded by design. Recorded here so the split is visible.
    expect(dynamicCallCount).toBeGreaterThan(0)
  })

  it("every non-allowlisted code key resolves in all 13 locales", () => {
    // (c) + (e): any code key NOT explicitly allowlisted must be translated in
    // every locale. A brand-new `t("…")` key that isn't translated everywhere
    // fails here until it is translated OR consciously added to the allowlist.
    const offenders: string[] = []
    for (const key of CODE_KEYS) {
      if (allowlist.has(key)) continue
      const missing = unresolvedLocales(key)
      if (missing.length > 0) {
        offenders.push(`"${key}" → English fallback in ${missing.join(", ")}`)
      }
    }
    expect(
      offenders,
      `Code keys missing a translation (translate & add to all locales, or add to KNOWN_UNTRANSLATED):\n${offenders.join("\n")}`,
    ).toEqual([])
  })

  it("allowlist contains no stale entries (shrink-only)", () => {
    // (d): an allowlist entry earns its place only while it is still an English
    // fallback somewhere. Two stale classes fail here so the list can only shrink:
    //   1. Fully translated now — must be DELETED so parity starts enforcing it.
    //   2. No longer referenced in code AND already fully translated — dead weight.
    const stale: string[] = []
    for (const key of KNOWN_UNTRANSLATED) {
      const missing = unresolvedLocales(key)
      if (missing.length === 0) {
        stale.push(
          codeKeySet.has(key)
            ? `"${key}" is now translated in all locales — remove it from KNOWN_UNTRANSLATED`
            : `"${key}" is fully translated and no longer used in code — remove it from KNOWN_UNTRANSLATED`,
        )
      }
    }
    expect(stale, `Stale allowlist entries:\n${stale.join("\n")}`).toEqual([])
  })

  it("allowlist has no duplicate entries", () => {
    const seen = new Set<string>()
    const dups: string[] = []
    for (const key of KNOWN_UNTRANSLATED) {
      if (seen.has(key)) dups.push(key)
      seen.add(key)
    }
    expect(dups, `Duplicate allowlist entries:\n${dups.join("\n")}`).toEqual([])
  })
})
