// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The handlers on scripted logs (test/harness): a pool's two markets, account attribution from AccountCreated, Spoke
// debt moving only for attributed accounts and only once when two sources deliver the same log, every log writing its
// event_log row and the parties it names, positions and per-market pledge and withdrawal totals, vault-token mints and
// burns, liquidations, repayments with collateral, First-Loss cover, the keeper registry, and the risk premium and
// collateral-risk rows behind the refresh list.

import { describe, expect, it } from "vitest";
import schema from "ponder:schema";
import { type LogSpec, Run, addr } from "./harness/run.ts";
import { FLASH, V3, V4 } from "./harness/manifest.ts";
import { lastRiskChange, refreshList } from "../src/lib/premiumRefresh.ts";

const ADAPTER = V3.aaveAdapter;
const SPOKE = addr(0xb0);
const WALLET = addr(0xc0);
const PROXY = addr(0xc1);
const STRANGER = addr(0xc2);
const VAULT = addr(0xd0);
const POOL = `0x${"00".repeat(12)}${addr(0xf5).slice(2)}` as const;
const KEY = `0x${"00".repeat(31)}2a` as const;
const lower = (a: string) => a.toLowerCase();

/** A pool listed on integration 1: its Full range (7) and Custom range (8) markets, then the pool. */
const listed = (block: bigint): LogSpec[] => [
  { source: "RiskModule", event: "MarketListed", args: { marketId: 7n, pool: POOL, kind: 0, bandLower: -887_270, bandUpper: 887_270, unitDecimals: 18 }, address: V3.riskModule, block, logIndex: 0 },
  { source: "RiskModule", event: "MarketListed", args: { marketId: 8n, pool: POOL, kind: 1, bandLower: -100, bandUpper: 100, unitDecimals: 18 }, address: V3.riskModule, block, logIndex: 1 },
  { source: "RiskModule", event: "PoolListed", args: { pool: POOL, spoke: SPOKE, fullRange: 7n, customRange: 8n, listingTick: 0, ltvBps: 9_000 }, address: V3.riskModule, block, logIndex: 2 },
];

const created = (block: bigint, logIndex: number): LogSpec[] => [
  { source: "AaveAdapter", event: "AccountCreated", args: { wallet: WALLET, marketId: 7n, account: PROXY }, address: ADAPTER, block, logIndex },
];

/** A run with the pool listed at block 5 (its fee read from the pool). */
async function listedRun(): Promise<Run> {
  const run = new Run();
  run.client.readContract = async () => 100;
  await run.deliverAll(listed(5n));
  return run;
}

const borrow = (block: bigint, logIndex: number, user = PROXY, shares = 1_000n, source = "AaveSpoke"): LogSpec => ({
  source,
  event: "Borrow",
  args: { reserveId: 2n, caller: ADAPTER, user, drawnShares: shares, drawnAmount: shares },
  address: SPOKE,
  block,
  logIndex,
});

const repay = (block: bigint, logIndex: number, shares: bigint): LogSpec => ({
  source: "AaveSpoke",
  event: "Repay",
  args: { reserveId: 2n, caller: ADAPTER, user: PROXY, drawnShares: shares, totalAmountRepaid: shares, premiumDelta: { sharesDelta: 0n, offsetRayDelta: 0n, restoredPremiumRay: 0n } },
  address: SPOKE,
  block,
  logIndex,
});

const premium = (block: bigint, logIndex: number, riskPremium: bigint, user = PROXY): LogSpec => ({
  source: "AaveSpoke",
  event: "UpdateUserRiskPremium",
  args: { user, riskPremium },
  address: SPOKE,
  block,
  logIndex,
});

const reserveConfig = (block: bigint, logIndex: number, collateralRisk: number, source = "AaveSpoke"): LogSpec => ({
  source,
  event: "UpdateReserveConfig",
  args: { reserveId: 1n, config: { collateralRisk, paused: false, frozen: false, borrowable: false, receiveSharesEnabled: false } },
  address: SPOKE,
  block,
  logIndex,
});

