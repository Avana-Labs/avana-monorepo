export const AAVE_MODEL_TOOLS = [
  "get_apy_history",
  "get_reserve_details",
  "get_emode_categories",
  "get_aave_guide",
  "read_aave_positions",
  "get_user_rewards",
  "read_aave_preview",
  "search_governance_proposals",
  "get_governance_proposal",
  "get_proposal_votes",
  "get_hubs",
] as const
export type AaveModelTool = (typeof AAVE_MODEL_TOOLS)[number]

/** Select before looking at any external content. Bare names never trigger reads. */
export function routeAaveTool(prompt: string): AaveModelTool | undefined {
  if (!/\baave\b/i.test(prompt)) return undefined
  if (/\b(token price|price|prices|worth)\b/i.test(prompt)) return undefined
  const personal = /\b(my|mine|me|i|our)\b/i.test(prompt)
  if (personal && /\b(simulate|preview|what if|cross.check)\b/i.test(prompt)) return "read_aave_preview"
  if (personal && /\b(rewards?|claimable|merit)\b/i.test(prompt)) return "get_user_rewards"
  if (
    personal &&
    /\b(positions?|summary|balances?|holdings?|portfolio|activity|history|health factor|debt|supply|borrow|versus|vs)\b/i.test(
      prompt,
    )
  )
    return "read_aave_positions"
  if (/\b(governance|proposals?|votes?|voting|quorum)\b/i.test(prompt)) {
    const hasId = /\bproposal\s*#?\s*\d+\b/i.test(prompt)
    if (hasId && /\b(votes?|voters?|tally)\b/i.test(prompt)) return "get_proposal_votes"
    return hasId ? "get_governance_proposal" : "search_governance_proposals"
  }
  if (
    /\b(apy|apr|rate|rates|yield|yields|supply|borrow)\b/i.test(prompt) &&
    /\b(history|historical|chart|graph|trend|over time|week|month|year|7d|30d)\b/i.test(prompt)
  )
    return "get_apy_history"
  if (
    /\b(hubs?|hub assets|spokes?|spoke assets|protocol history)\b/i.test(prompt) &&
    /\b(v4|liquidity|assets|history|show|list|caps?)\b/i.test(prompt)
  )
    return "get_hubs"
  if (/\b(e.?mode)\b/i.test(prompt) && /\b(categories|parameters|reserves|assets|list)\b/i.test(prompt))
    return "get_emode_categories"
  // Aave V4 risk-configuration vocabulary: a question naming any concrete
  // reserve parameter is a live parameter read, not an explanation.
  if (
    /\b(ltv|liquidation (?:threshold|bonus|penalty|fee|config)|close factor|caps?|supply cap|borrow cap|debt ceiling|reserve factor|risk premium|collateral risk|price source|interest rate (?:strategy|data|model)|kink|isolation mode|e-?mode|decimals|risk parameters|reserve details|reserve config|borrowable|frozen|paused|halted)\b/i.test(
      prompt,
    ) &&
    !/\b(what is|explain|how does)\b/i.test(prompt)
  )
    return "get_reserve_details"
  if (/\b(apy|apr|rate|rates|yield|yields)\b/i.test(prompt) && !/\b(how|explain|work|works)\b/i.test(prompt))
    return undefined
  if (/\b(how|explain|what is|what are|guide|work|works|risks?)\b/i.test(prompt)) return "get_aave_guide"
  return undefined
}

/** Chains Aave serves. Resolved from the prompt so the server picks the market
 * rather than the model guessing — a model asked about "Ethereum" sends it as
 * `marketName`, which matches no real label (AaveV3Ethereum, ...AaveV3EthereumLido).
 */
const AAVE_CHAIN_IDS: ReadonlyArray<readonly [RegExp, number]> = [
  [/\b(?:ethereum|mainnet)\b/i, 1],
  [/\boptimism\b/i, 10],
  [/\b(?:bnb|bsc|binance)\b/i, 56],
  [/\bgnosis\b/i, 100],
  [/\bpolygon\b/i, 137],
  [/\bsonic\b/i, 146],
  [/\bzk\s?sync\b/i, 324],
  [/\bmetis\b/i, 1088],
  [/\bsoneium\b/i, 1868],
  [/\bbase\b/i, 8453],
  [/\barbitrum\b/i, 42161],
  [/\bcelo\b/i, 42220],
  [/\b(?:avalanche|avax)\b/i, 43114],
  [/\blinea\b/i, 59144],
  [/\bscroll\b/i, 534352],
]

// Upper-case words that read like tickers but are not reserve symbols. "AAVE"
// is excluded because every routed prompt names the protocol.
const AAVE_TICKER_NOISE = new Set([
  "AAVE",
  "APY",
  "APR",
  "LTV",
  "TVL",
  "USD",
  "DAO",
  "AIP",
  "MCP",
  "HF",
  "AND",
  "THE",
  "FOR",
  "ALL",
  "NEW",
  "API",
  "DEFI",
])

/** Lower-case words users type, mapped to Aave's reserve symbol casing.
 * "ethereum" is deliberately absent: there it names the chain, not the asset.
 */
