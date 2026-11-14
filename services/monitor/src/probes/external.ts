// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Signals read outside the protocol contracts: M-23 the governance Safes (owners, threshold, guard, modules; every
// change pages), M-25 each pool token's and debt asset's issuer probes (`paused()`, `basisPointsRate()`; any change
// warns), M-29 GHO's baseDrawnRate on each Avana Hub against the Core Hub's (below it pages), and M-27 the frontend
// (bundle hash against the released one pages on a mismatch; DNS and hosting changes warn).

import { createHash } from "node:crypto";
import { lensAbi } from "@avana/protocol/abis";
import { some } from "@avana/services-common/views";
import { type Address, type Hex, parseAbi } from "viem";
import { type Probe, text } from "../probe.ts";
import type { Level } from "../signals.ts";
import type { Finding } from "../types.ts";

const safeAbi = parseAbi(["function getOwners() view returns (address[])", "function getThreshold() view returns (uint256)", "function getModulesPaginated(address start, uint256 pageSize) view returns (address[] array, address next)"]);
const issuerAbi = parseAbi(["function paused() view returns (bool)", "function basisPointsRate() view returns (uint256)"]);

/** `keccak256("guard_manager.guard.address")`, the Safe's guard slot. */
export const SAFE_GUARD_SLOT: Hex = "0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8";
const SENTINEL: Address = "0x0000000000000000000000000000000000000001";

export interface SafeConfig {
  readonly label: string;
  readonly address: Address;
}

export interface SafeState {
  readonly owners: readonly string[];
  readonly threshold: string;
  readonly guard: string;
  readonly modules: readonly string[];
}

/** Changes between two reads of a Safe, field by field. */
export function safeChanges(before: SafeState, after: SafeState): Record<string, string> {
  const out: Record<string, string> = {};
  const list = (xs: readonly string[]) => [...xs].map((x) => x.toLowerCase()).sort().join(",");
  if (list(before.owners) !== list(after.owners)) out.owners = `${list(before.owners)} -> ${list(after.owners)}`;
  if (before.threshold !== after.threshold) out.threshold = `${before.threshold} -> ${after.threshold}`;
  if (before.guard.toLowerCase() !== after.guard.toLowerCase()) out.guard = `${before.guard} -> ${after.guard}`;
  if (list(before.modules) !== list(after.modules)) out.modules = `${list(before.modules)} -> ${list(after.modules)}`;
  return out;
}

export function safesProbe(safes: readonly SafeConfig[]): Probe<ReadonlyMap<string, SafeState | null>> {
  const last = new Map<string, SafeState>();
  return {
    name: "safes",
    async read(ctx) {
      const r = await some(ctx.views, safes.flatMap((s) => [
        { address: s.address, abi: safeAbi, functionName: "getOwners" },
        { address: s.address, abi: safeAbi, functionName: "getThreshold" },
        { address: s.address, abi: safeAbi, functionName: "getModulesPaginated", args: [SENTINEL, 100n] },
      ]));
      const out = new Map<string, SafeState | null>();
      for (const [k, s] of safes.entries()) {
        const [owners, threshold, modules] = [r[3 * k], r[3 * k + 1], r[3 * k + 2]];
        const slot = await ctx.rpc.getStorageAt(s.address, SAFE_GUARD_SLOT);
        const guard = `0x${slot.slice(-40)}`;
        out.set(s.address.toLowerCase(), owners && threshold !== null && modules ? { owners: owners as string[], threshold: String(threshold), guard, modules: (modules as readonly [string[], string])[0] } : null);
      }
      return out;
    },
    evaluate(input) {
      const out: Finding[] = [];
      for (const s of safes) {
        const key = s.address.toLowerCase();
        const now = input.get(key);
        const subject = `safe:${key}`;
        if (!now) {
          out.push({ signal: "M-23", kind: "unread", level: "ok", subject, detail: {} });
          continue;
        }
        const before = last.get(key);
        last.set(key, now);
        if (!before) continue;
        const changes = safeChanges(before, now);
        if (Object.keys(changes).length > 0) out.push({ signal: "M-23", kind: "event", level: "page", subject, detail: { safe: s.label, address: s.address, ...changes } });
      }
      return out;
    },
    evidence: (input, subject) => {
      const v = input.get(subject.slice("safe:".length));
      return v ? text(v) : null;
    },
  };
}

export interface IssuerProbe {
  readonly paused: boolean | null;
  readonly feeBps: string | null;
}

