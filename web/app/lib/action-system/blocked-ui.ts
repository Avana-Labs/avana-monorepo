type BlockedCta = {
  /** Short, button-sized label describing why the action can't proceed. */
  label: string
}

/**
 * Map a block reason (raw engine text or a `humanizeBlockedReason` string) to a short
 * primary-button label. The gate lives on the CTA itself, not a dialog.
 *
 * `symbol` is the asset the action spends, used for balance messages.
 */
export function blockedCtaLabel(reason: string, options?: { symbol?: string }): BlockedCta {
  const r = reason.toLowerCase()
  const symbol = options?.symbol?.trim()

  if (r.includes("no collateral") || (r.includes("deposit") && (r.includes("before") || r.includes("collateral")))) {
    return { label: "No collateral" }
  }
  if (r.includes("no open position") || r.includes("no position to") || r.includes("no position selected")) {
    return { label: "No position" }
  }

  if (r.includes("borrowing unavailable") || (r.includes("borrow") && r.includes("unavailable"))) {
    return { label: "Borrowing unavailable" }
  }
  if (r.includes("liquidity")) return { label: "Insufficient liquidity" }
  if (/\blp\b/.test(r)) return { label: "Insufficient LP" }
  if (r.includes("balance") && (r.includes("insufficient") || r.includes("enough") || r.includes("exceed"))) {
    // Return a translation key with a {symbol} placeholder (interpolated at render)
    // so the label localizes — token tickers themselves are never translated.
    return { label: symbol ? "Insufficient {symbol}" : "Insufficient balance" }
  }
  if (
    r.includes("borrowing power") ||
    r.includes("available credit") ||
    r.includes("safely support") ||
    r.includes("at risk") ||
    r.includes("liquidation") ||
    r.includes("insolvent")
  ) {
    return { label: "Try a smaller amount" }
  }
  if (r.includes("withdrawal window expired")) return { label: "Window expired" }
  if (r.includes("cooldown is not ready")) return { label: "Cooldown not ready" }
  if (r.includes("finish or unstake the current cooldown")) return { label: "Cooldown active" }
  if (r.includes("supply cap")) return { label: "Supply cap reached" }
  if (r.includes("paused")) return { label: "Market paused" }
  if (r.includes("price")) return { label: "Price unavailable" }
  if (r.includes("not supported") || r.includes("unavailable") || r.includes("disabled")) {
    return { label: "Not available here" }
  }
  if (r.includes("nothing to claim")) return { label: "Nothing to claim" }
  if (r.includes("select rewards")) return { label: "Select rewards" }
  if (r.includes("no deposited position") || r.includes("position does not exist")) {
    return { label: "Nothing to withdraw" }
  }
  if (r.includes("nothing to repay") || r.includes("no debt")) return { label: "Nothing to repay" }
  if (r.includes("nothing to remove")) return { label: "Nothing to remove" }
  if (r.includes("nothing to withdraw")) return { label: "Nothing to withdraw" }
  if (r.includes("positive") || r.includes("greater than zero")) return { label: "Enter an amount" }

  // Non-alarming catch-all — most remaining blocks are "amount is too big".
  return { label: "Try a smaller amount" }
}