const AAVE_SYMBOL_WORDS = new Map<string, string>([
  ["usdc", "USDC"],
  ["usdt", "USDT"],
  ["tether", "USDT"],
  ["dai", "DAI"],
  ["gho", "GHO"],
  ["weth", "WETH"],
  ["eth", "WETH"],
  ["ether", "WETH"],
  ["wbtc", "WBTC"],
  ["btc", "WBTC"],
  ["bitcoin", "WBTC"],
  ["cbbtc", "cbBTC"],
  ["tbtc", "tBTC"],
  ["lbtc", "LBTC"],
  ["wsteth", "wstETH"],
  ["steth", "wstETH"],
  ["reth", "rETH"],
  ["weeth", "weETH"],
  ["cbeth", "cbETH"],
  ["link", "LINK"],
  ["chainlink", "LINK"],
  ["uni", "UNI"],
  ["uniswap", "UNI"],
  ["crv", "CRV"],
  ["curve", "CRV"],
  ["crvusd", "crvUSD"],
  ["arb", "ARB"],
  ["op", "OP"],
  ["bal", "BAL"],
  ["gno", "GNO"],
  ["ldo", "LDO"],
  ["eurc", "EURC"],
  ["usde", "USDe"],
  ["susde", "sUSDe"],
  ["rlusd", "RLUSD"],
  ["frax", "FRAX"],
  ["frxusd", "frxUSD"],
  ["usdg", "USDG"],
  ["paxg", "PAXG"],
  ["pyusd", "PYUSD"],
  ["fdusd", "FDUSD"],
])

const AAVE_PROPOSAL_STATES = [
  "created",
  "active",
  "queued",
  "executed",
  "failed",
  "cancelled",
  "expired",
  "pending",
] as const

function aaveSymbol(prompt: string): string | undefined {
  const ticker = (prompt.match(/\b[A-Z][A-Z0-9]{1,7}\b/g) ?? []).find((word) => !AAVE_TICKER_NOISE.has(word))
  if (ticker) return ticker
  for (const word of prompt.toLowerCase().split(/[^a-z0-9]+/)) {
    const mapped = AAVE_SYMBOL_WORDS.get(word)
    if (mapped) return mapped
  }
  return undefined
}

const aaveChainId = (prompt: string) => AAVE_CHAIN_IDS.find(([pattern]) => pattern.test(prompt))?.[1]
const aaveVersion = (prompt: string) => (/\bv4\b/i.test(prompt) ? "v4" : /\bv3\b/i.test(prompt) ? "v3" : undefined)
const aaveSide = (prompt: string) => (/\bborrow/i.test(prompt) && !/\bsupply/i.test(prompt) ? "borrow" : "supply")

function aaveWindow(prompt: string) {
  if (/\b(?:year|1y|12\s*months?|annual)\b/i.test(prompt)) return "year"
  if (/\b(?:six\s*months?|6\s*months?|180d)\b/i.test(prompt)) return "sixMonths"
  if (/\b(?:month|30d|30\s*days?)\b/i.test(prompt)) return "month"
  if (/\b(?:day|24h|today|1d)\b/i.test(prompt)) return "day"
  return "week"
}

function aaveGuideTopic(prompt: string) {
  if (/\bhealth factor\b/i.test(prompt)) return "health-factor"
  if (/\brisks?\b/i.test(prompt)) return "risks"
  if (/\bgho\b/i.test(prompt)) return "gho"
  if (/\bgovernance\b/i.test(prompt)) return "governance"
  if (/\brewards?\b/i.test(prompt)) return "rewards"
  if (/\bpositions?\b/i.test(prompt)) return "positions"
  if (/\bprices?\b/i.test(prompt)) return "prices"
  if (/\bamounts?\b/i.test(prompt)) return "amounts"
  if (/\bv4\b/i.test(prompt)) return "v4"
  if (/\bv3\b/i.test(prompt)) return "v3"
  return "overview"
}

/**
 * Resolve a routed Aave tool's arguments from the prompt alone, so the turn can
 * prefetch the read and answer in ONE model call — the same single-call shape
 * every other Ask AI data intent uses. Returns undefined when the arguments
 * cannot be resolved confidently, in which case the caller lets the model pick
 * them (and pays for the extra step). `marketName` is never emitted.
 */
export function aaveToolArgsFromPrompt(tool: AaveModelTool, prompt: string): Record<string, unknown> | undefined {
  const chainId = aaveChainId(prompt)
  const version = aaveVersion(prompt)
  switch (tool) {
    case "get_aave_guide":
      return { topic: aaveGuideTopic(prompt) }
    case "search_governance_proposals": {
      const state = AAVE_PROPOSAL_STATES.find((value) => new RegExp(`\\b${value}\\b`, "i").test(prompt))
      return state ? { state } : {}
    }
    case "get_governance_proposal":
    case "get_proposal_votes": {
      const proposalId = prompt.match(/\bproposal\s*#?\s*(\d{1,12})\b/i)?.[1]
      return proposalId ? { proposalId } : undefined
    }
    case "get_hubs":
      return chainId ? { chainId } : {}
    case "get_emode_categories": {
      const symbol = aaveSymbol(prompt)
      return { ...(chainId ? { chainId } : {}), ...(symbol ? { symbols: [symbol] } : {}) }
    }
    case "read_aave_positions":
    case "get_user_rewards":
      return { version: version ?? "all", ...(chainId ? { chainId } : {}) }
    case "get_reserve_details": {
      const symbol = aaveSymbol(prompt)
      return symbol ? { symbol, ...(version ? { version } : {}), ...(chainId ? { chainId } : {}) } : undefined
    }
    case "get_apy_history": {
      const symbol = aaveSymbol(prompt)
      return symbol
        ? {
            symbol,
            ...(version ? { version } : {}),
            ...(chainId ? { chainId } : {}),
            side: aaveSide(prompt),
            window: aaveWindow(prompt),
          }
        : undefined
    }
    // An action + amount is not safe to infer from free text; let the model bind it.
    case "read_aave_preview":
      return undefined
  }
}
