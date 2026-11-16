"use client"

import { useEffect, useSyncExternalStore } from "react"
import { useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import {
  frontendFeeRules,
  setFrontendFeeRules,
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

/**
 * Loads the fee rules from Convex `frontendFee.getConfig` into the front-end fee module. Without
 * a Convex deployment the module keeps the default rules (10 bps on every Q-409 action).
 */
export function FrontendFeeRulesSync() {
  return hasConvexClient ? <FrontendFeeRulesQuery /> : null
}

/** The fee rules in force; re-renders when they load or change. */
export function useFrontendFeeRules(): FeeRules {
  return useSyncExternalStore(subscribeFrontendFeeRules, frontendFeeRules, frontendFeeRules)
}
