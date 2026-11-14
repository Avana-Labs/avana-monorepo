/**
 * Deterministic generator for a market's governance parameter changelog, built backward from
 * the market's CURRENT risk parameters: the newest entry for a parameter lands exactly on the
 * value shown in the Risk Parameters grid. Same slug in → same changelog out, so it seeds
 * Convex deterministically and keeps tests stable.
 */

import { SANDBOX_NOW } from "@/app/lib/deterministic"
import { hashString, prngFromString } from "@/app/lib/borrow-detail/prng"

export type ParameterChangeCategory = "Risk Management" | "Domain Admin" | "Listing" | "Emergency"

type ParameterChangeEntry = {
  id: string
  parameter: string
  previous: string
  current: string
  date: string
  source: string
  executor: string
  category: ParameterChangeCategory
  href?: string
}

/** One current risk parameter, taken from the market's Risk Parameters grid. */
export type ParameterAnchor = {
  id: string
  label: string
  value: string
}

export type ProductKind = "borrow-pool" | "borrow-asset" | "lend"

export type BuildParameterChangelogInput = {
  slug: string
  product: ProductKind
  /** The market's current risk parameters (the changelog's newest values anchor to these). */
  anchors: ParameterAnchor[]
  /** ISO date (YYYY-MM-DD) the market was listed; the oldest entry. */
  listedAt?: string
  /** Optional governance proposal link applied to every row. */
  proposalHref?: string
}

const MS_PER_DAY = 24 * 60 * 60 * 1000

// ── Value parsing / formatting ────────────────────────────────────────────────

type ValueKind = "pct" | "usd" | "num" | "mult"

/** True for a two-sided numeric range like "5.00% - 5.55%" (a unit may sit before the dash). */
function isRange(value: string): boolean {
  const dash = value.search(/[-–—]/)
  if (dash < 0) return false
  return /\d/.test(value.slice(0, dash)) && /\d/.test(value.slice(dash + 1))
}

/** Parse the leading number of a formatted value (handles ranges like "5.00% - 5.55%"). */
function parseLeadingNumber(value: string): number | null {
  const match = value.match(/(-?\d[\d,]*\.?\d*)/)
  if (!match) return null
  const n = Number(match[1]!.replace(/,/g, ""))
  return Number.isFinite(n) ? n : null
}

/** Parse a compact-USD string ("$211.0M", "$78K", "1.2B") into a number. */
function parseCompactUsd(value: string): number | null {
  const match = value.match(/\$?\s*(-?\d[\d,]*\.?\d*)\s*([KMBT])?/i)
  if (!match) return null
  const n = Number(match[1]!.replace(/,/g, ""))
  if (!Number.isFinite(n)) return null
  const suffix = (match[2] ?? "").toUpperCase()
  const scale = suffix === "T" ? 1e12 : suffix === "B" ? 1e9 : suffix === "M" ? 1e6 : suffix === "K" ? 1e3 : 1
  return n * scale
}

function formatCompactUsd(n: number): string {
  const abs = Math.abs(n)
  if (abs >= 1e12) return `$${trimZeros(n / 1e12)}T`
  if (abs >= 1e9) return `$${trimZeros(n / 1e9)}B`
  if (abs >= 1e6) return `$${trimZeros(n / 1e6)}M`
  if (abs >= 1e3) return `$${trimZeros(n / 1e3)}K`
  return `$${Math.round(n)}`
}

/** One decimal place, trailing ".0" trimmed. */
function trimZeros(n: number): string {
  return n.toFixed(1).replace(/\.0$/, "")
}

function formatPct(n: number): string {
  return `${n.toFixed(2)}%`
}

function formatValue(kind: ValueKind, n: number): string {
  switch (kind) {
    case "pct":
      return formatPct(n)
    case "usd":
      return formatCompactUsd(n)
    case "mult":
      return `${n
        .toFixed(2)
        .replace(/\.00$/, "")
        .replace(/(\.\d)0$/, "$1")}x`
    case "num":
      return n.toFixed(2)
  }
}

// ── Parameter classification ──────────────────────────────────────────────────

