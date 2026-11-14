const METRIC_TOOLTIPS_BY_ID: Record<string, string> = {
  exposure: "Total collateral value after leverage, including supplied assets and looped positions.",
  debt: "Outstanding borrowed amount you would owe after this transaction.",
  ltv: "Loan-to-value ratio — borrowed value divided by collateral value. Higher LTV means less buffer before liquidation.",
  hf: "Health factor estimates how far your position is from liquidation. Above 1.0 is solvent; below 1.0 can be liquidated.",
  "net-apy": "Estimated net yield after supply APY minus borrow cost for the looped position.",
  "liq-price": "Estimated collateral price at which your position could be liquidated.",
  "collateral-factor": "Share of this collateral's value that counts toward your borrowing power.",
  "collateral-risk": "Additional liquidation buffer above the collateral factor for this market.",
  "borrowable-assets": "Assets you can borrow against this collateral pool.",
  "borrow-power": "Additional borrowing capacity unlocked after pledging this collateral.",
  "supplied-value": "Total value you have supplied to this market.",
  "position-apy": "Blended supply APY for your position after this transaction.",
  "rewards-earned": "Rewards accrued on your supplied balance.",
  "interest-earned": "Interest earned on your supplied balance.",
}

const METRIC_TOOLTIPS_BY_LABEL: Record<string, string> = {
  "Health factor": METRIC_TOOLTIPS_BY_ID.hf!,
  "Health factor after": METRIC_TOOLTIPS_BY_ID.hf!,
  LTV: METRIC_TOOLTIPS_BY_ID.ltv!,
  Exposure: METRIC_TOOLTIPS_BY_ID.exposure!,
  "Estimated debt": METRIC_TOOLTIPS_BY_ID.debt!,
  "Net APY": METRIC_TOOLTIPS_BY_ID["net-apy"]!,
  "Liquidation price": METRIC_TOOLTIPS_BY_ID["liq-price"]!,
  "Borrow APY": "Annualized cost to borrow this asset from the pool.",
  "Supply APY": "Annualized yield earned for supplying this asset to the pool.",
  "Borrow power": METRIC_TOOLTIPS_BY_ID["borrow-power"]!,
  "Remaining debt": "Outstanding debt for this position that still needs to be repaid.",
  "Available to borrow": "Maximum additional borrow capacity based on your collateral and market limits.",
  "Collateral factor": METRIC_TOOLTIPS_BY_ID["collateral-factor"]!,
  "Collateral risk": METRIC_TOOLTIPS_BY_ID["collateral-risk"]!,
  "Borrowable assets": METRIC_TOOLTIPS_BY_ID["borrowable-assets"]!,
  "Borrowing power": METRIC_TOOLTIPS_BY_ID["borrow-power"]!,
  "Supplied value": METRIC_TOOLTIPS_BY_ID["supplied-value"]!,
  "Position APY": METRIC_TOOLTIPS_BY_ID["position-apy"]!,
  "Rewards earned": METRIC_TOOLTIPS_BY_ID["rewards-earned"]!,
  "Interest earned": METRIC_TOOLTIPS_BY_ID["interest-earned"]!,
  "Avana Platform Fee":
    "A 15 bps (0.15%) upfront Avana interface fee applies to transactions initiated through the Avana platform. Interest rates, returns, and other transaction costs may vary depending on the market, position, and execution route.",
}

export const ACTION_INFO_TOOLTIPS: Record<string, string> = {
  rate: "Estimated annual rate for this action, such as borrow APY, supply APY, or net carry.",
  fxRate: "Estimated exchange rate for this swap after price impact.",
  market: "The market this action applies to, including collateral and borrow assets where relevant.",
  fee: "A 15 bps (0.15%) upfront Avana interface fee applies to transactions initiated through the Avana platform. Interest rates, returns, and other transaction costs may vary depending on the market, position, and execution route.",
  amount: "Amount you are confirming for this transaction.",
  apy: "Annualized yield or cost rate for the selected market.",
  collateralApy: "Annualized yield earned by the collateral asset in this multiply position.",
  borrowApy: "Annualized cost to borrow the debt asset in this multiply position.",
  claimTotal: "Total token rewards selected to claim. Network or protocol fees are separate from harvestable rewards.",
}

export function resolveMetricTooltip(id?: string, label?: string, explicit?: string) {
  if (explicit) return explicit
  if (id && METRIC_TOOLTIPS_BY_ID[id]) return METRIC_TOOLTIPS_BY_ID[id]
  if (label && METRIC_TOOLTIPS_BY_LABEL[label]) return METRIC_TOOLTIPS_BY_LABEL[label]
  return undefined
}
