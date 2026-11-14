"use client"

import { AlertTriangle } from "@/app/components/icons"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useWrongNetwork } from "@/app/lib/web3/use-wrong-network"

/**
 * The wagmi-backed body of the wrong-network banner. Statically imports `useWrongNetwork`
 * (a wagmi hook), so it lives in its own module and is dynamically loaded only once the
 * wallet SDK is mounted — keeping wagmi off the guest critical path. Renders nothing on the
 * correct network.
 */
export function WrongNetworkBannerInner() {
  const { t } = useTranslation()
  const { isWrongNetwork, targetChainName, isSwitching, switchError, switchToTargetChain } = useWrongNetwork()

  if (!isWrongNetwork) return null

  const switchLabel = t("Switch to {chain}").replace("{chain}", targetChainName)

  return (
    <div
      role="alert"
      data-testid="wrong-network-banner"
      className="flex flex-wrap items-center gap-3 border-b border-amber-500/30 bg-amber-500/10 px-4 py-3 text-amber-900 sm:px-6 dark:text-amber-100"
    >
      <AlertTriangle className="size-4 shrink-0 text-amber-600 dark:text-amber-300" />
      <div className="min-w-0 flex-1">
        <div className="text-[14px] font-semibold">{t("Wrong network")}</div>
        <div className="mt-0.5 text-[13px] leading-relaxed opacity-90">
          {t("Switch your wallet to {chain} to continue.").replace("{chain}", targetChainName)}
        </div>
        {switchError ? <div className="mt-1 text-[12px] text-rose-600 dark:text-rose-300">{switchError}</div> : null}
      </div>
      <button
        type="button"
        onClick={() => void switchToTargetChain()}
        disabled={isSwitching}
        className="inline-flex h-9 shrink-0 items-center justify-center rounded-full bg-amber-500 px-4 text-[13px] font-medium text-amber-950 transition-colors hover:bg-amber-500/90 disabled:opacity-70"
      >
        {isSwitching ? t("Switching…") : switchLabel}
      </button>
    </div>
  )
}
