/**
 * Canonical About-card contract rows for borrow pool / asset, lend, and multiply
 * detail pages. Pool/asset/multiply inject these from Convex `*ContractAddresses`
 * tables; lend seeds the same labels into market content stats.
 */

export const ABOUT_CONTRACT_ADDRESS_SALTS = ["vault", "token", "riskManager", "oracleRouter"] as const

type AboutContractAddressSalt = (typeof ABOUT_CONTRACT_ADDRESS_SALTS)[number]

const ABOUT_CONTRACT_ADDRESS_LABEL_BY_SALT: Record<AboutContractAddressSalt, string> = {
  vault: "Vault Contract Address",
  token: "Token Contract Address",
  riskManager: "Risk Manager Address",
  oracleRouter: "Oracle Router Address",
}

/** Lending-market explanations for the About (i) affordance — Aave-style roles. */
export const ABOUT_CONTRACT_ADDRESS_HELP: Record<string, string> = {
  "Vault Contract Address":
    "The market vault that holds deposits and handles supply, withdraw, and position accounting for this lending market.",
  "Token Contract Address":
    "The underlying ERC20 asset for this market, the token suppliers deposit and borrowers draw against.",
  "Risk Manager Address":
    "The risk configuration contract that sets and enforces parameters such as collateral factors, liquidation thresholds, and supply and borrow caps, similar to Aave’s risk stewardship.",
  "Oracle Router Address":
    "The price oracle router that feeds asset prices used for collateral valuation, borrowing power, and liquidations, similar to Aave’s price oracle.",
}

const LEGACY_CONTRACT_STAT_LABELS = new Set(["Staking Contract Address", "Governance Contract Address"])

/** True for current or legacy contract-address rows (used to strip before Convex inject). */
export function isAboutContractAddressStat(stat: { label: string }): boolean {
  return (
    Object.prototype.hasOwnProperty.call(ABOUT_CONTRACT_ADDRESS_HELP, stat.label) ||
    LEGACY_CONTRACT_STAT_LABELS.has(stat.label) ||
    /Contract Address$/.test(stat.label)
  )
}

export function aboutContractAddressLabelForSalt(salt: string): string | undefined {
  return ABOUT_CONTRACT_ADDRESS_LABEL_BY_SALT[salt as AboutContractAddressSalt]
}

export function sortAboutContractAddressRows<T extends { salt: string }>(rows: readonly T[]): T[] {
  const order = new Map(ABOUT_CONTRACT_ADDRESS_SALTS.map((salt, index) => [salt, index]))
  return [...rows].sort(
    (a, b) =>
      (order.get(a.salt as AboutContractAddressSalt) ?? 99) - (order.get(b.salt as AboutContractAddressSalt) ?? 99),
  )
}
