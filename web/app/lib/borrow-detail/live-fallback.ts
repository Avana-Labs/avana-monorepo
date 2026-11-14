import { shouldFailClosedInLive } from "@/app/lib/detail-page/live-fallback"

/**
 * Live list requires Convex snapshots; detail must fail closed the same way.
 * Backed by the shared `shouldFailClosedInLive` — lend + multiply detail use the
 * same guard so no product silently falls through to mock in live mode.
 */
export function shouldFailClosedWithoutSnapshots(mode: "live" | "mock", snapshotCount: number) {
  return shouldFailClosedInLive(mode, snapshotCount > 0)
}
