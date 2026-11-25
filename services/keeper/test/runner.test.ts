// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The bot runner's pass: accounts from the bot stream or, while it fails, the bot's own RPC scan; one LiquidationBot
// per integration; nothing sent while halted; M-16, M-10 and M-09 from the outcomes; the heartbeat every pass; and
// each integration's LiquidationBot configuration from the manifest.

import { describe, expect, it } from "vitest";
import type { Account, Outcome } from "@avana/liquidator/bot";
import type { Address } from "viem";
import type { Alert } from "../src/alerts.ts";
import { type Instance, Runner, instanceConfig } from "../src/runner.ts";

const A = (n: number) => `0x${n.toString(16).padStart(40, "0")}` as Address;
const ADAPTER_1 = A(0x103).toLowerCase();
const ADAPTER_3 = A(0x303).toLowerCase();

class FakeBot {
  seen: Account[][] = [];
  constructor(private readonly answer: (a: Account) => Outcome | undefined) {}
  async pass(accounts: readonly Account[]) {
    this.seen.push([...accounts]);
    return accounts.map(this.answer).filter((o): o is Outcome => o !== undefined);
  }
}

const unhealthy = (hash?: `0x${string}`) => (a: Account): Outcome => ({ ...a, decision: { kind: "direct", debtToCover: 5n }, ...(hash ? { hash } : {}) });

function setup(o: { bot1?: FakeBot; bot3?: FakeBot; stream?: { ok: boolean; accounts: Map<string, Account[]> } | null; halted?: boolean } = {}) {
  const sent: Alert[] = [];
  const beats: bigint[] = [];
  const bot1 = o.bot1 ?? new FakeBot(() => undefined);
  const bot3 = o.bot3 ?? new FakeBot(() => undefined);
  const rpc = { calls: 0 };
  const instance = (integrationId: number, adapter: string, bot: FakeBot): Instance => ({
    integrationId,
    adapter,
    bot,
    rpcAccounts: { refresh: async () => (rpc.calls++, [{ account: A(0xa0 + integrationId), marketId: BigInt(integrationId) }]) },
  });
  const state = { halted: o.halted ?? false };
  const runner = new Runner(1, [instance(1, ADAPTER_1, bot1), instance(3, ADAPTER_3, bot3)], { send: async (a) => void sent.push(a) }, state, o.stream === undefined ? null : o.stream === null ? null : async () => o.stream!, (b) => beats.push(b));
  return { runner, sent, beats, bot1, bot3, rpc, state };
}

describe("Runner.pass", () => {
  it("gives each LiquidationBot the accounts its AaveAdapter announced on the stream", async () => {
    const stream = { ok: true, accounts: new Map([[ADAPTER_1, [{ account: A(1), marketId: 7n }]], [ADAPTER_3, [{ account: A(3), marketId: 9n }]]]) };
    const { runner, bot1, bot3, rpc, beats } = setup({ stream });
    const r = await runner.pass({ number: 10n, timestamp: 1_000 });
    expect(r.source).toBe("stream");
    expect([bot1.seen[0], bot3.seen[0]]).toEqual([[{ account: A(1), marketId: 7n }], [{ account: A(3), marketId: 9n }]]);
    expect(rpc.calls).toBe(0);
    expect(beats).toEqual([10n]);
  });

  it("keeps the streamed accounts across passes and falls back to RPC discovery while the stream fails", async () => {
    const stream = { ok: true, accounts: new Map([[ADAPTER_1, [{ account: A(1), marketId: 7n }]]]) };
    const { runner, bot1, rpc } = setup({ stream });
    await runner.pass({ number: 10n, timestamp: 1_000 });
    stream.accounts = new Map();
    await runner.pass({ number: 11n, timestamp: 1_012 });
    expect(bot1.seen[1]).toEqual([{ account: A(1), marketId: 7n }]);
    stream.ok = false;
    const r = await runner.pass({ number: 12n, timestamp: 1_024 });
    expect(r.source).toBe("rpc");
    expect(rpc.calls).toBe(2);
    expect(bot1.seen[2]).toEqual([{ account: A(0xa1), marketId: 1n }]);
  });

  it("sends nothing while halted, and still reports the head", async () => {
    const { runner, bot1, beats } = setup({ halted: true });
    const r = await runner.pass({ number: 5n, timestamp: 60 });
    expect([r.halted, r.outcomes, bot1.seen]).toEqual([true, [], []]);
    expect(beats).toEqual([5n]);
  });

  it("pages M-16 for an account no bot can fund and warns M-10 for a failed liquidation", async () => {
    const bot1 = new FakeBot((a) => ({ ...a, decision: { kind: "unfunded", debt: 42n } }));
    const bot3 = new FakeBot((a) => ({ ...a, decision: { kind: "error", message: "execution reverted: NothingSeized" } }));
    const { runner, sent } = setup({ bot1, bot3 });
    await runner.pass({ number: 10n, timestamp: 1_000 });
    expect(sent.map((a) => [a.signal, a.level, a.subject])).toEqual([
      ["M-16", "page", `account:${A(0xa1).toLowerCase()}`],
      ["M-10", "warn", "market:3:3"],
    ]);
    expect(sent[1]!.detail.reason).toContain("NothingSeized");
  });

  it("warns M-09 once an account stays liquidatable 60 s, pages at 300 s, and forgets it once liquidated", async () => {
    let hash: `0x${string}` | undefined;
    const bot1 = new FakeBot((a) => unhealthy(hash)(a));
    const { runner, sent } = setup({ bot1 });
    const m09 = async (timestamp: number) => {
      sent.length = 0;
      await runner.pass({ number: BigInt(timestamp), timestamp });
      return sent.filter((a) => a.signal === "M-09").map((a) => a.level);
    };
    expect(await m09(1_000)).toEqual([]);
    expect(await m09(1_059)).toEqual([]);
    expect(await m09(1_060)).toEqual(["warn"]);
    expect(await m09(1_300)).toEqual(["page"]);
    hash = `0x${"ab".repeat(32)}`;
    expect(await m09(1_312)).toEqual([]);
    hash = undefined;
    expect(await m09(1_324)).toEqual([]); // counted afresh
  });
});

describe("instanceConfig", () => {
  const settings = { rpcUrl: "http://x", chainId: 1, swapLegs: [], fromBlock: 0n, pollMs: 1, maxTopUp: 0n, profitSlippageBps: 50n, keystore: "/k" };
  it("takes the integration's contracts and the debt reserves per Spoke", () => {
    const reserves = new Map([[A(0xb0).toLowerCase(), [1n, 2n]]]);
    const c = instanceConfig(settings, { aaveAdapter: A(1), liquidationModule: A(2) }, reserves);
    expect(c).toMatchObject({ adapter: A(1), liquidationModule: A(2), debtReserves: [], spokeDebtReserves: reserves });
    expect(c.flashLiquidator).toBeUndefined();
  });

  it("refuses a FlashLiquidator without a swap router", () => {
    expect(() => instanceConfig(settings, { aaveAdapter: A(1), liquidationModule: A(2), flashLiquidator: A(3) }, new Map())).toThrow(/SWAP_ROUTER/);
  });
});