export function issuerProbe(): Probe<ReadonlyMap<string, IssuerProbe>> {
  const last = new Map<string, IssuerProbe>();
  return {
    name: "issuers",
    async read(ctx) {
      const tokens = [...new Set([...ctx.snapshot.markets.flatMap((m) => m.tokens), ...ctx.manifest.debtReserves.map((d) => d.asset)].map((t) => t.toLowerCase() as Address))];
      // A token without the function answers null; that is its normal state, not a failed read.
      const r = await some(ctx.views, tokens.flatMap((t) => [
        { address: t, abi: issuerAbi, functionName: "paused" },
        { address: t, abi: issuerAbi, functionName: "basisPointsRate" },
      ]));
      return new Map(tokens.map((t, k) => [t, { paused: r[2 * k] === null ? null : Boolean(r[2 * k]), feeBps: r[2 * k + 1] === null ? null : String(r[2 * k + 1]) }]));
    },
    evaluate(input) {
      const out: Finding[] = [];
      for (const [token, now] of input) {
        const before = last.get(token);
        last.set(token, now);
        const changed = before ? before.paused !== now.paused || before.feeBps !== now.feeBps : now.paused === true || (now.feeBps !== null && now.feeBps !== "0");
        if (changed) out.push({ signal: "M-25", kind: "event", level: "warn", subject: `token:${token}`, detail: { token, paused: `${before?.paused ?? "unseen"} -> ${now.paused}`, basisPointsRate: `${before?.feeBps ?? "unseen"} -> ${now.feeBps}` } });
      }
      return out;
    },
    evidence: (input, subject) => {
      const v = input.get(subject.slice("token:".length));
      return v ? text(v) : null;
    },
  };
}

export interface CoreHubGho {
  readonly hub: Address;
  readonly assetId: bigint;
}

export interface GhoRates {
  readonly core: bigint | null;
  /** Each Avana Hub asset of GHO: its baseDrawnRate, bps. */
  readonly avana: ReadonlyMap<string, bigint>;
}

/** M-29 page: GHO's baseDrawnRate on an Avana Hub below the Core Hub's (SPEC-HUB-007). */
export function m29Gho(avanaBps: bigint, coreBps: bigint): Level {
  return avanaBps < coreBps ? "page" : "ok";
}

export function ghoRateProbe(core: CoreHubGho): Probe<GhoRates> {
  return {
    name: "ghoRate",
    async read(ctx) {
      const gho = ctx.manifest.debtReserves.find((d) => d.isGho)?.asset.toLowerCase();
      const [c] = await some(ctx.views, [{ address: ctx.manifest.avana.lens.address, abi: lensAbi, functionName: "getHubAsset", args: [core.hub, core.assetId] }]);
      const avana = new Map(ctx.snapshot.hubAssets.filter((a) => gho !== undefined && a.underlying.toLowerCase() === gho && a.rateCurve !== null).map((a) => [`hubAsset:${a.hub}:${a.assetId}:ghoBase`, BigInt(a.rateCurve!.baseDrawnRateBps)]));
      return { core: c ? BigInt((c as { baseDrawnRateBps: bigint }).baseDrawnRateBps) : null, avana };
    },
    evaluate(input) {
      return [...input.avana].map(([subject, bps]): Finding =>
        input.core === null
          ? { signal: "M-29", kind: "unread", level: "ok", subject, detail: {} }
          : { signal: "M-29", kind: "condition", level: m29Gho(bps, input.core), subject, detail: { baseDrawnRateBps: bps.toString(10), coreHubBaseDrawnRateBps: input.core.toString(10) } },
      );
    },
    evidence: (input, subject) => (input.core === null || !input.avana.has(subject) ? null : text({ core: input.core, avana: input.avana.get(subject) })),
  };
}

export interface FrontendConfig {
  readonly url: string;
  /** The released bundle's sha256 (hex); without it a change of hash warns instead. */
  readonly expectedSha256: string | null;
}

export interface FrontendRead {
  readonly sha256: string;
  readonly server: string;
  readonly dns: string;
}

export interface FrontendDeps {
  fetchText(url: string): Promise<{ body: string; server: string }>;
  resolve(host: string): Promise<string>;
}

export function frontendProbe(cfg: FrontendConfig, deps: FrontendDeps): Probe<FrontendRead> {
  let last: FrontendRead | null = null;
  return {
    name: "frontend",
    async read() {
      const { body, server } = await deps.fetchText(cfg.url);
      return { sha256: createHash("sha256").update(body).digest("hex"), server, dns: await deps.resolve(new URL(cfg.url).hostname) };
    },
    evaluate(input) {
      const out: Finding[] = [];
      if (cfg.expectedSha256 !== null) {
        const ok = input.sha256 === cfg.expectedSha256.toLowerCase().replace(/^0x/, "");
        out.push({ signal: "M-27", kind: "condition", level: ok ? "ok" : "page", subject: "frontend:bundle", detail: { url: cfg.url, sha256: input.sha256, expected: cfg.expectedSha256 } });
      } else if (last && last.sha256 !== input.sha256) {
        out.push({ signal: "M-27", kind: "event", level: "warn", subject: "frontend:bundle", detail: { url: cfg.url, sha256: `${last.sha256} -> ${input.sha256}` } });
      }
      if (last && last.dns !== input.dns) out.push({ signal: "M-27", kind: "event", level: "warn", subject: "frontend:dns", detail: { dns: `${last.dns} -> ${input.dns}` } });
      if (last && last.server !== input.server) out.push({ signal: "M-27", kind: "event", level: "warn", subject: "frontend:hosting", detail: { server: `${last.server} -> ${input.server}` } });
      last = input;
      return out;
    },
    evidence: (input) => text(input),
  };
}
