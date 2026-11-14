// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
import { routeAaveTool, AAVE_MODEL_TOOLS, type AaveModelTool } from "./aaveRouting"
export const ASK_AI_DOMAIN_CATEGORIES = [
  "avana",
  "lp_collateral",
  "defi_lending",
  "crypto_market",
  "dex_pool",
  "aave",
  "position_risk",
  "protocol_education",
  "unsupported",
] as const

export const ASK_AI_INTENTS = [
  "position",
  "market",
  "pool",
  "borrow_simulation",
  "stress_test",
  "comparison",
  "education",
  "risk",
  "unsupported",
] as const

type AskAIDomainCategory = (typeof ASK_AI_DOMAIN_CATEGORIES)[number]
type AskAIIntent = (typeof ASK_AI_INTENTS)[number]

type DomainResult = {
  allowed: boolean
  category: AskAIDomainCategory
  intent: AskAIIntent
  confidence: number
}

/**
 * The vocabulary people actually use for "the money and positions I hold here",
 * including the words the product itself puts on screen (the read_portfolio
 * tool, the dashboard's "Net Value" headline). Kept as one source
 * string so the position patterns and the `classifyAskAIDomain` safety net can
 * never drift apart.
 */
const HOLDINGS_WORDS =
  "portfolio|dashboard|net ?(?:value|worth)|total ?(?:value|balance)|balances?|holdings?|positions?|funds?|assets?|collateral|debts?|loans?|borrows?|borrowings?|borrowed|deposits?|deposited|supplied|supplying|lent|lending|staked?|staking|cooldown|withdrawals?|withdraw|unstake|equity|exposure|allocation|pn ?l|p&l|profits?|(?<!impermanent )loss(?:es)?|gains?|returns?|earnings?|earning|earned|interest|yields?|leveraged?|loops?|looping|ltv|health ?factor|liquidat\\w*|buffer|margin|headroom|capacity|credit|invested|investments?|capital|account|wallets?|money|cash|rewards?" +
  // Web3-native ways of naming the same thing.
  "|bags?|stack|book|notional|size|position size|collateral ?ratio|borrow ?power|supply ?balance|debt ?balance|a ?tokens?|receipt ?tokens?|lp ?tokens?|shares?|principal|apy ?earned|interest ?earned|accrued|claimable|unclaimed|vested|locked|unlocked|idle|deployed|dry ?powder|roi|apy i(?:'m)? ?(?:getting|earning)|points?|airdrops?|emissions|incentives"

const HOLDINGS_TOPIC_PATTERN = new RegExp(`\\b(?:${HOLDINGS_WORDS})\\b`, "i")

/** First-person subject, including the common contractions. */
const PERSONAL_SUBJECT_PATTERN =
  /\b(?:my|mine|our|ours|me|us|i|we)\b|\bi['’]?(?:m|ve|ll|d)\b|\bwe['’]?(?:re|ve|ll|d)\b/i

/**
 * Nouns that in this app can only mean the signed-in user's own view. Used only
 * by the late safety net, so an educational "how does portfolio valuation work"
 * still classifies as education first.
 */
const SELF_NOUN_PATTERN = /\b(?:portfolio|dashboard|net ?(?:value|worth))\b/i

/** Danger framing, including phrasings that never say "liquidated". */
const RISK_TOPIC_PATTERN =
  /\b(?:risk|risky|riskier|safe|safety|unsafe|danger(?:ous)?|liquidat\w*|health ?factor|underwater|margin ?call|wreck(?:ed)?|rekt|blow ?up|survive|make it|hold up|buffer|headroom|ltv|exposed|drawdown)\b/i

