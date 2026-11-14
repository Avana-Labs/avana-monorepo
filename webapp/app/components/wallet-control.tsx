"use client"

import { useEffect, useState } from "react"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { IS_DEV_SHORTCUT_MODE, TEST_MODE_WALLET_ADDRESS } from "@/app/lib/test-mode"
import { useWalletGate } from "@/app/lib/web3/wallet-gate"
import { useGetStarted } from "@/app/lib/web3/get-started-intent"
import { useWalletSlotRef } from "@/app/lib/web3/wallet-slots"
import { useSiweToken } from "@/app/lib/siwe/use-siwe-auth"
import {
  walletButtonClasses,
  walletGradient,
  truncateAddress,
  type WalletControlSize,
} from "@/app/components/wallet-control-shared"

/**
 * Once the wallet SDK is active, the real ConnectKit control is rendered by the SDK runtime
 * (a sibling of the app tree) into this slot via a portal — see `wallet-slots.ts`. Keeping
 * wagmi out of the app tree is what stops SDK mount from remounting the whole page.
 */
function ConnectedWalletSlot({ size }: { size: WalletControlSize }) {
  const ref = useWalletSlotRef(size === "mobile" ? "wallet-control-mobile" : "wallet-control-desktop")
  return <span ref={ref} className="contents" />
}

/**
 * Single wallet control for the whole app. It picks one of three implementations:
 *   - dev open-gate/test mode  → the shared dev wallet rendered as a real address pill
 *   - wallet SDK not mounted   → the lightweight idle control (Connect / token account pill)
 *   - wallet SDK mounted       → the full ConnectKit + SIWE flow (dynamically loaded)
 *
 * This module has NO static wagmi/connectkit imports, so a guest never downloads the wallet
 * SDK just to render the header's Connect button.
 */
export function WalletControl({ size = "desktop" }: { size?: WalletControlSize }) {
  const { active } = useWalletGate()
  // Reserve the desktop footprint even between registering the portal and mounting
  // its content. Button widths alone cannot prevent that empty-slot layout shift.
  return (
    <span
      data-wallet-control={size}
      className={size === "desktop" ? "inline-flex h-10 w-[152px] shrink-0 items-center justify-center" : "contents"}
    >
      {IS_DEV_SHORTCUT_MODE ? (
        <DevWalletControl size={size} />
      ) : active ? (
        <ConnectedWalletSlot size={size} />
      ) : (
        <IdleWalletControl size={size} />
      )}
    </span>
  )
}

/**
 * Dev open-gate: the shared dev wallet reads+writes real Convex just like any user.
 * Render it as a normal connected wallet — truncated address + gradient icon — so the
 * dev environment matches production. No amber "Test wallet" label.
 */
function DevWalletControl({ size }: { size: WalletControlSize }) {
  const { pill } = walletButtonClasses(size)
  const address = TEST_MODE_WALLET_ADDRESS
  return (
    <div className={pill} title={address} data-testid="test-mode-wallet" aria-label={address}>
      <span
        aria-hidden
        className="size-5 shrink-0 rounded-full ring-1 ring-border"
        style={{ background: walletGradient(address) }}
      />
      <span className="max-w-[110px] truncate font-data tabular-nums">{truncateAddress(address)}</span>
    </div>
  )
}

/**
 * Wagmi-free control shown before the wallet SDK mounts. Reads only the persisted SIWE
 * token. Clicking either state calls `connect()`, which loads the SDK and (for a fresh
 * connect) auto-opens the modal — a returning signed-in user's SDK is already mounting via
 * the gate's restore effect, so their pill just brings up the account view.
 *
 * Anti-flicker: wallet/token state is client-only, so SSR + the first client render show a
 * "Get Started" placeholder with the same classes as the real button.
 */
function IdleWalletControl({ size }: { size: WalletControlSize }) {
  const { t } = useTranslation()
  const { connect } = useWalletGate()
  const getStarted = useGetStarted()
  const token = useSiweToken()
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])

  const { brand, pill } = walletButtonClasses(size)

  if (!mounted) {
    return (
      <span className={brand} aria-hidden>
        {t("Get Started")}
      </span>
    )
  }

  if (token?.wallet) {
    const address = token.wallet
    return (
      <button type="button" onClick={connect} className={pill} title={address}>
        <span
          aria-hidden
          className="size-5 shrink-0 rounded-full ring-1 ring-border"
          style={{ background: walletGradient(address) }}
        />
        <span className="max-w-[110px] truncate font-data tabular-nums">{truncateAddress(address)}</span>
      </button>
    )
  }

  return (
    <button type="button" onClick={getStarted} className={brand} aria-label={t("Get Started")}>
      {t("Get Started")}
    </button>
  )
}