type TrackSpec = {
  kind: ValueKind
  category: ParameterChangeCategory
  /** Sign applied when walking BACKWARD in time (older value = current + backwardSign*step). */
  backwardSign: 1 | -1
  /** Per-step magnitude as a fraction of the current value (usd/mult) or absolute pp (pct/num). */
  step: number
  clampMin: number
  clampMax: number
  sources: string[]
  executors: string[]
}

function classify(anchor: ParameterAnchor): TrackSpec | null {
  const id = anchor.id.toLowerCase()
  const label = anchor.label.toLowerCase()
  const has = (needle: string) => id.includes(needle) || label.includes(needle)

  // Oracle / price source is text — handled as a synthetic Domain Admin track, not here.
  if (has("oracle") || has("price source")) return null

  if (has("cap") || has("capacity")) {
    return {
      kind: "usd",
      category: "Risk Management",
      backwardSign: -1, // caps grow over time → older caps are smaller
      step: 0.14,
      clampMin: 1e6,
      clampMax: 5e11,
      sources: ["Risk parameter review", "Quarterly risk review", "Capacity adjustment"],
      executors: ["Governance executor", "Risk steward multisig"],
    }
  }
  if (has("reserve factor") || has("interest fee") || has("liquidity fee")) {
    return {
      kind: "pct",
      category: "Domain Admin",
      backwardSign: -1, // reserve factor tends to rise over time
      step: 1,
      clampMin: 1,
      clampMax: 35,
      sources: ["Revenue parameter update", "Fee configuration update"],
      executors: ["Governance executor", "Risk steward multisig"],
    }
  }
  if (has("risk premium") || has("collateral risk")) {
    return {
      kind: "pct",
      category: "Risk Management",
      backwardSign: 1, // risk premia compress as a market seasons → older values higher
      step: 0.75,
      clampMin: 0.25,
      clampMax: 25,
      sources: ["Risk parameter review", "Market risk update"],
      executors: ["Risk steward multisig", "Governance executor"],
    }
  }
  if (has("health factor")) {
    return {
      kind: "num",
      category: "Risk Management",
      backwardSign: 1,
      step: 0.03,
      clampMin: 1.05,
      clampMax: 3,
      sources: ["Risk parameter review", "Liquidation parameter update"],
      executors: ["Risk steward multisig", "Governance executor"],
    }
  }
  if (has("leverage")) {
    return {
      kind: "mult",
      category: "Risk Management",
      backwardSign: -1, // max leverage raised over time
      step: 0.14,
      clampMin: 1.5,
      clampMax: 20,
      sources: ["Risk parameter review", "Leverage limit update"],
      executors: ["Risk steward multisig", "Governance executor"],
    }
  }
  if (has("penalty") || has("bonus")) {
    return {
      kind: "pct",
      category: "Risk Management",
      backwardSign: 1, // liquidation incentives trimmed over time
      step: 0.5,
      clampMin: 1,
      clampMax: 20,
      sources: ["Liquidation parameter update", "Risk parameter review"],
      executors: ["Risk steward multisig", "Governance executor"],
    }
  }
  if (has("factor") || has("threshold") || has("ltv")) {
    return {
      kind: "pct",
      category: "Risk Management",
      backwardSign: -1, // collateral factors / thresholds loosened as confidence grew
      step: 1.5,
      clampMin: 5,
      clampMax: 95,
      sources: ["Risk parameter review", "Quarterly risk review"],
      executors: ["Risk steward multisig", "Governance executor"],
    }
  }
  return null
}

function clamp(n: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, n))
}

/** Step a value one notch BACKWARD in time along its track. */
function stepBack(kind: ValueKind, spec: TrackSpec, value: number, rand: () => number): number {
  const wobble = 0.6 + rand() * 0.8 // 0.6..1.4 — vary the step so a chain is not perfectly uniform
  let next: number
  if (kind === "usd" || kind === "mult") {
    next = value * (1 + spec.backwardSign * spec.step * wobble)
  } else {
    next = value + spec.backwardSign * spec.step * wobble
  }
  return clamp(round(kind, next), spec.clampMin, spec.clampMax)
}

function round(kind: ValueKind, n: number): number {
  if (kind === "pct") return Math.round(n * 100) / 100
  if (kind === "num") return Math.round(n * 100) / 100
  if (kind === "mult") return Math.round(n * 100) / 100
  // usd — round to a clean-ish figure
  if (n >= 1e6) return Math.round(n / 1e5) * 1e5
  if (n >= 1e3) return Math.round(n / 1e2) * 1e2
  return Math.round(n)
}