const POSITION_PATTERNS = [
  new RegExp(`\\b(?:my|our)\\b.{0,40}\\b(?:${HOLDINGS_WORDS})\\b`, "i"),
  // Reverse order too: "the debt on my loop", "balance in my account".
  new RegExp(`\\b(?:${HOLDINGS_WORDS})\\b.{0,30}\\b(?:my|our)\\b`, "i"),
  /\bwhat(?:'s| is) in (?:my|our) (?:wallet|portfolio|account)\b/i,
  /\b(show|analy[sz]e|compare|review|check|open)\b.{0,20}\b(my|our)\b/i,
  /\bhow much can i borrow\b/i,
  /\b(can i borrow|borrow another|borrow more|borrowing capacity|borrow power|close am i to liquidation)\b/i,
  /\b(?:take out|draw|draw down|top up|increase|add to|extend)\b.{0,24}\b(?:more|another|my)?\s*(?:loan|debt|borrow\w*|leverage|position|credit)\b/i,
  /\bhow much more can (?:i|we) (?:borrow|draw|take|get)\b/i,
  // First-person holdings without a literal "my" ("do I have a USDC balance?",
  // "how much ETH do I have", "I hold any GHO"). Kept in first-person + a
  // possession verb so it does not swallow general market questions.
  /\b(?:do|did|have|has)\s+(?:i|we)\s+(?:have|own|hold|got|owe|owed)\b/i,
  /\b(?:how much|what|any).{0,40}\bdo (?:i|we) (?:have|own|hold|owe)\b/i,
  /\b(?:i|we) (?:have|own|hold|holding|got|owe|deposited|borrowed|staked|supplied|lent|looped)\b/i,
  /\b(?:cooldown|withdrawal window|ready to (?:withdraw|unstake)|can (?:i|we) (?:withdraw|unstake))\b/i,
  // Performance framing: "how's my ...", "am I up?", "did I make money?".
  /\bhow(?:'s| is| are)?\s+(?:my|our)\b/i,
  /\bhow (?:am|are) (?:i|we) doing\b/i,
  /\b(?:am|are) (?:i|we) (?:up|down|profitable|in profit|in the green|in the red|losing|winning|even|break ?even)\b/i,
  /\b(?:did|have|has)\s+(?:i|we)\s+(?:make|made|lose|lost|earn|earned|gain|gained)\b/i,
  // A POSSESSED rate is the user's own blended rate, not a market lookup. "apy"
  // is kept out of HOLDINGS_WORDS so market questions keep their intent, so
  // these first-person forms are matched explicitly instead.
  /\b(?:my|our)\s+(?:net\s+|blended\s+|current\s+|effective\s+)?(?:apy|apr|yield|rate|return)s?\b/i,
  /\bwhat\s+(?:apy|apr|yield|rate)\s+(?:am|are)\s+(?:i|we)\b/i,
  /\b(?:apy|apr|yield|rate)\s+(?:am|are)\s+(?:i|we)\s+(?:getting|earning|paying|on)\b/i,
  /\bhow much\s+(?:interest|apy|yield)\s+(?:am|are)\s+(?:i|we)\s+(?:paying|earning|getting)\b/i,
]

const RISK_PATTERNS = [
  /\b(?:will|would|could|can|am|are)\s+(?:i|we)\s+(?:get\s+)?liquidat(?:ed|ion)?\b/i,
  /\b(?:my|our)\s+(?:liquidation|health factor|risk|ltv|buffer)\b/i,
  /\b(?:liquidation|health factor)\s+(?:risk|status|chance|probability)\b/i,
  // Survival framing that never says "liquidated": "Will I make it with this
  // loop?", "am I going to be ok?", "is my position gonna blow up?".
  /\b(?:will|would|can|could|am|are|is)\b.{0,24}\b(?:i|we|my|our)\b.{0,40}\b(?:make it|survive|(?:be )?ok(?:ay)?|(?:be )?fine|(?:be )?safe|(?:be )?alright|hold up|blow ?up|underwater|get wrecked|get rekt|margin ?call)\b/i,
  /\bhow (?:risky|safe|exposed|healthy)\b.{0,24}\b(?:is|am|are)?\s*(?:my|our|i|we)\b/i,
]

/** Forward-looking earnings language: answered by the engine snapshot's
 * projections, not by a balance read. */
const PROJECTION_PATTERN =
  /\b(?:will (?:i|we) (?:earn|make|get)|going to (?:earn|make)|projected|projection|forecast|over (?:a|the) (?:year|month|week)|in (?:a|one) year|per year|annually|next (?:year|month|week)|by (?:year|month) end|compounded?|over time)\b/i

const STRESS_PATTERNS = [
  /\bwhat (?:happens|if)\b/i,
  /\b(stress|shock|drops?|dropped|falls?|fell|crash(?:es|ed)?|dumps?|dumped|tanks?|depeg\w*|price change|downside|worst ?case|black ?swan|bear ?case|scenario|simulate|sensitivity|-\d+ ?%|\d+ ?% ?(?:drop|down|crash|decline))\b/i,
]

/** AMM/DEX venues — these denote a *pool* question. Lending venues are listed
 * separately in LENDING_VENUE_WORDS so "morpho rates" is not read as a pool. */
/** An explicit scenario ask. In this app that means "what does this do to MY
 * position", so it stress-tests rather than becoming a market lookup. */
const SCENARIO_VERB_PATTERN =
  /\b(?:stress ?test|simulate|simulation|scenario|worst ?case|bear ?case|black ?swan|downside|sensitivity)\b/i
const WHAT_IF_PATTERN = /\bwhat (?:happens |would happen )?if\b/i
const MOVE_PATTERN = /\b(?:drops?|dropped|falls?|fell|crash(?:es|ed)?|dumps?|dumped|tanks?|depegs?|-?\d+ ?%)\b/i

const DEX_WORDS =
  "uniswap|uni ?v[234]|curve|balancer|beethoven|aerodrome|velodrome|sushiswap|pancakeswap|camelot|trader ?joe|quickswap|thena|ramses|maverick|ekubo|swapx|spookyswap|spiritswap|raydium|meteora|lifinity|thruster|syncswap"

const LENDING_VENUE_WORDS =
  "aave|compound|morpho|spark|euler|silo|fluid|radiant|benqi|venus|moonwell|granary|seamless|sonne|notional|maple|gearbox|instadapp|dolomite|zerolend|ironclad|lodestar|kamino|marginfi"

/** Assets people name. Every path that uses this also requires a market signal
 * (price/rate/yield/...), so a bare token mention never forces a market read. */
const TOKEN_WORDS =
  "btc|bitcoin|eth|ethereum|weth|steth|wsteth|reth|weeth|cbeth|ezeth|rseth|oeth|frxeth|sfrxeth|wbtc|cbbtc|tbtc|lbtc|solvbtc|sol|solana|avax|avalanche|matic|polygon|bnb|arb|arbitrum|optimism|blast|scroll|linea|zksync|starknet|strk|mantle|metis|celo|gnosis|fantom|sonic|sei|sui|aptos|celestia|injective|atom|cosmos|polkadot|cardano|ripple|xrp|doge|dogecoin|shib|pepe|bonk|" +
  "usdc|usdt|tether|dai|gho|usde|susde|pyusd|fdusd|rlusd|usdg|usds|frax|frxusd|sfrxusd|crvusd|lusd|tusd|usdp|usdd|eurc|eurs|eure|paxg|xaut|" +
  "aave|uni|link|chainlink|crv|cvx|convex|bal|aura|ldo|lido|mkr|maker|snx|synthetix|comp|morpho|pendle|gmx|gns|hyperliquid|dydx|jupiter|ethena|ena|eigen|eigenlayer|ethfi|renzo|kelp|puffer|swell|rpl|rocketpool|fxs|cake|velo|aero|radiant|silo|euler|ondo|" +
  "tokens?|coins?|assets?|stablecoins?|altcoins?|memecoins?"

const TOKEN_PATTERN = new RegExp(`\\b(?:${TOKEN_WORDS})\\b`, "i")

const POOL_PATTERNS = [
  /\b(pools?|liquidity|volume|fee tier|ticks?|in range|out of range|weighting|weights|lp yields?|lp tokens?|concentrated liquidity|impermanent loss|amm|swap fees?|depth|slippage|price impact|pair|trading pair)\b/i,
  new RegExp(`\\b(?:${DEX_WORDS})\\b`, "i"),
]

const MARKET_PATTERNS = [
  new RegExp(`\\b(?:${TOKEN_WORDS})\\b`, "i"),
  new RegExp(`\\b(?:${LENDING_VENUE_WORDS})\\b`, "i"),
  /\b(price|worth|trading at|borrow rate|supply rate|apr|apy|utilization|market)\b/i,
]

const TOKEN_PRICE_LOOKUP_PATTERN = /\b(price|prices|worth|quote|cost)\b/i

// A market-data request needs a real data signal (price, rate, yield, TVL,
// volume, market cap, etc.), not merely a token or protocol name. Without this,
// "who created aave" or "is aave safe" name a token but ask for no market data,
// yet still render an unrequested price chart and market table.
const MARKET_SIGNAL_PATTERN =
  /\b(price|prices|priced|worth|trading at|quote|quotes|cost|apr|apy|apys|yield|yields|rate|rates|utilization|tvl|liquidity|volume|market|markets|market cap|marketcap|fdv|supply cap|borrow cap|depth|spread|premium|discount|funding rate|basis|emissions|incentives|best|highest|cheapest|deepest)\b/i

const EDUCATION_PATTERNS = [
  /\b(explain|explains?|what is|what are|what does|whats|how does|how do|how to|how might|how would|how could|why does|why is|methodology|work|works|meaning|means|definition|difference between|tell me about|walk me through|teach|learn|guide|tutorial|docs?|documentation)\b/i,
  /\b(avana|lp collateral|health factor|ltv|liquidation threshold|oracle|aave hub)\b/i,
]

/** DeFi/web3 subject matter, used to keep an explanation on the knowledge tool. */
const PROTOCOL_TOPIC_PATTERN = new RegExp(
  "\\b(?:avana|amm|apy|apr|borrow\\w*|collateral\\w*|crypto|defi|dex|cex|health ?factor|impermanent ?loss|lend\\w*|liquidat\\w*|lp|ltv|markets?|oracles?|pools?|positions?|stak\\w*|restak\\w*|lst|lrt|liquid ?staking|stablecoins?|tokens?|yields?|farming|vaults?|strateg\\w*|autocompound\\w*|compound\\w*|leverage\\w*|loop\\w*|fold\\w*|delta ?neutral|basis|funding ?rate|perps?|perpetuals?|options?|structured|rwa|tokeni[sz]ed|treasur\\w*|points?|airdrops?|emissions|incentives|bribes|gauges?|boost\\w*|mev|slippage|gas|fees?|bridge\\w*|l1|l2|rollups?|validators?|nodes?|smart ?contracts?|audits?|exploits?|rug ?pulls?|tvl|utilization|reserve ?factor|e-?mode|isolation ?mode|supply ?cap|borrow ?cap|debt ?ceiling|kink|interest ?rate ?model|flash ?loans?|liquidity ?mining|withdrawal ?queue|cooldown|slashing|epochs?|wallets?|custody|self-?custody|seed ?phrase|private ?key|gas ?fees?|hubs?|spokes?|hub ?assets?|spoke ?reserves?|risk ?premium|add ?cap|draw ?cap|caps?|caps? ?reached|liquidation ?(?:config|bonus|penalty|threshold|fee)|close ?factor|collateral ?risk|price ?source|paused|frozen|halted|deactivated|borrowable|receive ?shares|shares|dynamic ?reserve ?config|reserve ?listings?|asset ?listings?|interest ?rate ?(?:strategy|data)|ir ?strategy|position ?manager|access ?manager|config ?engine|governance ?payload|payloads?|aip|proposals?|tokeni[sz]ation ?spoke|reinvestment ?controller|liquidity ?fee|fee ?receiver|executor|guardian|roles?|" +
    DEX_WORDS +
    "|" +
    LENDING_VENUE_WORDS +
    ")\\b",
  "i",
)

const GREETING_PATTERN =
  /^(?:(?:good\s+)?(?:morning|afternoon|evening)|(?:hi|hello|hey|yo|sup)(?:\s+(?:there|avana))?|what(?:'s| is)\s+up)[!.?\s]*$/i

function isAskAIClarificationPrompt(message: string) {
  return /^(?:\?|huh\??|what\??|why\??|how so\??)$/i.test(message.trim())
}

function isAskAIGreeting(message: string) {
  return GREETING_PATTERN.test(message.trim())
}

function matchesAny(message: string, patterns: RegExp[]) {
  return patterns.some((pattern) => pattern.test(message))
}

/**
 * Advisory local semantic routing. Conversation scope is decided by Luna with
 * history; deterministic validation here is limited to empty/oversized input.
 */
export function classifyAskAIDomain(message: string): DomainResult {
  const normalized = message.trim().replace(/\s+/g, " ")
  if (!normalized || normalized.length > 2_000) {
    return { allowed: false, category: "unsupported", intent: "unsupported", confidence: 1 }
  }

  if (isAskAIGreeting(normalized)) {
    return { allowed: true, category: "avana", intent: "education", confidence: 0.99 }
  }

  if (matchesAny(normalized, RISK_PATTERNS)) {
    return { allowed: true, category: "position_risk", intent: "risk", confidence: 0.99 }
  }

  if (matchesAny(normalized, POSITION_PATTERNS)) {
    if (
      /\b(borrow another|borrow more|additional borrow|can i borrow|how much can i borrow|borrow(?:ing)? (?:capacity|power)|how much more can i (?:borrow|draw|take)|take out (?:more|another)|top up my (?:loan|borrow|debt)|increase my (?:loan|borrow|debt|leverage))\b/i.test(
        normalized,
      )
    ) {
      return { allowed: true, category: "defi_lending", intent: "borrow_simulation", confidence: 0.98 }
    }
    if (matchesAny(normalized, STRESS_PATTERNS)) {
      return { allowed: true, category: "position_risk", intent: "stress_test", confidence: 0.98 }
    }
    if (RISK_TOPIC_PATTERN.test(normalized)) {
      return { allowed: true, category: "position_risk", intent: "risk", confidence: 0.98 }
    }
    return { allowed: true, category: "avana", intent: "position", confidence: 0.97 }
  }

  // A scenario question is about the user's own position here, so stress-test it
  // instead of letting "market"/"crashes" pull it into a market lookup or, with
  // no market signal at all, into `unsupported` with no tools.
  if (
    SCENARIO_VERB_PATTERN.test(normalized) ||
    (WHAT_IF_PATTERN.test(normalized) &&
      (MOVE_PATTERN.test(normalized) || TOKEN_PATTERN.test(normalized) || HOLDINGS_TOPIC_PATTERN.test(normalized)))
  ) {
    return { allowed: true, category: "position_risk", intent: "stress_test", confidence: 0.9 }
  }

  // An explicit token quote wins over a protocol name that also denotes a DEX.
  // Without this, "Uniswap token price" is misrouted as a pool lookup.
  if (matchesAny(normalized, MARKET_PATTERNS) && TOKEN_PRICE_LOOKUP_PATTERN.test(normalized)) {
    return { allowed: true, category: "crypto_market", intent: "market", confidence: 0.98 }
  }

  // Explanations about Avana's treatment of LPs, DEX positions, valuation, and
  // liquidation come from the protocol corpus, not from a live pool snapshot.
  if (
    matchesAny(normalized, EDUCATION_PATTERNS) &&
    /\b(avana|collateral|liquidat|oracle|valuation|value|health factor|ltv|position|positions)\b/i.test(normalized)
  ) {
    return {
      allowed: true,
      category: /\bavana\b/i.test(normalized) ? "avana" : "protocol_education",
      intent: "education",
      confidence: 0.97,
    }
  }

  if (matchesAny(normalized, POOL_PATTERNS)) {
    return {
      allowed: true,
      category: "dex_pool",
      intent: /\bcompare\b/i.test(normalized) ? "comparison" : "pool",
      confidence: 0.96,
    }
  }

  // A bare "aave" mention is NOT a market-data request: compare/education keep their own
  // intents, only a real market signal takes the market-card path, and anything else ("who
  // created aave") falls through — otherwise the turn renders an unrequested price chart.
  if (/\baave\b/i.test(normalized)) {
    if (/\bcompare\b/i.test(normalized))
      return { allowed: true, category: "aave", intent: "comparison", confidence: 0.97 }
    if (matchesAny(normalized, EDUCATION_PATTERNS))
      return { allowed: true, category: "aave", intent: "education", confidence: 0.97 }
    if (MARKET_SIGNAL_PATTERN.test(normalized))
      return { allowed: true, category: "aave", intent: "market", confidence: 0.97 }
  }

  // A market-data request needs a real signal (price/rate/yield/TVL/etc.), so a
  // bare token name alone falls through to conversational handling below. An
  // education-framed protocol question keeps its educational intent even when it
  // mentions a market word ("how might markets react?", "explain APY"); those are
  // answered from knowledge, not a live market card.
  if (
    MARKET_SIGNAL_PATTERN.test(normalized) &&
    !(matchesAny(normalized, EDUCATION_PATTERNS) && PROTOCOL_TOPIC_PATTERN.test(normalized))
  ) {
    return {
      allowed: true,
      category: "crypto_market",
      intent: /\bcompare\b/i.test(normalized) ? "comparison" : "market",
      confidence: 0.94,
    }
  }

  if (matchesAny(normalized, EDUCATION_PATTERNS) && PROTOCOL_TOPIC_PATTERN.test(normalized)) {
    return {
      allowed: true,
      category: /\bavana\b/i.test(normalized) ? "avana" : "protocol_education",
      intent: "education",
      confidence: 0.94,
    }
  }

  // Safety net, deliberately LAST so market/pool/education keep their own intents. A
  // first-person money question must never reach `unsupported`: that plans zero tools, and the
  // model then answers from nothing ("I don't have a portfolio balance") for a funded wallet.
  if (
    (PERSONAL_SUBJECT_PATTERN.test(normalized) &&
      (HOLDINGS_TOPIC_PATTERN.test(normalized) || PROJECTION_PATTERN.test(normalized))) ||
    SELF_NOUN_PATTERN.test(normalized)
  ) {
    const risky = RISK_TOPIC_PATTERN.test(normalized)
    return {
      allowed: true,
      category: risky ? "position_risk" : "avana",
      intent: risky ? "risk" : "position",
      confidence: 0.8,
    }
  }

  return { allowed: true, category: "unsupported", intent: "unsupported", confidence: 0.5 }
}

/**
 * Every tool registered on the Ask AI agent. A turn is routed to the smallest subset that can
 * answer it, so a price question never loads the portfolio/risk tools.
 */
type AskAIToolName =
  | AaveModelTool
  | "web_search"
  | "search_avana_knowledge"
  | "read_portfolio"
  | "read_borrow_capacity"
  | "read_position_risk"
  | "read_engine_snapshot"
  | "simulate_borrow"
  | "stress_position"
  | "search_markets"
  | "read_pool_metrics"

export type AskAIModelTier = "fast" | "reasoning"

type AskAITurnRoute = {
  category: AskAIDomainCategory
  intent: AskAIIntent
  confidence: number
  /** The only tools the model may call this turn (AI SDK `activeTools`). */
  tools: AskAIToolName[]
  /** "none" when no tools are needed, so the model answers in a single step. */
  toolChoice: "auto" | "none" | { type: "tool"; toolName: AskAIToolName }
  /** Upper bound on tool/generation steps (AI SDK `stopWhen`). */
  maxSteps: number
  /** Cheap model for simple lookups; the reasoning model for risk analysis. */
  modelTier: AskAIModelTier
}

export function toolChoiceForAskAIStep(route: AskAITurnRoute, stepNumber: number): AskAITurnRoute["toolChoice"] {
  if (stepNumber === 0) return route.toolChoice
  if (route.tools.some((tool) => (AAVE_MODEL_TOOLS as readonly string[]).includes(tool))) return "none"
  return route.tools.length > 0 ? "auto" : "none"
}

// Web search is never a substitute for a Convex tool: prices, pools, balances and risk come
// from Convex. This pattern covers recent public events and recency cues, and routeAskAITurn
// honors it ONLY for otherwise-unsupported turns, so "price right now" still uses Convex.
const NEWS_EVENT_PATTERN =
  /\b(news|headlines?|announc(?:e|ed|ement|ing)|breaking|events?|what happened|happening|going on|latest|recently|trending|hacks?|hacked|exploits?|exploited|attacks?|attacked|breach(?:es|ed)?|drained|rug ?pulls?|rugged|vulnerabilit(?:y|ies)|incidents?|this week|this month|right now)\b/i

/**
 * Deterministic, zero-cost turn router: it only decides how much machinery a turn may spend.
 * Topic scope (redirecting unrelated asks) belongs to the agent instructions, NOT here.
 */
export function routeAskAITurn(message: string): AskAITurnRoute {
  const { category, intent, confidence } = classifyAskAIDomain(message)
  const normalized = message.trim()
  const wantsNewsOrEvents = NEWS_EVENT_PATTERN.test(normalized)

  const plan = (tools: AskAIToolName[], maxSteps: number, modelTier: AskAIModelTier): AskAITurnRoute => ({
    category,
    intent,
    confidence,
    tools,
    toolChoice: tools.length === 1 ? { type: "tool", toolName: tools[0]! } : tools.length > 1 ? "auto" : "none",
    maxSteps,
    modelTier,
  })

  // Greetings and bare clarifications need no tools at all — answer in one step.
  if (isAskAIGreeting(normalized) || isAskAIClarificationPrompt(normalized)) return plan([], 1, "fast")
  const aaveTool = routeAaveTool(normalized)
  if (aaveTool) {
    // routeAaveTool recognises protocol vocabulary the generic classifier does
    // not, so carry a truthful intent instead of inheriting its `unsupported`
    // label — telemetry and any intent-keyed logic read this.
    const aaveIntent: AskAIIntent =
      aaveTool === "get_aave_guide"
        ? "education"
        : aaveTool === "read_aave_positions" || aaveTool === "get_user_rewards"
          ? "position"
          : aaveTool === "read_aave_preview"
            ? "borrow_simulation"
            : "market"
    return {
      ...plan([aaveTool], 2, aaveTool === "read_aave_preview" ? "reasoning" : "fast"),
      category: "aave",
      intent: aaveIntent,
    }
  }
  if (
    /\baave\b/i.test(normalized) &&
    /\b(markets?|pools?|rates?|apy|apr|yields?|liquidity|tvl|prices?)\b/i.test(normalized)
  )
    return { ...plan(["search_markets"], 2, "fast"), intent: "market" }
  // Only open-ended current-events asks reach web search. Anything Convex can
  // answer (prices, pools, the user's positions, risk, Avana how-to) keeps its
  // own tools even when phrased with a "latest"/"right now" recency cue.
  if (wantsNewsOrEvents && intent === "unsupported") return plan(["web_search"], 2, "fast")

  switch (intent) {
    case "position":
      // A projection ("what will I earn in a year", "how are my positions
      // doing over time") needs the engine snapshot, which is the only read
      // that projects yield and reports per-loop leverage and net APY.
      if (PROJECTION_PATTERN.test(normalized)) return plan(["read_engine_snapshot"], 2, "fast")
      // A balance/holdings question needs only the portfolio read.
      return plan(["read_portfolio"], 2, "fast")
    case "risk":
      return plan(["read_position_risk"], 2, "reasoning")
    case "borrow_simulation":
      if (/\b(how much can i borrow|borrowing capacity)\b/i.test(normalized))
        return plan(["read_borrow_capacity"], 2, "reasoning")
      return plan(["read_borrow_capacity", "simulate_borrow"], 3, "reasoning")
    case "stress_test":
      return plan(["read_position_risk", "stress_position"], 4, "reasoning")
    case "pool":
      return plan(["search_markets"], 2, "fast")
    case "market":
      // A price/rate question needs only the market search.
      return plan(["search_markets"], 2, "fast")
    case "comparison":
      return plan(["search_markets"], 2, "fast")
    case "education":
      return plan(["search_avana_knowledge"], 2, "fast")
    case "unsupported":
    default:
      // Let the model answer briefly from its own knowledge (or redirect per the
      // instructions); only grant web search when the ask is clearly time-sensitive.
      return plan([], 1, "fast")
  }
}
