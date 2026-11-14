/**
 * Borrow's siloed tables carry an extra `kind` ("pool" | "asset"). `kindField(withKind)` adds
 * that validator to an args object, typed on the literal flag so borrow's args keep
 * `kind: "pool" | "asset"` and lend/multiply's keep no `kind` at all.
 */

import { v } from "convex/values"

const kindValidator = v.union(v.literal("pool"), v.literal("asset"))

export type KindField<WithKind extends boolean> = WithKind extends true
  ? { kind: typeof kindValidator }
  : Record<never, never>

export function kindField<WithKind extends boolean>(withKind: WithKind): KindField<WithKind> {
  return (withKind ? { kind: kindValidator } : {}) as KindField<WithKind>
}