describe("markets", () => {
  it("lists a pool's Full range and Custom range markets with their bands and the LTV and Spoke they share", async () => {
    const run = await listedRun();
    expect(run.store.rows(schema.market).map((m) => [m.marketId, m.kind, m.bandLower, m.bandUpper, m.ltvBps, m.spoke, m.integrationId, m.active])).toEqual([
      [7n, "full-range", -887_270, 887_270, 9_000, lower(SPOKE), 1, false],
      [8n, "custom-range", -100, 100, 9_000, lower(SPOKE), 1, false],
    ]);
    expect(run.store.rows(schema.ammPool)).toMatchObject([{ pool: lower(addr(0xf5)), integrationId: 1, feePips: 100, listedBlock: 5n }]);
  });

  it("activates a market with its vault token, LPOracle and reserve", async () => {
    const run = await listedRun();
    await run.deliver({ source: "RiskModule", event: "MarketActivated", args: { marketId: 8n, vaultToken: VAULT, reserveId: 4n, lpOracle: addr(0xd1) }, address: V3.riskModule, block: 6n, logIndex: 0 });
    expect(run.store.rows(schema.market).find((m) => m.marketId === 8n)).toMatchObject({ active: true, vaultToken: lower(VAULT), reserveId: 4n });
  });

  it("keeps two integrations' markets of the same ID apart (each RiskModule numbers its markets from 1)", async () => {
    const run = await listedRun();
    // Integration 3 lists its own markets 7 and 8 on another Spoke and activates its 8.
    await run.deliverAll(listed(6n).map((l) => ({ ...l, address: V4.riskModule, args: l.event === "PoolListed" ? { ...l.args, spoke: addr(0xb1) } : l.args })));
    await run.deliver({ source: "RiskModule", event: "MarketActivated", args: { marketId: 8n, vaultToken: VAULT, reserveId: 4n, lpOracle: addr(0xd1) }, address: V4.riskModule, block: 7n, logIndex: 0 });
    const rows = run.store.rows(schema.market).map((m) => [m.integrationId, m.marketId, m.spoke, m.active]);
    expect(rows.sort((a, b) => Number(a[0]) - Number(b[0]) || Number(a[1]) - Number(b[1]))).toEqual([
      [1, 7n, lower(SPOKE), false],
      [1, 8n, lower(SPOKE), false],
      [3, 7n, lower(addr(0xb1)), false],
      [3, 8n, lower(addr(0xb1)), true],
    ]);
  });

  it("refuses a RiskModule the manifest does not list", async () => {
    const run = new Run();
    await expect(run.deliver({ ...listed(5n)[0]!, address: addr(0x999) })).rejects.toThrow(/not in the manifest/);
  });

  it("keeps each RiskModule's keeper registry and debt reserves", async () => {
    const run = new Run();
    await run.deliverAll([
      { source: "RiskModule", event: "KeeperAdded", args: { keeper: addr(0xb07) }, address: V3.riskModule, block: 3n, logIndex: 0 },
      { source: "RiskModule", event: "DebtReserveSet", args: { spoke: SPOKE, reserveId: 2n, hub: addr(0xab), asset: addr(0xac), firstLossReserve: addr(0xf1) }, address: V3.riskModule, block: 3n, logIndex: 1 },
      { source: "RiskModule", event: "KeeperRemoved", args: { keeper: addr(0xb07) }, address: V3.riskModule, block: 4n, logIndex: 0 },
    ]);
    expect(run.store.rows(schema.keeper)).toMatchObject([{ keeper: lower(addr(0xb07)), active: false, lastBlock: 4n }]);
    expect(run.store.rows(schema.debtReserve)).toMatchObject([{ debtReserveId: 2n, firstLossReserve: lower(addr(0xf1)), listed: true }]);
  });
});

