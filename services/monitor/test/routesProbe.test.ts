// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// M-11 and M-12 on a scripted chain: the token's balance and allowance slots found by probing, the route swap
// simulated through state overrides (the Lock stub, the input balance and allowance), depth judged at 120 % and 100 %
// of the slot's threshold, GSM room against the stress input, and the daily schedule.

import { describe, expect, it } from "vitest";
import type { ServiceManifest } from "@avana/services-common";
import { FIXTURE_USDC, fixtureMarkets } from "@avana/services-common/fixtures";
import { type Address, type Hex, decodeFunctionData, encodeAbiParameters, keccak256, numberToHex, parseAbi } from "viem";
import type { CallOutcome, Override } from "../src/probe.ts";
import { m11, m12, routesProbe, slotKey } from "../src/probes/routes.ts";
import { findSlots, lockStub } from "../src/sim.ts";
import { EMPTY_MANIFEST, contextOf, fakeProvider, fixtureSnapshot, on } from "./fakeChain.ts";

const SWAP = "0x0000000000000000000000000000000000000075" as Address;
const LOCK = "0x00000000000000000000000000000000000000a0" as Address;
const ROUTE = "0x00000000000000000000000000000000000000b0" as Address;
const GSM = "0x00000000000000000000000000000000000000c0" as Address;
const USDT = fixtureMarkets[0]!.tokens[1]!.toLowerCase() as Address;
const manifest = { ...EMPTY_MANIFEST, avana: { ...EMPTY_MANIFEST.avana, lpVaultSwap: { address: SWAP }, lock: { address: LOCK } } } as unknown as ServiceManifest;

const word = (x: bigint) => numberToHex(x, { size: 32 });
const pair = (a: Hex, b: Hex) => keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }], [a, b]));
const addr = (a: string) => word(BigInt(a));
/** A token keeping balances at slot 9 and allowances at slot 10, as USDC's FiatToken does. */
const balSlot = (h: string) => pair(addr(h), word(9n));
const allowSlot = (o: string, s: string) => pair(addr(s), pair(addr(o), word(10n)));
const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)", "function allowance(address, address) view returns (uint256)", "function swap(uint256 amountIn, uint256 minOut) returns (uint256)"]);

/** The scripted chain's `eth_call`: the token reads its overridden storage; the route swaps on a constant-product pool of depth `depth`. */
function caller(depth: () => bigint) {
  return (from: Address, to: Address, data: Hex, overrides: readonly Override[]): CallOutcome => {
    const diff = new Map(overrides.flatMap((o) => (o.stateDiff ?? []).map((d) => [`${o.address.toLowerCase()}:${d.slot}`, BigInt(d.value)] as const)));
    const call = decodeFunctionData({ abi: erc20, data });
    if (to.toLowerCase() === USDT) {
      const slot = call.functionName === "balanceOf" ? balSlot(call.args[0]) : call.functionName === "allowance" ? allowSlot(call.args[0], call.args[1]) : null;
      return { ok: true, data: word(slot ? (diff.get(`${USDT}:${slot}`) ?? 0n) : 0n) };
    }
    if (to.toLowerCase() === ROUTE && call.functionName === "swap") {
      const amountIn = call.args[0];
      if (from !== SWAP) return { ok: false, error: "NotLPVaultSwap()" };
      if (!overrides.some((o) => o.address === LOCK && o.code === lockStub(SWAP))) return { ok: false, error: "NotLocked()" };
      if (diff.get(`${USDT}:${balSlot(SWAP)}`) !== amountIn || diff.get(`${USDT}:${allowSlot(SWAP, ROUTE)}`) !== amountIn) return { ok: false, error: "TransferMismatch()" };
      return { ok: true, data: word((amountIn * depth()) / (depth() + amountIn)) };
    }
    return { ok: false, error: "unscripted" };
  };
}

const T = 1_000_000_000n; // 1,000 USDC of stress size, the slot's threshold

