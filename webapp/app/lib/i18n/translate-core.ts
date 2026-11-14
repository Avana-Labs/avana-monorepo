import type { TranslationDictionary } from "./types"

/**
 * Look up `key` in a single already-loaded locale dictionary. Mirrors the old
 * monolithic `translate()`: exact hit wins, then generated-copy fallbacks compose
 * from their parts so sinks that build a sentence around a runtime value (a verb,
 * an amount, a formatted balance) localize without a dedicated key per value.
 *
 * `dict` is the merged dictionary for one language (or undefined before it has
 * loaded / for English), in which case keys fall back to their English source.
 */
export function translateWith(dict: TranslationDictionary | undefined, key: string): string {
  const exact = dict?.[key]
  if (exact) return exact

  const successfulMatch = key.match(/^(.+) successful$/)
  if (successfulMatch) {
    return `${translateWith(dict, successfulMatch[1])} ${translateWith(dict, "successful")}`
  }

  if (key.endsWith(" processed.")) {
    return `${key.slice(0, -" processed.".length)} ${translateWith(dict, "processed")}.`
  }

  const fundWalletMatch = key.match(/^(.+) Fund your wallet or switch accounts to continue\.$/)
  if (fundWalletMatch) {
    return `${translateWith(dict, fundWalletMatch[1])} ${translateWith(dict, "Fund your wallet or switch accounts to continue.")}`
  }

  const overBalanceMatch = key.match(/^Amount exceeds your available balance\. Max (.+)\.$/)
  if (overBalanceMatch) {
    return translateWith(dict, "Amount exceeds your available balance. Max {amount}.").replace(
      "{amount}",
      overBalanceMatch[1]!,
    )
  }

  const overDebtMatch = key.match(/^Amount exceeds outstanding debt\. Maximum repay is (.+)\.$/)
  if (overDebtMatch) {
    return translateWith(dict, "Amount exceeds outstanding debt. Maximum repay is {amount}.").replace(
      "{amount}",
      overDebtMatch[1]!,
    )
  }

  return key
}
