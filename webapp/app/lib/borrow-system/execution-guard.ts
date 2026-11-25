import type { TransactionIntent } from "./contracts"

/**
 * Content fingerprint used to collapse a duplicate in-flight execution (rapid double-click on
 * the confirm CTA). It must NOT include intent.id: createIntent() mints a fresh id per submit,
 * so an id-keyed fingerprint never matched and the dedup was inert. Key on the action content
 * (type + wallet + market/asset/position + amount) so two identical concurrent submits share
 * one execution while genuinely different actions stay independent.
 */
export function createExecutionFingerprint(intent: TransactionIntent) {
  return [
    intent.actionType,
    intent.walletId,
    intent.marketId ?? "",
    intent.assetId ?? "",
    intent.positionId ?? "",
    intent.debtPositionId ?? "",
    intent.amountUsd6.toString(),
  ].join(":")
}
