// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The safety state every submission passes before signing (Q-219): kill switch, mode, code check, helper freeze.
// Any guard that cannot be evaluated counts as failed: the keeper keeps scanning and logging, and sends nothing.

import type { BlockContext, CodeTarget, SkipReason } from "../types.ts";

export type EffectiveMode = "active" | "observe" | "halted";

export interface SafetyState {
  /** Set by the authenticated kill switch; persisted, so it survives a restart. */
  halted: boolean;
  /** Set when a code check failed; cleared only by a new verified manifest listing the code (M-26). */
  codeMismatch: { readonly address: string; readonly expected: string; readonly found: string } | null;
  /** Chains where the instance's helper is frozen by the guardian (REQ-SWAP-105); the keeper stops and pages. */
  readonly frozenHelperChains: Set<number>;
}

export function effectiveMode(configured: "observe" | "active", hasSigner: boolean, s: SafetyState): EffectiveMode {
  if (s.halted) return "halted";
  if (configured === "observe" || !hasSigner || s.codeMismatch) return "observe";
  return "active";
}

/**
 * Compares every target of a call with the manifest at the decision block: the ERC-1967 slot of upgradeable
 * contracts and the runtime code hash of immutable ones. A proxy's bytecode never changes on upgrade, so only
 * the slot shows one. The first mismatch is returned; the caller records it and pages M-26.
 */
export async function checkTargets(ctx: BlockContext, targets: readonly CodeTarget[]): Promise<SafetyState["codeMismatch"]> {
  for (const t of targets) {
    if (t.kind === "upgradeable") {
      const found = await ctx.reader.implementationOf(t.address);
      if (found.toLowerCase() !== t.implementation.toLowerCase()) return { address: t.address, expected: t.implementation, found };
    } else {
      const found = await ctx.reader.codeHashOf(t.address);
      if (found.toLowerCase() !== t.codeHash.toLowerCase()) return { address: t.address, expected: t.codeHash, found };
    }
  }
  return null;
}

/** The reason a plan may not be signed now, or null when every guard passes. */
export function blockingReason(mode: EffectiveMode, s: SafetyState, chainId: number): SkipReason | null {
  if (mode === "halted") return "halted";
  if (s.codeMismatch) return "codeMismatch";
  if (s.frozenHelperChains.has(chainId)) return "helperFrozen";
  if (mode === "observe") return "observeOnly";
  return null;
}