describe("account attribution and debt", () => {
  it("attributes an account from AccountCreated under its market's Spoke, and moves its drawn shares", async () => {
    const run = await listedRun();
    await run.deliverAll([...created(10n, 0), borrow(11n, 0), repay(12n, 0, 400n)]);
    const [account] = run.store.rows(schema.account);
    expect(account).toMatchObject({ wallet: lower(WALLET), proxy: lower(PROXY), spoke: lower(SPOKE), adapter: lower(ADAPTER), integrationId: 1, marketId: 7n, createdBlock: 10n });
    const [debt] = run.store.rows(schema.accountDebt);
    expect(debt).toMatchObject({ debtReserveId: 2n, drawnShares: 600n, deficitReported: false, lastBlock: 12n });
  });

  it("moves debt once when two sources deliver the same Spoke log", async () => {
    const run = await listedRun();
    await run.deliverAll([...created(10n, 0), borrow(11n, 0, PROXY, 1_000n, "AaveSpoke"), borrow(11n, 0, PROXY, 1_000n, "AaveSpokeAdded")]);
    expect(run.store.rows(schema.accountDebt)[0]!.drawnShares).toBe(1_000n);
    expect(run.store.rows(schema.eventLog).filter((r) => r.kind === "AaveSpoke.Borrow")).toHaveLength(1);
  });

  it("keeps the debt of an address the AaveAdapter did not announce out of the account tables", async () => {
    const run = await listedRun();
    await run.deliverAll([...created(10n, 0), borrow(11n, 0, STRANGER)]);
    expect(run.store.rows(schema.accountDebt)).toEqual([]);
    expect(run.store.rows(schema.eventLog).map((r) => r.kind)).toContain("AaveSpoke.Borrow");
  });

  it("refuses an account of a market not listed yet", async () => {
    await expect(new Run().deliver(created(10n, 0)[0]!)).rejects.toThrow(/before its PoolListed/);
  });

  it("reads an account's market under its own AaveAdapter's integration", async () => {
    // Integration 1 lists market 7; integration 3 has no market 7, so its AaveAdapter's AccountCreated is refused.
    const run = await listedRun();
    await expect(run.deliver({ ...created(10n, 0)[0]!, address: V4.aaveAdapter })).rejects.toThrow(/market 3:7 .* before its PoolListed/);
  });

  it("writes one log_party row per address a log names", async () => {
    const run = await listedRun();
    await run.deliverAll([...created(10n, 0), borrow(11n, 0)]);
    const parties = run.store.rows(schema.logParty).filter((r) => r.blockNumber === 11n).map((r) => r.party).sort();
    expect(parties).toEqual([lower(ADAPTER), lower(PROXY)].sort());
  });
});

