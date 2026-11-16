"use client"

import { useEffect } from "react"
import { useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"

/** The fields of a services/convex `hubAssets` row a Lend send uses: the Lend market slug, its token and its lend reserves. */
export type LendHubAssetRef = {
  chainId: number
  slug: string
  underlying: string
  decimals: number
  /** USD with 8 decimals per whole token. */
  priceUsd8: string
  lendReserves: readonly { spoke: string; reserveId: string }[]
}

let latest: readonly LendHubAssetRef[] | null = null

export function setLendHubAssets(assets: readonly LendHubAssetRef[] | null) {
  latest = assets
}

/** The Hub assets as services/convex last named them, or null before they load. */
export function lendHubAssets(): readonly LendHubAssetRef[] | null {
  return latest
}

/** Keeps {@link lendHubAssets} in step with services/convex `hubAssets.list`. Needs a Convex client. */
export function useLendHubAssetRefs() {
  const assets = useQuery(api.hubAssets.list, {}) as readonly LendHubAssetRef[] | undefined
  useEffect(() => {
    if (assets) setLendHubAssets(assets)
  }, [assets])
}
