// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
/**
 * When Ask AI shows the portfolio table under an answer.
 *
 * Reading the portfolio is how the assistant answers almost any "my" question, so attaching the
 * table to every such answer buried short answers under a card nobody asked for. The table is a
 * way to SEE holdings, so it appears only when the question asks to see them: a list, breakdown,
 * overview, table, or "show / what's in my portfolio". Everything else ("what is my net value",
 * "how much do I have in Lend") is answered in the text alone.
 */

const SHOW_HOLDINGS =
  /\b(?:show|list|display|see|view)\b[^.?!]{0,40}\b(?:portfolio|positions?|holdings?|balances?|everything|all)\b/i
const BREAKDOWN = /\b(?:breakdown|break\s+(?:it\s+)?down|overview|table|itemi[sz]e|per[-\s]product|by\s+product)\b/i
const WHATS_IN =
  /\bwhat(?:'s|\s+is|\s+are)?\s+(?:in\s+my\s+(?:portfolio|wallet|account)|my\s+(?:positions|holdings))\b/i
const WHAT_DO_I_HOLD = /\bwhat\s+do\s+i\s+(?:hold|own|have)\b/i
const ALL_POSITIONS = /\ball\s+(?:of\s+)?my\s+(?:positions|holdings|assets|balances)\b/i
const UMBRELLA = /\bumbrella\b/i

export type PortfolioCardDecision = {
  show: boolean
  /** Umbrella rows (with their Cooldown / Status columns) only when Umbrella is in the question. */
  includeUmbrella: boolean
}

export function portfolioCardFor(question: string | undefined): PortfolioCardDecision {
  const text = (question ?? "").trim()
  if (!text) return { show: false, includeUmbrella: false }
  const show =
    SHOW_HOLDINGS.test(text) ||
    BREAKDOWN.test(text) ||
    WHATS_IN.test(text) ||
    WHAT_DO_I_HOLD.test(text) ||
    ALL_POSITIONS.test(text)
  return { show, includeUmbrella: show && (UMBRELLA.test(text) || ALL_POSITIONS.test(text)) }
}
