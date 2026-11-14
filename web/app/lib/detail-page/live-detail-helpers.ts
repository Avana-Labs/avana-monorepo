import { formatTokenPrice } from "@/app/lib/prices/format"
import { sandboxBaselinePriceUsd } from "@/app/lib/prices/sandbox-baseline-prices"

type DetailQuickStat = {
  id: string
  value: string
  delta?: unknown
}

/**
 * Pin the "Price" quick stat to the sandbox baseline — the SAME price that values this token
 * everywhere else. Overlaying the live oracle here instead makes the tile disagree with the
 * valuation sitting next to it.
 */
export function injectBaselinePrice<T extends DetailQuickStat>(quickStats: T[], baseSymbol: string): T[] {
  const value = formatTokenPrice(sandboxBaselinePriceUsd(baseSymbol))
  return quickStats.map((stat) => (stat.id === "price" ? { ...stat, value } : stat))
}

export function mergeAliasedQuickStats<T extends DetailQuickStat>(
  base: T[],
  convex: ReadonlyArray<{ id: string; value: string; delta?: T["delta"] }> | null,
  aliases: Record<string, string[]>,
): T[] {
  if (!convex || convex.length === 0) return base
  const byMockId = new Map<string, { value: string; delta?: T["delta"] }>()
  for (const item of convex) {
    for (const mockId of aliases[item.id] ?? [item.id]) byMockId.set(mockId, item)
  }
  return base.map((stat) => {
    const next = byMockId.get(stat.id)
    return next ? { ...stat, value: next.value, delta: next.delta ?? stat.delta } : stat
  })
}

type ChangelogEntry = {
  id: string
  parameter: string
  previous: string
  current: string
  date: string
  source: string
  executor: string
  category?: string
  href?: string
}

type GovernanceParameters = {
  parameters: Array<{ id: string; label: string; value: string; status?: string; description?: string; href?: string }>
  changelog: ChangelogEntry[]
}

type AboutContent = {
  description: string
  stats: Array<{ label: string; value: string; href?: string }>
  history: Array<{ date: string; title: string; description?: string }>
  governanceParameters?: GovernanceParameters
}

type FaqEntry = { question: string; answer: string }

/** Convex editorial content shape (`getContent`): About fields + FAQs + the rich changelog. */
type DetailContentOverlay = {
  description: string
  stats: AboutContent["stats"]
  history: AboutContent["history"]
  faqs: FaqEntry[]
  changelog?: ChangelogEntry[]
}

type DetailWithContent = {
  about: AboutContent
  faqs: FaqEntry[]
}

type DetailContentOverlayOptions = {
  /**
   * Live mode: when Convex content is missing, clear catalog About/FAQs/history
   * instead of silently re-pinning mock editorial. Mock/open-gate leaves base intact.
   */
  clearWhenMissing?: boolean
}

/** Prefer Convex editorial content (About + FAQs); keep any base-only about fields. */
export function applyDetailContentOverlay<T extends DetailWithContent>(
  detail: T,
  content: DetailContentOverlay | null | undefined,
  options: DetailContentOverlayOptions = {},
): T {
  if (!content) {
    if (!options.clearWhenMissing) return detail
    return {
      ...detail,
      about: {
        ...detail.about,
        description: "",
        stats: [],
        history: [],
        governanceParameters: detail.about.governanceParameters
          ? { ...detail.about.governanceParameters, changelog: [] }
          : detail.about.governanceParameters,
      },
      faqs: [],
    } as T
  }
  const changelog = content.changelog
  return {
    ...detail,
    about: {
      ...detail.about,
      description: content.description,
      stats: content.stats,
      history: content.history,
      // Prefer the Convex-seeded governance changelog when present; keep any base
      // parameters (applyRiskParametersToAbout, which runs after, refreshes them).
      governanceParameters:
        changelog && changelog.length > 0
          ? { parameters: detail.about.governanceParameters?.parameters ?? [], changelog }
          : detail.about.governanceParameters,
    },
    faqs: content.faqs,
  } as T
}