// ── Change generation ─────────────────────────────────────────────────────────

type PendingChange = {
  parameter: string
  previous: string
  current: string
  category: ParameterChangeCategory
  source: string
  executor: string
}

const ORACLE_LADDER = ["Chainlink", "Chainlink + Uniswap TWAP", "Dual-oracle (Chainlink + TWAP)"]
const IR_LADDER = ["Linear v1", "Jump-rate v1", "Jump-rate v2"]

function pick<T>(arr: T[], rand: () => number): T {
  return arr[Math.floor(rand() * arr.length) % arr.length]!
}

/**
 * Build a deterministic changelog for one market. Always returns 11–32 entries so
 * the detail table's 10-per-page pager is always exercised.
 */
export function buildParameterChangelog(input: BuildParameterChangelogInput): ParameterChangeEntry[] {
  const rand = prngFromString(`parameter-changes:${input.product}:${input.slug}`)
  const count = 11 + Math.floor(rand() * 22) // 11..32

  // Build a value chain per classified anchor: newest change lands on the real value.
  type Track = { spec: TrackSpec; parameter: string; chain: PendingChange[] }
  const tracks: Track[] = []
  for (const anchor of input.anchors) {
    const spec = classify(anchor)
    if (!spec) continue
    const parsed = spec.kind === "usd" ? parseCompactUsd(anchor.value) : parseLeadingNumber(anchor.value)
    if (parsed == null) continue
    // Number of times this parameter changed (1..3).
    const changes = 1 + Math.floor(rand() * 3)
    const chain: PendingChange[] = []
    let currentValue = parsed
    // Newest current shows the grid value verbatim, except ranges ("5.00% - 5.55%"),
    // which read oddly against a single `previous`, so normalize those to one value.
    let currentLabel = isRange(anchor.value) ? formatValue(spec.kind, parsed) : anchor.value
    for (let i = 0; i < changes; i++) {
      const prevValue = stepBack(spec.kind, spec, currentValue, rand)
      if (prevValue === currentValue) break
      chain.push({
        parameter: anchor.label,
        previous: formatValue(spec.kind, prevValue),
        current: i === 0 ? currentLabel : formatValue(spec.kind, currentValue),
        category: spec.category,
        source: pick(spec.sources, rand),
        executor: pick(spec.executors, rand),
      })
      currentValue = prevValue
      currentLabel = formatValue(spec.kind, prevValue)
    }
    if (chain.length > 0) tracks.push({ spec, parameter: anchor.label, chain })
  }

  // Synthetic Domain Admin tracks not present in the risk grid.
  const synthetic: PendingChange[] = []
  if (rand() < 0.7) {
    synthetic.push({
      parameter: "Oracle price source",
      previous: ORACLE_LADDER[0]!,
      current: ORACLE_LADDER[Math.min(ORACLE_LADDER.length - 1, 1 + Math.floor(rand() * 2))]!,
      category: "Domain Admin",
      source: "Oracle configuration update",
      executor: "Governance executor",
    })
  }
  if (rand() < 0.5) {
    synthetic.push({
      parameter: "Interest rate strategy",
      previous: IR_LADDER[0]!,
      current: IR_LADDER[Math.min(IR_LADDER.length - 1, 1 + Math.floor(rand() * 2))]!,
      category: "Domain Admin",
      source: "IR strategy update",
      executor: "Governance executor",
    })
  }

  // Occasional emergency freeze → unfreeze pair (newest-first: unfreeze then freeze).
  const emergency: PendingChange[] = []
  if (rand() < 0.3) {
    emergency.push(
      {
        parameter: "Reserve frozen",
        previous: "Frozen",
        current: "Active",
        category: "Emergency",
        source: "Emergency action",
        executor: "Emergency guardian",
      },
      {
        parameter: "Reserve frozen",
        previous: "Active",
        current: "Frozen",
        category: "Emergency",
        source: "Emergency action",
        executor: "Emergency guardian",
      },
    )
  }

  // The oldest entry: listing / onboarding.
  const listing: PendingChange = buildListingChange(input, rand)

  // Round-robin over track chains (newest slice first) to fill the body, newest-first.
  const body: PendingChange[] = [...synthetic]
  let guard = 0
  while (body.length < count - 1 - emergency.length && guard < count * 8) {
    guard += 1
    let progressed = false
    for (const track of tracks) {
      if (body.length >= count - 1 - emergency.length) break
      const next = track.chain.shift()
      if (next) {
        body.push(next)
        progressed = true
      }
    }
    if (!progressed) {
      // Chains exhausted — extend the richest track with more backward steps.
      const track = tracks.find((t) => t.spec)
      if (!track) break
      // Re-seed one more change from where its last known value sat.
      const last = body.filter((b) => b.parameter === track.parameter).at(-1)
      const parsedPrev = last
        ? track.spec.kind === "usd"
          ? parseCompactUsd(last.previous)
          : parseLeadingNumber(last.previous)
        : null
      if (parsedPrev == null) break
      const prevValue = stepBack(track.spec.kind, track.spec, parsedPrev, rand)
      if (prevValue === parsedPrev) break
      track.chain.push({
        parameter: track.parameter,
        previous: formatValue(track.spec.kind, prevValue),
        current: formatValue(track.spec.kind, parsedPrev),
        category: track.spec.category,
        source: pick(track.spec.sources, rand),
        executor: pick(track.spec.executors, rand),
      })
    }
  }

  // Insert the emergency pair mid-list if present.
  if (emergency.length > 0 && body.length > 2) {
    const at = 1 + Math.floor(rand() * Math.max(1, body.length - 1))
    body.splice(at, 0, ...emergency)
  } else {
    body.push(...emergency)
  }

  // Assemble newest → oldest, then the listing as the final (oldest) row.
  const ordered = [...body.slice(0, count - 1), listing]

  // Assign strictly-descending dates from a recent date back to the listing date.
  const newest = SANDBOX_NOW - (7 + Math.floor(rand() * 38)) * MS_PER_DAY
  const listedMs = input.listedAt
    ? Date.parse(`${input.listedAt}T00:00:00Z`)
    : SANDBOX_NOW - (480 + Math.floor(rand() * 200)) * MS_PER_DAY
  const oldest = Math.min(listedMs, newest - (ordered.length - 1) * MS_PER_DAY)

  return ordered.map((change, index) => {
    const progress = ordered.length === 1 ? 0 : index / (ordered.length - 1)
    const jitter = index === 0 || index === ordered.length - 1 ? 0 : (rand() - 0.5) * MS_PER_DAY * 2
    const ms = newest - progress * (newest - oldest) + jitter
    const date = new Date(clampDate(ms, oldest, newest)).toISOString().slice(0, 10)
    const id = `${input.slug}-chg-${index}`
    return {
      id,
      parameter: change.parameter,
      previous: change.previous,
      current: change.current,
      date,
      source: change.source,
      executor: change.executor,
      category: change.category,
      href: input.proposalHref ?? txHrefFor(id),
    }
  })
}

