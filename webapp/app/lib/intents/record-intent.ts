import type { Hex } from "viem"
import { api } from "@/convex/_generated/api"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import { getSiweSession } from "@/app/lib/siwe/auth-store"

/**
 * Tells Convex about a transaction the wallet just sent (`intents.submit`): the hash, the chain and the kind of action,
 * never a target, amount or calldata. Convex then follows the transaction to its receipt, and the wallet's first one
 * dates its "Member since".
 *
 * Best effort: `intents.submit` needs the signed-in (SIWE) session, so nothing is sent without a session for this
 * wallet or without a Convex deployment, and any failure is swallowed. Recording never delays or fails the action.
 */
export type IntentRecorder = (args: { chainId: number; wallet: string; txHash: Hex; kind: string }) => Promise<void>

export const recordSubmittedIntent: IntentRecorder = async ({ chainId, wallet, txHash, kind }) => {
  try {
    if (!hasConvexClient) return
    const session = getSiweSession()
    if (!session || session.wallet !== wallet.toLowerCase()) return
    // Loaded on demand so a guest never pulls the Convex client in.
    const { getSiweConvexClient } = await import("@/app/lib/convex/siwe-convex-provider")
    const client = getSiweConvexClient()
    if (!client) return
    await client.mutation(api.intents.submit, { wallet: session.wallet, chainId, txHash: txHash.toLowerCase(), kind })
  } catch {
    // Progress tracking is optional.
  }
}

/** Records each hash of a sent action without waiting for it: the action's result never depends on the recording. */
export function recordSentHashes(
  record: IntentRecorder,
  args: { chainId: number; wallet: string; kind: string; hashes: readonly (Hex | null | undefined)[] },
): void {
  for (const txHash of args.hashes) {
    if (!txHash) continue
    void record({ chainId: args.chainId, wallet: args.wallet, txHash, kind: args.kind }).catch(() => {})
  }
}
