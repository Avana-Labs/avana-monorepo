"use client"

import { useCallback } from "react"
import { useMutation } from "convex/react"
import { api } from "@/convex/_generated/api"
import { useAvanaIdentity, useRewardsSessionContext } from "@/app/lib/avana-session/avana-sessions-provider"
import { claimKey, rewardsClaimTxHash } from "@/app/lib/rewards-engine"

/** Persist the Convex transaction before changing the client rewards engine. */
export function useDurableRewardsClaim() {
  const { walletId } = useAvanaIdentity()
  const rewards = useRewardsSessionContext()
  const recordRewardsClaim = useMutation(api.sandbox.transactions.recordRewardsClaim)

  return useCallback(
    async (taskIds: readonly string[]) => {
      if (taskIds.length === 0) throw new Error("Nothing to claim")
      const key = claimKey(taskIds)
      // One receipt hash per task, each matching the engine seed row's hash
      // (rewardsClaimTxHash([taskId])), so every durable row dedups into its
      // quest-titled seed row — including a multi-quest "claim all".
      const syntheticTxHashes = taskIds.map((taskId) => rewardsClaimTxHash([taskId]))
      // Legacy single-hash arg + the receipt link target: the first task's row
      // (always written, so /sandbox/transactions/<hash> resolves).
      const syntheticTxHash = syntheticTxHashes[0]
      const persisted = await recordRewardsClaim({
        wallet: walletId,
        intentId: `rewards:${key}:${taskIds.length}`,
        taskIds: [...taskIds],
        syntheticTxHash,
        syntheticTxHashes,
      })
      const claims = []
      for (const taskId of taskIds) claims.push(await rewards.claimReward(taskId))
      return { claims, persisted, syntheticTxHash }
    },
    [recordRewardsClaim, rewards, walletId],
  )
}