describe("positions and market totals", () => {
  const pledged = (marketId: bigint, liquidity: bigint, credit: bigint, block = 20n): LogSpec[] => [
    { source: "LPVault", event: "PositionPledged", args: { positionKey: KEY, account: PROXY, marketId, from: WALLET, liquidity, credit }, address: V3.lpVault, block, logIndex: 0 },
    { source: "AaveAdapter", event: "Pledged", args: { wallet: WALLET, marketId, positionKey: KEY, credit }, address: ADAPTER, block, logIndex: 1 },
  ];
  const totals = (run: Run) => run.store.rows(schema.marketCollateral).map((m) => [m.marketId, m.positions, m.liquidity, m.credit, m.pledges, m.withdrawals, m.unwinds]);

  it("counts each LPVault's pledges under its own integration's market", async () => {
    const run = new Run();
    const other = `0x${"00".repeat(31)}2b` as const;
    await run.deliverAll(pledged(8n, 1_000n, 400n));
    await run.deliver({ source: "LPVault", event: "PositionPledged", args: { positionKey: other, account: PROXY, marketId: 8n, from: WALLET, liquidity: 50n, credit: 30n }, address: V4.lpVault, block: 25n, logIndex: 0 });
    const rows = run.store.rows(schema.marketCollateral).map((m) => [m.integrationId, m.marketId, m.positions, m.liquidity]);
    expect(rows.sort((a, b) => Number(a[0]) - Number(b[0]))).toEqual([
      [1, 8n, 1, 1_000n],
      [3, 8n, 1, 50n],
    ]);
    expect(run.store.rows(schema.position).map((p) => [p.integrationId, p.marketId]).sort()).toEqual([
      [1, 8n],
      [3, 8n],
    ]);
  });

  it("holds a pledged position for its wallet and counts it in its market", async () => {
    const run = new Run();
    await run.deliverAll(pledged(8n, 1_000n, 400n));
    expect(run.store.rows(schema.position)[0]).toMatchObject({ marketId: 8n, account: lower(PROXY), wallet: lower(WALLET), liquidity: 1_000n, credit: 400n, held: true });
    expect(totals(run)).toEqual([[8n, 1, 1_000n, 400n, 1, 0, 0]]);
  });

  it("moves liquidity and credit on add, partial withdraw, liquidation unwind and release", async () => {
    const run = new Run();
    await run.deliverAll(pledged(8n, 1_000n, 400n));
    const ev = (event: string, args: Record<string, unknown>, block: bigint): LogSpec => ({ source: "LPVault", event, args: { positionKey: KEY, ...args }, address: V3.lpVault, block, logIndex: 0 });
    await run.deliver(ev("LiquidityAdded", { payer: WALLET, liquidity: 500n, credit: 200n, amount0: 1n, amount1: 1n }, 21n));
    await run.deliver(ev("LiquidityRemoved", { recipient: WALLET, liquidity: 300n, credit: 120n, amount0: 1n, amount1: 1n }, 22n));
    await run.deliver(ev("PositionUnwound", { recipient: addr(0x102), liquidity: 200n, credit: 80n, amount0: 1n, amount1: 1n }, 23n));
    expect(run.store.rows(schema.position)[0]).toMatchObject({ liquidity: 1_000n, credit: 400n, held: true, lastBlock: 23n });
    await run.deliver(ev("PositionReleased", { account: PROXY, recipient: WALLET, liquidity: 1_000n, credit: 400n }, 24n));
    expect(run.store.rows(schema.position)[0]).toMatchObject({ liquidity: 0n, credit: 0n, held: false });
    expect(totals(run)).toEqual([[8n, 0, 0n, 0n, 1, 2, 1]]);
  });

  it("keeps a pool's Full range and Custom range markets apart", async () => {
    const run = new Run();
    const other = `0x${"00".repeat(31)}2b` as const;
    await run.deliverAll(pledged(8n, 1_000n, 400n));
    await run.deliver({ source: "LPVault", event: "PositionPledged", args: { positionKey: other, account: PROXY, marketId: 7n, from: WALLET, liquidity: 50n, credit: 30n }, address: V3.lpVault, block: 25n, logIndex: 0 });
    expect(totals(run).sort((a, b) => Number(a[0]) - Number(b[0]))).toEqual([
      [7n, 1, 50n, 30n, 1, 0, 0],
      [8n, 1, 1_000n, 400n, 1, 0, 0],
    ]);
  });

  it("counts a replayed log once", async () => {
    const run = new Run();
    await run.deliverAll([...pledged(8n, 1_000n, 400n), pledged(8n, 1_000n, 400n)[0]!]);
    expect(totals(run)).toEqual([[8n, 1, 1_000n, 400n, 1, 0, 0]]);
  });

  it("stops on a change to a position never pledged", async () => {
    const run = new Run();
    await expect(
      run.deliver({ source: "LPVault", event: "LiquidityRemoved", args: { positionKey: KEY, recipient: WALLET, liquidity: 1n, credit: 1n, amount0: 0n, amount1: 0n }, address: V3.lpVault, block: 5n, logIndex: 0 }),
    ).rejects.toThrow(/before its PositionPledged/);
  });
});

describe("vault-token supply", () => {
  it("adds mints and subtracts burns, from either vault-token source, and ignores transfers between holders", async () => {
    const run = new Run();
    const zero = addr(0);
    const t = (source: string, from: string, to: string, value: bigint, block: bigint): LogSpec => ({ source, event: "Transfer", args: { from, to, value }, address: VAULT, block, logIndex: 0 });
    await run.deliverAll([t("VaultTokenListed", zero, PROXY, 1_000n, 30n), t("VaultToken", zero, PROXY, 1_000n, 30n), t("VaultToken", PROXY, addr(0x102), 300n, 31n), t("VaultToken", addr(0x102), zero, 300n, 32n)]);
    expect(run.store.rows(schema.vaultTokenSupply)).toMatchObject([{ vaultToken: lower(VAULT), supply: 700n, minted: 1_000n, burned: 300n, lastBlock: 32n }]);
  });
});

