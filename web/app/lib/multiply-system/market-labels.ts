import { formatTokenDisplaySymbol } from "@/app/lib/token-icons"
import { getMultiplyMarketById } from "./catalog"

function displaySymbol(symbol: string) {
  return formatTokenDisplaySymbol(symbol)
}

/** Short pair label (e.g. "USDC / GHO"). */
export function formatMultiplyLoopPairLabel(collateralSymbol: string, borrowSymbol: string) {
  return `${displaySymbol(collateralSymbol)} / ${displaySymbol(borrowSymbol)}`
}

const MULTIPLY_LOOP_SUPPLY_VERB = "Supply" as const
const MULTIPLY_LOOP_BORROW_VERB = "Borrow" as const
const MULTIPLY_LOOP_SUPPLY_LABEL = "Supply {collateral}" as const
const MULTIPLY_LOOP_BORROW_LABEL = "Borrow {borrow}" as const

export function formatMultiplyLoopSupplyLabel(collateralSymbol: string) {
  return `${MULTIPLY_LOOP_SUPPLY_VERB} ${displaySymbol(collateralSymbol)}`
}

export function formatMultiplyLoopBorrowLabel(borrowSymbol: string) {
  return `${MULTIPLY_LOOP_BORROW_VERB} ${displaySymbol(borrowSymbol)}`
}

/** Resolve the collateral/borrow roles used by Multiply activity and receipt labels. */
export function getMultiplyActivityMarketSymbols(marketId?: string) {
  if (!marketId) return null
  const normalizedId = marketId.trim().toLowerCase()
  const market = getMultiplyMarketById(normalizedId)
  if (market) {
    return {
      collateralSymbol: market.collateralAsset.symbol,
      borrowSymbol: market.borrowAsset.symbol,
    }
  }

  const [collateralSymbol, borrowSymbol] = normalizedId.split(/[-_:]/)
  if (!collateralSymbol || !borrowSymbol) return null
  return { collateralSymbol, borrowSymbol }
}

export function formatMultiplyActivityMarketLabel(marketId?: string) {
  const symbols = getMultiplyActivityMarketSymbols(marketId)
  return symbols ? formatMultiplyLoopPairLabel(symbols.collateralSymbol, symbols.borrowSymbol) : "Multiply"
}

function translateLoopRoleLabel(
  t: (key: string) => string,
  phraseKey: string,
  verbKey: string,
  placeholder: string,
  symbol: string,
) {
  const phrase = t(phraseKey)
  if (phrase !== phraseKey && phrase.includes(placeholder)) {
    return phrase.replace(placeholder, symbol)
  }
  return `${t(verbKey)} ${symbol}`
}

export function translateMultiplyLoopSupplyLabel(t: (key: string) => string, collateralSymbol: string) {
  return translateLoopRoleLabel(
    t,
    MULTIPLY_LOOP_SUPPLY_LABEL,
    MULTIPLY_LOOP_SUPPLY_VERB,
    "{collateral}",
    displaySymbol(collateralSymbol),
  )
}

export function translateMultiplyLoopBorrowLabel(t: (key: string) => string, borrowSymbol: string) {
  return translateLoopRoleLabel(
    t,
    MULTIPLY_LOOP_BORROW_LABEL,
    MULTIPLY_LOOP_BORROW_VERB,
    "{borrow}",
    displaySymbol(borrowSymbol),
  )
}

export function translateMultiplyLoopMarketLabel(
  t: (key: string) => string,
  collateralSymbol: string,
  borrowSymbol: string,
) {
  return `${translateMultiplyLoopSupplyLabel(t, collateralSymbol)} · ${translateMultiplyLoopBorrowLabel(t, borrowSymbol)}`
}
