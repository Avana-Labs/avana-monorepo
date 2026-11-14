// Relevance ranking for the global search dialog.
// Higher score = more relevant. Results are sorted so that exact/prefix/word
// matches on the title come before token-contains matches, which in turn come
// before generic substring (fuzzy) matches on the keywords/subtitle blob.

type RankableResult = {
  title: string
  subtitle: string
  eyebrow: string
  keywords: string
}

const scoreField = (field: string, query: string): number => {
  const value = field.toLowerCase()
  if (!value.includes(query)) return 0
  if (value === query) return 100
  if (value.startsWith(query)) return 60
  // Whole-word / token boundary match (e.g. "usdc" inside "eth usdc pool").
  if (new RegExp(`\\b${escapeRegExp(query)}`, "i").test(value)) return 40
  return 15
}

const escapeRegExp = (value: string) => value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")

export function scoreResult(result: RankableResult, normalizedQuery: string): number {
  const query = normalizedQuery.trim().toLowerCase()
  if (!query) return 0

  // Title matches dominate; then eyebrow/subtitle; then the keyword blob (fuzzy).
  return (
    scoreField(result.title, query) * 4 +
    scoreField(result.eyebrow, query) * 2 +
    scoreField(result.subtitle, query) * 2 +
    scoreField(result.keywords, query)
  )
}

// Filter to matching results and sort most-relevant first (stable for ties).
export function rankResults<T extends RankableResult>(results: readonly T[], rawQuery: string): T[] {
  const query = rawQuery.trim().toLowerCase()
  if (!query) return [...results]

  return results
    .map((result, index) => ({ result, index, score: scoreResult(result, query) }))
    .filter((entry) => entry.score > 0)
    .sort((a, b) => b.score - a.score || a.index - b.index)
    .map((entry) => entry.result)
}