describe("liquidations and repayments with collateral", () => {
  const liquidated = (block: bigint, logIndex: number): LogSpec => ({
    source: "LiquidationModule",
    event: "Liquidated",
    args: { account: PROXY, marketId: 8n, liquidator: addr(0xf7), debtReserveId: 2n, debtRepaid: 1_000n, seized: 900n, creditUnwound: 800n, amount0: 10n, amount1: 20n },
    address: V3.liquidationModule,
    block,
    logIndex,
  });

  it("records a liquidation with the Avana fee of its FeePaid and the flash figures of its FlashLiquidated", async () => {
    const run = new Run();
    const spec = liquidated(40n, 3);
    await run.deliver(spec);
    // FeePaid and FlashLiquidated are later logs of the same transaction (the harness keys a tx by its first log).
    const tx = run.store.rows(schema.liquidation)[0]!.txHash as `0x${string}`;
    const sameTx = (s: LogSpec) => ({ ...s, block: spec.block });
    await run.deliverIn(tx, sameTx({ source: "LiquidationModule", event: "FeePaid", args: { account: PROXY, marketId: 8n, recipient: addr(0xfe), units: 9n, fee0: 1n, fee1: 2n }, address: V3.liquidationModule, block: 40n, logIndex: 4 }));
    await run.deliverIn(tx, sameTx({ source: "FlashLiquidator", event: "FlashLiquidated", args: { account: PROXY, marketId: 8n, asset: addr(0xac), flashAmount: 1_000n, premium: 0n, debtRepaid: 1_000n, topUp: 5n, profit: 7n }, address: FLASH.v3, block: 40n, logIndex: 5 }));
    expect(run.store.rows(schema.liquidation)).toMatchObject([{ account: lower(PROXY), integrationId: 1, marketId: 8n, debtRepaid: 1_000n, seized: 900n, creditUnwound: 800n, feeUnits: 9n, fee0: 1n, fee1: 2n, flashAmount: 1_000n, topUp: 5n, profit: 7n }]);
  });

  it("matches a FeePaid and a FlashLiquidated to the liquidation of their own integration", async () => {
    const run = new Run();
    const spec = liquidated(40n, 3);
    await run.deliver(spec);
    const tx = run.store.rows(schema.liquidation)[0]!.txHash as `0x${string}`;
    // Integration 3's LiquidationModule and FlashLiquidator name the same account and market ID: not this liquidation.
    const fee = { source: "LiquidationModule", event: "FeePaid", args: { account: PROXY, marketId: 8n, recipient: addr(0xfe), units: 9n, fee0: 1n, fee1: 2n }, address: V4.liquidationModule, block: 40n, logIndex: 4 };
    await expect(run.deliverIn(tx, fee)).rejects.toThrow(/without its Liquidated/);
    const flash = { source: "FlashLiquidator", event: "FlashLiquidated", args: { account: PROXY, marketId: 8n, asset: addr(0xac), flashAmount: 1n, premium: 0n, debtRepaid: 1n, topUp: 0n, profit: 0n }, address: FLASH.v4, block: 40n, logIndex: 5 };
    await expect(run.deliverIn(tx, flash)).rejects.toThrow(/without its Liquidated/);
    await expect(run.deliverIn(tx, { ...flash, address: addr(0xf8), logIndex: 6 })).rejects.toThrow(/not in the manifest/);
  });

  it("refuses a FeePaid without its Liquidated", async () => {
    const run = new Run();
    await expect(run.deliver({ source: "LiquidationModule", event: "FeePaid", args: { account: PROXY, marketId: 8n, recipient: addr(0xfe), units: 9n, fee0: 1n, fee1: 2n }, address: V3.liquidationModule, block: 40n, logIndex: 4 })).rejects.toThrow(/without its Liquidated/);
  });

  it("records a repayment with collateral", async () => {
    const run = new Run();
    await run.deliver({ source: "FlashloanRepay", event: "RepaidWithCollateral", args: { wallet: WALLET, positionKey: KEY, asset: addr(0xac), repaid: 500n, premium: 0n, liquidity: 250n }, address: V3.flashloanRepay, block: 45n, logIndex: 0 });
    expect(run.store.rows(schema.collateralRepay)).toMatchObject([{ wallet: lower(WALLET), positionKey: KEY, repaid: 500n, liquidity: 250n }]);
  });
});