function clampDate(ms: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, ms))
}

/** Deterministic (fake, sandbox-consistent) Etherscan tx link for a change id. */
function txHrefFor(id: string): string {
  let hex = ""
  let seed = id
  while (hex.length < 64) {
    const chunk = hashString(seed).toString(16).padStart(8, "0")
    hex += chunk
    seed = chunk + seed
  }
  return `https://etherscan.io/tx/0x${hex.slice(0, 64)}`
}

function buildListingChange(input: BuildParameterChangelogInput, rand: () => number): PendingChange {
  if (input.product === "borrow-asset") {
    return {
      parameter: "Borrowable",
      previous: "Disabled",
      current: "Enabled",
      category: "Listing",
      source: "Market onboarding",
      executor: "Governance executor",
    }
  }
  const cf = input.anchors.find((a) => /factor|ltv/i.test(a.id) || /factor|ltv/i.test(a.label))?.value
  const lt = input.anchors.find((a) => /threshold/i.test(a.id) || /threshold/i.test(a.label))?.value
  const current = cf && lt ? `${cf} CF / ${lt} LT` : "Enabled"
  void rand
  return {
    parameter: "Collateral configuration",
    previous: "Disabled",
    current,
    category: "Listing",
    source: "Market onboarding",
    executor: "Governance executor",
  }
}
