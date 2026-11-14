import { NATIVE_GAS_RESERVE_ETH, getSwapAsset, getSwapPair } from "./catalog"
import type { SwapAmountValidationResult, SwapContext, SwapEligibilityResult, UserAssetBalance } from "./contracts"

function sourceRestriction(balance: UserAssetBalance): SwapEligibilityResult | null {
  if (balance.sourceType === "wallet") return null
  if (balance.sourceType === "lend_deposited") {
    return { eligible: false, availableAmount: 0, reason: "ineligible_deposited" }
  }
  if (balance.sourceType === "borrow_collateral_pledged" || balance.sourceType === "borrow_collateral_unpledged") {
    return { eligible: false, availableAmount: 0, reason: "ineligible_pledged" }
  }
  return { eligible: false, availableAmount: 0, reason: "ineligible_protocol_locked" }
}

export function getSwapEligibility(balance: UserAssetBalance, context: SwapContext): SwapEligibilityResult {
  const asset = getSwapAsset(balance.assetId)
  if (!asset || asset.chainId !== context.chainId) {
    return { eligible: false, availableAmount: 0, reason: "unsupported_asset" }
  }
  if (asset.isLpToken) {
    return { eligible: false, availableAmount: 0, reason: "ineligible_lp_token" }
  }
  if (!asset.isSwapEnabled) {
    return { eligible: false, availableAmount: 0, reason: "unsupported_asset" }
  }

  const restricted = sourceRestriction(balance)
  if (restricted) return restricted

  if (context.outputAssetId) {
    if (balance.assetId === context.outputAssetId) {
      return { eligible: false, availableAmount: balance.amount, reason: "same_asset" }
    }
    const pair = getSwapPair(balance.assetId, context.outputAssetId, context.chainId)
    if (!pair?.isEnabled) {
      return { eligible: false, availableAmount: balance.amount, reason: "unsupported_pair" }
    }
  }

  if (balance.amount <= 0) {
    return { eligible: false, availableAmount: 0, reason: "insufficient_balance" }
  }

  return { eligible: true, availableAmount: balance.amount }
}

export function getMaxSwapInputAmount(balance: UserAssetBalance, context: SwapContext) {
  const eligibility = getSwapEligibility(balance, context)
  if (!eligibility.eligible) return 0
  const asset = getSwapAsset(balance.assetId)
  if (!asset?.isNative) return eligibility.availableAmount
  return Math.max(0, eligibility.availableAmount - NATIVE_GAS_RESERVE_ETH)
}

export function validateSwapInputAmount({
  amountText,
  balance,
  context,
}: {
  amountText: string
  balance: UserAssetBalance
  context: SwapContext
}): SwapAmountValidationResult {
  const parsed = Number(amountText)
  const maxAmount = getMaxSwapInputAmount(balance, context)
  const asset = getSwapAsset(balance.assetId)

  if (!Number.isFinite(parsed) || parsed <= 0 || !/^(?:\d+|\d*\.\d+)$/.test(amountText.trim())) {
    return { valid: false, amount: null, maxAmount, reason: "invalid_amount" }
  }

  const eligibility = getSwapEligibility(balance, context)
  if (!eligibility.eligible) {
    return { valid: false, amount: parsed, maxAmount, reason: eligibility.reason }
  }

  if (asset && parsed < asset.minimumSwapAmount) {
    return { valid: false, amount: parsed, maxAmount, reason: "below_minimum" }
  }
  if (asset && parsed > asset.maximumSwapAmount) {
    return { valid: false, amount: parsed, maxAmount, reason: "above_maximum" }
  }
  if (asset?.isNative && parsed > maxAmount) {
    return { valid: false, amount: parsed, maxAmount, reason: "insufficient_native_gas" }
  }
  if (parsed > maxAmount) {
    return { valid: false, amount: parsed, maxAmount, reason: "insufficient_balance" }
  }

  return { valid: true, amount: parsed, maxAmount }
}