describe("First-Loss Reserves and deficit offsets", () => {
  it("records a reserve's log once when both reserve sources deliver it, and keeps its balance", async () => {
    const run = new Run();
    const reserve = addr(0xf1);
    const funded = (source: string): LogSpec => ({ source, event: "Funded", args: { funder: WALLET, amount: 50n, shares: 50n, balanceAfter: 150n }, address: reserve, block: 40n, logIndex: 0 });
    await run.deliverAll([funded("FirstLossReserveListed"), funded("FirstLossReserve"), funded("DaoDeficitOffset")]);
    expect(run.store.rows(schema.eventLog).map((r) => r.kind)).toEqual(["FirstLossReserve.Funded"]);
    expect(run.store.rows(schema.coverageBalance)).toMatchObject([{ firstLossReserve: lower(reserve), balance: 150n }]);
  });

  it("records each deficit a reserve covers with the balance after it", async () => {
    const run = new Run();
    const reserve = addr(0xf3);
    await run.deliver({ source: "FirstLossReserveListed", event: "DeficitCovered", args: { spoke: SPOKE, caller: addr(0xca), covered: 6n, shares: 6n, balanceAfter: 94n }, address: reserve, block: 12n, logIndex: 0 });
    expect(run.store.rows(schema.firstLossCover)).toMatchObject([{ firstLossReserve: lower(reserve), spoke: lower(SPOKE), covered: 6n, balanceAfter: 94n }]);
    expect(run.store.rows(schema.coverageBalance)).toMatchObject([{ firstLossReserve: lower(reserve), balance: 94n }]);
  });

  it("follows a deficit offset that only the Hub's AddSpoke announced", async () => {
    const run = new Run();
    const offset = addr(0xf2);
    await run.deliver({ source: "DaoDeficitOffset", event: "Funded", args: { funder: addr(0xda0), amount: 9n, shares: 9n, balanceAfter: 9n }, address: offset, block: 41n, logIndex: 0 });
    expect(run.store.rows(schema.coverageBalance)).toMatchObject([{ firstLossReserve: lower(offset), balance: 9n }]);
  });
});

describe("risk premium refresh", () => {
  it("keeps an attributed account's last premium and ignores other users", async () => {
    const run = await listedRun();
    await run.deliverAll([...created(10n, 0), premium(11n, 1, 300n), premium(12n, 0, 450n), premium(12n, 1, 999n, STRANGER)]);
    const rows = run.store.rows(schema.accountPremium);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ proxy: lower(PROXY), riskPremium: 450n, lastBlock: 12n, lastLogIndex: 0 });
  });

  it("marks a collateral-risk change, but not a reserve's first configuration or a change of another field", async () => {
    const run = new Run();
    await run.deliver(reserveConfig(5n, 0, 1_000));
    expect(run.store.rows(schema.reserveConfig)[0]).toMatchObject({ collateralRisk: 1_000, riskChangedBlock: null });
    await run.deliver({ ...reserveConfig(6n, 0, 1_000), args: { reserveId: 1n, config: { collateralRisk: 1_000, paused: true, frozen: false, borrowable: false, receiveSharesEnabled: false } } });
    expect(run.store.rows(schema.reserveConfig)[0]).toMatchObject({ paused: true, riskChangedBlock: null });
    await run.deliver(reserveConfig(8n, 3, 1_500));
    await run.deliver(reserveConfig(8n, 3, 1_500, "AaveSpokeAdded")); // the same log from a second source
    expect(run.store.rows(schema.reserveConfig)[0]).toMatchObject({ collateralRisk: 1_500, riskChangedBlock: 8n, riskChangedLogIndex: 3 });
  });

  it("lists borrowers whose premium predates the last change", () => {
    const change = lastRiskChange([null, { blockNumber: 8n, logIndex: 3 }, { blockNumber: 8n, logIndex: 1 }]);
    expect(change).toEqual({ blockNumber: 8n, logIndex: 3 });
    const list = refreshList(change, [
      { proxy: addr(1), drawnShares: 10n, premiumAt: { blockNumber: 8n, logIndex: 2 } }, // before the change in the same block
      { proxy: addr(2), drawnShares: 10n, premiumAt: { blockNumber: 8n, logIndex: 4 } }, // after it
      { proxy: addr(3), drawnShares: 10n, premiumAt: null }, // never updated
      { proxy: addr(4), drawnShares: 0n, premiumAt: null }, // no debt
    ]);
    expect(list).toEqual([lower(addr(1)), lower(addr(3))]);
    expect(refreshList(null, [{ proxy: addr(3), drawnShares: 10n, premiumAt: null }])).toEqual([]);
  });
});
