"use client"

import { useEffect, useSyncExternalStore } from "react"
import { useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import { isAddress } from "viem"
import { useAvanaSessions } from "@/app/lib/avana-session/avana-sessions-provider"
import {
  frontendFeeRules,
  setFrontendFeeRules,
  setFrontendMemberDiscount,
  subscribeFrontendFeeRules,
  type FeeRules,
} from "@/app/lib/fees/front-end-fee"

function FrontendFeeRulesQuery() {
  const config = useQuery(api.frontendFee.getConfig, {})
  useEffect(() => {
    if (!config) return
    const { maxBps: _maxBps, ...rules } = config
    setFrontendFeeRules(rules as FeeRules)
  }, [config])
  return null
}

/** Loads the wallet's membership discount (Convex `wallet.membership.get`) into the module; 0 until it loads or with none. */
function FrontendMemberDiscountQuery() {
  const { walletId } = useAvanaSessions()
  const wallet = walletId && isAddress(walletId, { strict: false }) ? walletId : null
  const membership = useQuery(api.wallet.membership.get, wallet ? { wallet } : "skip")
  const discountBps = membership?.discountBps ?? 0
  useEffect(() => {
    setFrontendMemberDiscount(discountBps)
    return () => setFrontendMemberDiscount(0)
  }, [discountBps])
  return null
}

/**
 * Loads the fee rules from Convex `frontendFee.getConfig` and the wallet's membership discount into the front-end fee
 * module. Without a Convex deployment the module keeps the default rules (10 bps on every Q-409 action, no discount).
 */
export function FrontendFeeRulesSync() {
  return hasConvexClient ? (
    <>
      <FrontendFeeRulesQuery />
      <FrontendMemberDiscountQuery />
    </>
  ) : null
}

/** The fee rules in force; re-renders when they load or change. */
export function useFrontendFeeRules(): FeeRules {
  return useSyncExternalStore(subscribeFrontendFeeRules, frontendFeeRules, frontendFeeRules)
}
