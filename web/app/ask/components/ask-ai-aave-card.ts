import { aaveNumber, aaveObject, aavePlainText, aaveRows, type AaveObject } from "@/app/lib/ask-ai/aave-mcp"
import type { AskAIFinancialResult } from "./ask-ai-financial-result-card"

const number = (value: unknown, suffix = "") => {
  const n = aaveNumber(value)
  return n === undefined ? "Unavailable" : `${n.toLocaleString("en-US", { maximumFractionDigits: 4 })}${suffix}`
}
const dollars = (value: unknown) => (aaveNumber(value) === undefined ? "Unavailable" : `$${number(value)}`)
const pct = (value: unknown) => number(value, "%")
const bool = (value: unknown) => (value === true ? "Met" : value === false ? "Not met" : "Unavailable")

const metricNames: Record<string, string> = {
  suppliedUsd: "Supplied",
  borrowedUsd: "Borrowed",
  supplyCapUsd: "Supply cap",
  borrowCapUsd: "Borrow cap",
  utilizationPct: "Utilization",
  totalSuppliedUsd: "Supplied",
  totalCollateralUsd: "Collateral",
  totalDebtUsd: "Debt",
  netWorthUsd: "Net worth",
  netApyPct: "Net APY",
  healthFactor: "Health factor",
  lowestHealthFactor: "Lowest health factor",
  totalBorrowsUsd: "Borrows",
  totalSupplyBalanceUsd: "Supply balance",
  totalBorrowBalanceUsd: "Borrow balance",
  collateralValueUsd: "Collateral",
  debtValueUsd: "Debt",
  healthFactorAfter: "Health factor after",
  healthFactorBefore: "Health factor before",
  maxLtvPct: "Max LTV",
  liquidationThresholdPct: "Liquidation threshold",
}

function metricsIn(value: unknown, prefix = "", depth = 0): AskAIFinancialResult["metrics"] {
  if (depth > 5) return []
  if (Array.isArray(value))
    return value
      .slice(0, 12)
      .flatMap((row, index) =>
        metricsIn(
          row,
          `${prefix} ${aavePlainText(aaveObject(row).marketName ?? aaveObject(row).name, 60) || index + 1}`,
          depth + 1,
        ),
      )
  return Object.entries(aaveObject(value))
    .flatMap(([key, item]) => {
      const label = metricNames[key]
      if (label && aaveNumber(item) !== undefined)
        return [
          {
            label: `${prefix} ${label}`.trim(),
            value: key.endsWith("Usd") ? dollars(item) : key.endsWith("Pct") ? pct(item) : number(item),
          },
        ]
      return item && typeof item === "object" ? metricsIn(item, `${prefix} ${key}`.trim(), depth + 1) : []
    })
    .slice(0, 30)
}

