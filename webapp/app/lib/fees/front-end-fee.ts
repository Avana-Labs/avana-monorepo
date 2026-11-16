import {
  DEFAULT_FEE_RULES,
  FEE_ACTIONS,
  LP_VALUE_ACTIONS,
  quoteFee,
  type FeeAction,
  type FeeRules,
} from "@/convex/lib/fees"

/**
 * The Avana front-end fee (Q-409): 10 bps by default of every action the app builds, from the rules
 * in Convex `frontendFee.getConfig`. The amount always comes from `quoteFee` in
 * services/convex/convex/lib/fees.ts, the one function that also sizes the fee transfer the app
 * adds to the action's batch, so the fee shown is the fee sent. Not an app action, so no fee: the
 * faucet's setup steps and keeper liquidations.
 */

export type { FeeAction, FeeRules } from "@/convex/lib/fees"

let currentRules: FeeRules = DEFAULT_FEE_RULES
const listeners = new Set<() => void>()

/** The fee rules in force: Convex `frontendFee.getConfig` once it has loaded, the defaults before. */
export function frontendFeeRules(): FeeRules {
  return currentRules
}

export function setFrontendFeeRules(rules: FeeRules) {
  if (rules === currentRules) return
  currentRules = rules
  for (const listener of listeners) listener()
}

export function subscribeFrontendFeeRules(listener: () => void) {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

export function isFeeAction(action: string): action is FeeAction {
  return (FEE_ACTIONS as readonly string[]).includes(action)
}

/** The rate of an action in bps; 0 for anything that is not a Q-409 action (claim, for example). */
export function frontendFeeBps(action: string, rules: FeeRules = currentRules): number {
  if (!isFeeAction(action)) return 0
  const quote = quoteFee(rules, {
    action,
    basis: LP_VALUE_ACTIONS.has(action)
      ? { kind: "lpValue", valueUsd8: 0n, decimals: 6, priceUsd8: 100_000_000n }
      : { kind: "amount", amount: 0n, decimals: 6, priceUsd8: 100_000_000n },
    gas: NO_GAS,
  })
  return quote.feeBps
}

const NO_GAS = { gasUnits: 0n, baseFeeWei: 0n, priorityFeeWei: 0n, l1FeeWei: 0n, nativeUsd8: 0n } as const

/**
 * The fee in USD on an action's USD amount, for the "Avana Platform Fee" row while an action's
 * token amounts are not wired yet: the amount as 6-decimal USD at a price of 1, through the same
 * `quoteFee` (rounded down). 0 for anything that is not a Q-409 action.
 */
export function frontendFeeUsd(action: string, amountUsd: number, rules: FeeRules = currentRules): number {
  if (!isFeeAction(action) || !Number.isFinite(amountUsd) || amountUsd <= 0) return 0
  const units = BigInt(Math.floor(amountUsd * 1e6))
  const quote = quoteFee(rules, {
    action,
    basis: LP_VALUE_ACTIONS.has(action)
      ? { kind: "lpValue", valueUsd8: units * 100n, decimals: 6, priceUsd8: 100_000_000n }
      : { kind: "amount", amount: units, decimals: 6, priceUsd8: 100_000_000n },
    gas: NO_GAS,
  })
  return Number(quote.feeAmount) / 1e6
}

/**
 * The fee in token units on an action's token amount, through `quoteFee` (rounded down). With no
 * price the USD cap does not apply. 0 for anything that is not a Q-409 action.
 */
export function frontendFeeAmount(
  action: string,
  amount: bigint,
  decimals: number,
  rules: FeeRules = currentRules,
  priceUsd8 = 0n,
): bigint {
  if (!isFeeAction(action) || LP_VALUE_ACTIONS.has(action) || amount <= 0n) return 0n
  return quoteFee(rules, { action, basis: { kind: "amount", amount, decimals, priceUsd8 }, gas: NO_GAS }).feeAmount
}

/** Languages whose fee sentence writes the decimal with a comma ("0,10 %"). */
const COMMA_DECIMAL_LANGUAGES = new Set(["DE", "FR", "ID", "NL", "PT", "RU", "TR"])

/** Fills `{bps}` and `{pct}` of the fee sentence: 10 and 0.10 (or 0,10). */
export function fillFeeRate(text: string, bps: number, language = "EN"): string {
  const pct = (bps / 100).toFixed(2)
  return text
    .replace("{bps}", String(bps))
    .replace("{pct}", COMMA_DECIMAL_LANGUAGES.has(language.toUpperCase()) ? pct.replace(".", ",") : pct)
}

/** The Q-409 action of an action page kind; claim (collecting LP fees) is none and pays no fee. */
export function feeActionForKind(kind: string): FeeAction | null {
  switch (kind) {
    case "borrow":
      return "borrow"
    case "repay":
      return "repay"
    case "supply":
    case "pledge":
      return "pledge"
    case "remove":
      return "withdrawCollateral"
    case "deposit":
      return "supply"
    case "withdraw":
      return "withdraw"
    default:
      return null
  }
}

/** The rate the fee tooltip states: the default rate, 0 when the fee is off. */
export function statedFeeBps(rules: FeeRules = currentRules): number {
  return rules.enabled ? rules.defaultBps : 0
}
