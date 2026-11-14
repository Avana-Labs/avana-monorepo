/** Resolve the projection horizon stated in a natural-language Ask AI prompt. */
export function projectionDaysFromPrompt(prompt: string): number {
  const explicit = /\b(?:next\s+)?(\d+)\s*[- ]?\s*(days?|weeks?|months?)\b/i.exec(prompt)
  if (explicit) {
    const amount = Number(explicit[1])
    const unit = explicit[2].toLowerCase()
    const days = unit.startsWith("week") ? amount * 7 : unit.startsWith("month") ? amount * 30 : amount
    return Math.min(Math.max(days, 1), 365)
  }
  if (/\b(?:a|one)\s+week\b|\bnext\s+week\b/i.test(prompt)) return 7
  if (/\b(?:a|one)\s+month\b|\bnext\s+month\b/i.test(prompt)) return 30
  return 365
}