export function buildAaveCard(kind: string, payload: unknown): AskAIFinancialResult | null {
  const p = aaveObject(payload)
  if (p.walletRequired || p.status === "unavailable" || p.status === "needs_market") return null
  const data = aaveObject(p.data)
  const base = { asOf: aaveNumber(p.asOf), freshness: "fresh" as const }
  if (kind === "aave_reserve") {
    return {
      ...base,
      kind: "market",
      title: `${aavePlainText(data.symbol, 32)} · Aave reserve (live)`,
      metrics: [
        { label: "Market", value: aavePlainText(data.marketName ?? data.spoke, 100) || "Aave" },
        { label: "Chain", value: number(data.chainId) },
        { label: "Supply APY", value: pct(data.supplyApyPct) },
        { label: "Borrow APY", value: pct(data.borrowApyPct) },
        { label: "Max LTV", value: pct(data.maxLtvPct) },
        {
          label: data.collateralFactorPct !== undefined ? "Collateral factor (v4)" : "Liquidation threshold",
          value: pct(data.liquidationThresholdPct ?? data.collateralFactorPct),
        },
        { label: "Supply cap (tokens)", value: number(aaveObject(data.supplyCap).value ?? data.supplyCap) },
        { label: "Borrow cap (tokens)", value: number(aaveObject(data.borrowCap).value ?? data.borrowCap) },
        {
          label: data.liquidityFeePct !== undefined ? "Liquidity fee (v4)" : "Reserve factor",
          value: pct(data.reserveFactorPct ?? data.liquidityFeePct),
        },
        { label: "Decimals", value: number(data.decimals) },
      ],
      badges: aaveRows(data.eModes)
        .slice(0, 6)
        .map((mode) => `eMode: ${aavePlainText(mode.label, 80)}`),
    }
  }
  if (kind === "aave_governance") {
    const proposals = Array.isArray(data.proposals) ? aaveRows(data.proposals) : [aaveObject(data.proposal ?? data)]
    return {
      ...base,
      kind: "market",
      title: "Aave governance (live)",
      metrics: [],
      columns: ["Proposal", "Status", "Quorum (AAVE)", "Quorum met", "For (AAVE)", "Against (AAVE)"],
      rows: proposals
        .filter((proposal) => proposal.proposalId)
        .map((proposal) => ({
          id: String(proposal.proposalId),
          cells: [
            `#${proposal.proposalId} ${aavePlainText(proposal.title, 200)}`,
            aavePlainText(proposal.state, 30),
            number(proposal.quorum),
            bool(proposal.quorumMet),
            number(proposal.votesFor),
            number(proposal.votesAgainst),
          ],
        })),
    }
  }
  if (kind === "aave_positions") {
    const metrics = metricsIn(data.summary, "Aave on-chain")
    const totals = aaveObject(aaveObject(data.avanaSandbox).totals)
    for (const [key, label] of [
      ["lendUsd", "Lend"],
      ["borrowUsd", "Borrow balance"],
      ["multiplyUsd", "Multiply"],
      ["umbrellaUsd", "Umbrella"],
    ]) {
      if (aaveNumber(totals[key]) !== undefined)
        metrics.push({ label: `Avana sandbox ${label}`, value: dollars(totals[key]) })
    }
    return metrics.length
      ? {
          ...base,
          kind: "portfolio",
          title: data.avanaSandbox ? "Your Aave vs Avana" : "Your Aave positions (on-chain)",
          metrics,
        }
      : null
  }
  if (kind === "aave_rewards") {
    const rewards: Array<{ symbol: string; amount: unknown; usd: unknown; chain: unknown }> = []
    const collect = (value: unknown, chain: unknown, depth = 0) => {
      if (depth > 7) return
      if (Array.isArray(value)) {
        value.forEach((row) => collect(row, chain, depth + 1))
        return
      }
      const row = aaveObject(value)
      const amount = aaveObject(row.amount)
      const currency = aaveObject(row.currency ?? row.token)
      if (currency.symbol && (amount.usd !== undefined || amount.amount !== undefined)) {
        rewards.push({
          symbol: aavePlainText(currency.symbol, 32),
          amount: aaveObject(amount.amount).value ?? amount.value,
          usd: amount.usd,
          chain: row.chainId ?? currency.chainId ?? chain,
        })
        return
      }
      Object.values(row)
        .filter((item) => item && typeof item === "object")
        .forEach((item) => collect(item, row.chainId ?? chain, depth + 1))
    }
    collect(data, undefined)
    return {
      ...base,
      kind: "portfolio",
      title: "Aave claimable rewards",
      metrics: [],
      badges: rewards.length
        ? rewards.slice(0, 6).map((row) => `${number(row.amount)} ${row.symbol} claimable`)
        : ["No claimable rewards returned"],
      columns: ["Reward", "Amount", "Value", "Chain"],
      rows: rewards.slice(0, 30).map((row, index) => ({
        id: String(index),
        cells: [row.symbol, number(row.amount), dollars(row.usd), number(row.chain)],
      })),
    }
  }
  if (kind === "aave_emode") {
    const categories: AaveObject[] = []
    const collect = (value: unknown, depth = 0) => {
      if (depth > 5) return
      if (Array.isArray(value)) {
        value.forEach((row) => collect(row, depth + 1))
        return
      }
      const row = aaveObject(value)
      if (row.categoryId !== undefined) {
        categories.push(row)
        return
      }
      Object.values(row).forEach((item) => {
        if (item && typeof item === "object") collect(item, depth + 1)
      })
    }
    collect(p.data)
    return {
      ...base,
      kind: "market",
      title: "Aave eMode categories (live)",
      metrics: [],
      columns: ["eMode", "Max LTV", "Liquidation threshold"],
      rows: categories.slice(0, 20).map((row, i) => ({
        id: String(i),
        cells: [aavePlainText(row.label ?? row.name, 100), pct(row.maxLtvPct), pct(row.liquidationThresholdPct)],
      })),
    }
  }
  const metrics = metricsIn(p.data)
  return metrics.length
    ? {
        ...base,
        kind: "position_risk",
        title: kind === "aave_preview" ? "Aave simulation (on-chain, read-only)" : "Aave v4 hubs (live)",
        metrics,
      }
    : null
}
