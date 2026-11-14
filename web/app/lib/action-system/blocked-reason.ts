// Credit-engine failures are raw internal errors (they embed the wallet id, the
// "spoke" id, and the word "insolvent"). Those must never reach end users — map
// the known ones to plain-language copy and scrub anything unmapped that still
// leaks an identifier or internal term.

const GENERIC_BLOCKED_MESSAGE = "This action can't be completed right now. Try a smaller amount or a different market."

type ReasonRule = { match: RegExp; message: string }

const REASON_RULES: ReasonRule[] = [
  // Backend error codes (convex/sandbox/auth.ts + transactions.ts) are thrown with an
  // uppercase CODE: prefix and must never reach users verbatim.
  {
    match: /\bUNAUTHENTICATED\b/i,
    message: "Your session has expired. Reconnect your wallet and sign in to continue.",
  },
  {
    match: /\bWALLET_MISMATCH\b/i,
    message: "This action doesn't match your connected wallet. Reconnect the right wallet and try again.",
  },
  { match: /\bRATE_LIMITED\b/i, message: "You're doing that a bit too fast. Wait a moment and try again." },
  {
    match: /does not have enough available credit/i,
    message: "You don't have enough borrowing power for this amount. Lower the amount or add collateral.",
  },
  {
    match: /has no collateral/i,
    message: "You have no collateral in this market yet. Supply collateral before borrowing.",
  },
  {
    match: /borrowing would make .* insolvent/i,
    message: "This borrow is more than this market can safely support. Try a smaller amount.",
  },
  {
    match: /removing collateral would make wallet .* insolvent/i,
    message: "Removing this much collateral would put your position at risk. Lower the amount.",
  },
  {
    match: /removing collateral would make .* insolvent/i,
    message: "This removal is more than this market can safely support. Try a smaller amount.",
  },
  { match: /has insufficient balance to repay/i, message: "You don't have enough balance to repay this amount." },
  { match: /insufficient lp balance/i, message: "You don't have enough LP in your wallet for this deposit." },
  {
    match: /does not have enough liquidity/i,
    message: "There isn't enough liquidity for this amount right now. Try a smaller amount.",
  },
  { match: /amount must be positive/i, message: "Enter an amount greater than zero." },
  {
    match: /\bINSUFFICIENT_COLLATERAL_BALANCE\b/,
    message: "You're pledging more LP than you hold in this pool. Lower the amount.",
  },
  { match: /\bINSUFFICIENT_BALANCE\b/, message: "You don't have enough balance for this amount. Lower the amount." },
  {
    match: /\b(STALE_WRITE|REVISION_REQUIRED)\b/,
    message: "This position changed in another tab. Reload the page and try again.",
  },
  {
    match: /\bINVALID_TRANSITION\b/,
    message: "Your balance changed before this could be confirmed. Reload the page and try again.",
  },
  // A Convex failure with no code: "[CONVEX M(module:fn)] [Request ID: …] Server Error".
  {
    match: /\[CONVEX [QMA]\(|\bServer Error\b|\bRequest ID\b/,
    message: "Something went wrong on our side and nothing was changed. Try again in a moment.",
  },
]

// Anything that still exposes an internal identifier: a hex wallet address, the
// literal "spoke" internal grouping term, the raw "Wallet <id>" prefix, or the
// jargon "insolvent".
const LEAKS_INTERNAL = /(0x[a-f0-9]{6,})|\bspoke\b|\binsolvent\b|\bwallet\s+[\w-]+/i

// A raw backend error code prefix, e.g. "RATE_LIMITED: ..." or "INVALID_TRANSITION: ...".
// Any unmapped one still leaks an internal code, so it's scrubbed to the generic copy.
const RAW_CODE_PREFIX = /^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+\s*:/

/** Turn a raw credit-engine / backend error into safe, user-facing copy. */
export function humanizeBlockedReason(reason: string | null | undefined): string | null {
  if (!reason) return reason ?? null
  for (const rule of REASON_RULES) {
    if (rule.match.test(reason)) return rule.message
  }
  if (LEAKS_INTERNAL.test(reason) || RAW_CODE_PREFIX.test(reason.trim())) return GENERIC_BLOCKED_MESSAGE
  return reason
}

/**
 * User-facing copy for an error thrown by a submit. Reads the ConvexError payload
 * (`error.data`, which carries the backend code) before the message, which for a
 * Convex failure is the raw "[CONVEX M(...)] Server Error" string.
 */
export function actionErrorMessage(error: unknown, fallback: string): string {
  const data = (error as { data?: unknown } | null | undefined)?.data
  const payload =
    data && typeof data === "object"
      ? [(data as { code?: unknown }).code, (data as { message?: unknown }).message]
          .filter((part): part is string => typeof part === "string")
          .join(": ")
      : typeof data === "string"
        ? data
        : ""
  const raw = payload || (error instanceof Error ? error.message : "")
  return (raw && humanizeBlockedReason(raw)) || fallback
}