function chain(o: { depth: () => bigint; gsm?: { cap: bigint; held: bigint }; threshold?: bigint }) {
  return fakeProvider({
    snapshot: (b) => fixtureSnapshot(b, (s) => ({ ...s, markets: [{ ...s.markets[0]!, status: 2 }] })),
    call: caller(o.depth),
    handlers: [
      on("getTokenPrices", () => [[100_000_000n, 100_000_000n], 0n, 0]),
      on("getMarketParams", () => ({ slippageAllowanceBps: 100 })),
      on("getRoute", (args) => (args[3] === 0 ? [ROUTE, true] : ["0x0000000000000000000000000000000000000000", false])),
      on("routeDepthThreshold", () => o.threshold ?? T),
      on("routeType", () => (o.gsm ? 0 : 1)),
      on("dependencies", () => (o.gsm ? [GSM] : [])),
      on("getExposureCap", () => o.gsm?.cap, GSM),
      on("getAvailableUnderlyingLiquidity", () => o.gsm?.held, GSM),
    ],
  });
}

async function measure(o: Parameters<typeof chain>[0], t = 1_000) {
  const probe = routesProbe();
  const ctx = await contextOf(chain(o), { number: BigInt(t), timestamp: t }, manifest);
  return probe.evaluate(await probe.read(ctx), ctx.block);
}

const subject = `route:${slotKey("1", USDT, FIXTURE_USDC, 0)}`;

describe("token slots", () => {
  it("finds a FiatToken-like token's balance and allowance mappings", async () => {
    const ctx = await contextOf(chain({ depth: () => 1n }), { number: 1n, timestamp: 1 }, manifest);
    expect(await findSlots(ctx.rpc, USDT, SWAP)).toEqual({ balance: { slot: 9n, keyFirst: true }, allowance: { slot: 10n, keyFirst: true } });
  });
});

describe("M-11 route depth", () => {
  it("is ok when the route absorbs 120 % of the stress size within the slippage allowance", async () => {
    const [f] = await measure({ depth: () => 200_000_000_000n });
    expect(f).toMatchObject({ signal: "M-11", level: "ok", subject, detail: { depth: "120", kind: "primary" } });
  });

  it("warns when only 100 % passes and pages below it", async () => {
    expect((await measure({ depth: () => 100_000_000_000n }))[0]).toMatchObject({ level: "warn", detail: { depth: "100" } });
    expect((await measure({ depth: () => 50_000_000_000n }))[0]).toMatchObject({ level: "page", detail: { depth: "below" } });
  });

  it("warns on a slot with no threshold set", async () => {
    expect((await measure({ depth: () => 1n, threshold: 0n }))[0]).toMatchObject({ level: "warn", detail: { depth: "noThreshold" } });
  });

  it("levels", () => {
    const base = { marketId: "1", token: USDT, debtAsset: FIXTURE_USDC, kind: 0, route: ROUTE, threshold: T, stressIn: T, minOut100: T, at120: "", at100: "", gsmRoom: null } as const;
    expect([m11({ ...base, depth: "120" }), m11({ ...base, depth: "100" }), m11({ ...base, depth: "below" }), m11({ ...base, depth: "notSimulated" })]).toEqual(["ok", "warn", "page", "warn"]);
  });
});

describe("M-12 GSM headroom", () => {
  it("warns below 2x the stress input and pages below 1x", async () => {
    const room = async (cap: bigint) => (await measure({ depth: () => 200_000_000_000n, gsm: { cap, held: 0n } })).find((f) => f.signal === "M-12")!.level;
    expect([await room(2_000_000_000n), await room(1_999_999_999n), await room(999_999_999n)]).toEqual(["ok", "warn", "page"]);
    expect(m12(0n, 1n)).toBe("page");
  });
});

describe("schedule", () => {
  it("measures once a day, repeats the last findings in between, and re-measures on the measurement's own block", async () => {
    let depth = 200_000_000_000n;
    let swaps = 0;
    const p = chain({ depth: () => depth });
    const inner = p.call!;
    p.call = (from, to, data, o) => {
      if (to === ROUTE) swaps++;
      return inner(from, to, data, o);
    };
    const probe = routesProbe(86_400);
    const at = async (t: number, n = t) => {
      const ctx = await contextOf(p, { number: BigInt(n), timestamp: t }, manifest);
      return probe.evaluate(await probe.read(ctx), ctx.block)[0]!.level;
    };
    expect(await at(1_000)).toBe("ok");
    expect(swaps).toBe(2);
    depth = 50_000_000_000n;
    expect(await at(1_000)).toBe("page"); // the confirming read of the same block measures again
    expect(await at(50_000)).toBe("page"); // not due: the last measurement stands
    expect(swaps).toBe(4);
    depth = 200_000_000_000n;
    expect(await at(1_000 + 86_400)).toBe("ok");
    expect(swaps).toBe(6);
  });
});
