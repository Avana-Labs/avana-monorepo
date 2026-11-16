import { api } from "@/convex/_generated/api"
import { hasConvexClient } from "@/app/lib/convex/has-convex-client"
import { getSiweSession } from "@/app/lib/siwe/auth-store"

/**
 * Tells Convex the app saw a quest that no chain event shows (`wallet.clientQuests.record`): signing in, reading the
 * risk primer, pinning a market, copying the invite link. Convex derives the wallet from the sign-in session, accepts
 * only its own list of quests and awards each once, so a repeat is harmless.
 *
 * Best effort, like the transaction reports: without a sign-in session, without a deployment or on any failure it does
 * nothing and never affects what the user is doing.
 */
export type ClientQuestRecorder = (questId: string) => Promise<void>

export const recordClientQuest: ClientQuestRecorder = async (questId) => {
  try {
    if (!hasConvexClient) return
    const session = getSiweSession()
    if (!session) return
    // Loaded on demand so a guest never pulls the Convex client in.
    const { getSiweConvexClient } = await import("@/app/lib/convex/siwe-convex-provider")
    const client = getSiweConvexClient()
    if (!client) return
    await client.mutation(api.wallet.clientQuests.record, { wallet: session.wallet, questId })
  } catch {
    // Quest tracking is optional.
  }
}
