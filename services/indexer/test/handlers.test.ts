// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The handlers on scripted logs (test/harness): account attribution needs both creation events, Spoke debt moves only
// for attributed accounts and only once when two sources deliver the same log, every log writes its event_log row and
// the parties it names, custody and collateral records follow their events, and the risk premium and collateral-risk
// rows behind the refresh list.

import { describe, expect, it } from "vitest";
import schema from "ponder:schema";
import { type LogSpec, Run, addr } from "./harness/run.ts";
import { lastRiskChange, refreshList } from "../src/lib/premiumRefresh.ts";

const ADAPTER = addr(0xa0);
const MANAGER = addr(0xa1);
const SPOKE = addr(0xb0);
const WALLET = addr(0xc0);
const PROXY = addr(0xc1);
const STRANGER = addr(0xc2);
const VAULT = addr(0xd0);

const created = (block: bigint, logIndex: number): LogSpec[] => [
  { source: "AaveAdapter", event: "UserProxyCreated", args: { wallet: WALLET, spoke: SPOKE, marketId: 7n, proxy: PROXY }, address: ADAPTER, block, logIndex },
  { source: "ProxyManager", event: "ProxyDeployed", args: { wallet: WALLET, spoke: SPOKE, marketId: 7n, proxy: PROXY }, address: MANAGER, block, logIndex: logIndex + 1 },
];

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

const lower = (a: string) => a.toLowerCase();

describe("account attribution and debt", () => {
  it("attributes an account once both creation events agree, and moves its drawn shares", async () => {
    const run = new Run();
    await run.deliverAll([...created(10n, 0), borrow(11n, 0), repay(12n, 0, 400n)]);
    const [account] = run.store.rows(schema.account);
    expect(account).toMatchObject({ wallet: lower(WALLET), proxy: lower(PROXY), adapterSeen: true, managerSeen: true, marketId: 7n, createdBlock: 10n });
    const [debt] = run.store.rows(schema.accountDebt);
    expect(debt).toMatchObject({ debtReserveId: 2n, drawnShares: 600n, deficitReported: false, lastBlock: 12n });
  });

  it("moves debt once when two sources deliver the same Spoke log", async () => {
    const run = new Run();
    await run.deliverAll([...created(10n, 0), borrow(11n, 0, PROXY, 1_000n, "AaveSpoke"), borrow(11n, 0, PROXY, 1_000n, "AaveSpokeAdded"), borrow(11n, 0, PROXY, 1_000n, "AaveSpokeApproved")]);
    expect(run.store.rows(schema.accountDebt)[0]!.drawnShares).toBe(1_000n);
    expect(run.store.rows(schema.eventLog).filter((r) => r.kind === "AaveSpoke.Borrow")).toHaveLength(1);
  });

  it("keeps the debt of an address that no creation event announced out of the account tables", async () => {
    const run = new Run();
    await run.deliverAll([...created(10n, 0), borrow(11n, 0, STRANGER)]);
    expect(run.store.rows(schema.accountDebt)).toEqual([]);
    expect(run.store.rows(schema.eventLog).map((r) => r.kind)).toContain("AaveSpoke.Borrow");
  });

  it("refuses creation events that name different wallets for one proxy", async () => {
    const run = new Run();
    await run.deliver(created(10n, 0)[0]!);
    await expect(run.deliver({ ...created(10n, 0)[1]!, args: { wallet: STRANGER, spoke: SPOKE, marketId: 7n, proxy: PROXY } })).rejects.toThrow(/disagree/);
  });

  it("writes one log_party row per address a log names", async () => {
    const run = new Run();
    await run.deliverAll([...created(10n, 0), borrow(11n, 0)]);
    const parties = run.store.rows(schema.logParty).filter((r) => r.blockNumber === 11n).map((r) => r.party).sort();
    expect(parties).toEqual([lower(ADAPTER), lower(PROXY)].sort());
  });
});

describe("custody", () => {
  const KEY = `0x${"00".repeat(31)}2a` as const;
  const LP_VAULT = addr(0xe0);

  it("holds a received position until it is returned", async () => {
    const run = new Run();
    await run.deliver({ source: "LPVault", event: "PositionReceived", args: { positionKey: KEY, marketId: 7n, depositor: WALLET, units: 5n }, address: LP_VAULT, block: 20n, logIndex: 0 });
    expect(run.store.rows(schema.lpPosition)[0]).toMatchObject({ held: true, stray: false, depositor: lower(WALLET) });
    await run.deliver({ source: "LPVault", event: "PositionReturned", args: { positionKey: KEY, depositor: WALLET }, address: LP_VAULT, block: 21n, logIndex: 0 });
    expect(run.store.rows(schema.lpPosition)[0]).toMatchObject({ held: false, lastBlock: 21n });
  });

  it("tracks seized units waiting for settlement", async () => {
    const run = new Run();
    const C = addr(0xe1);
    await run.deliver({ source: "Collateralization", event: "SeizureReconciled", args: { proxy: PROXY, vaultToken: VAULT, units: 9n, amounts: [1n, 2n] }, address: C, block: 30n, logIndex: 0 });
    await run.deliver({ source: "Collateralization", event: "PendingSettled", args: { vaultToken: VAULT, units: 4n, amounts: [1n, 0n] }, address: C, block: 31n, logIndex: 0 });
    expect(run.store.rows(schema.pendingSettlement)[0]).toMatchObject({ units: 5n, lastBlock: 31n });
  });
});

describe("First-Loss Reserves and deficit offsets", () => {
  it("records a reserve's log once when both reserve sources deliver it, and keeps its balance", async () => {
    const run = new Run();
    const reserve = addr(0xf1);
    const funded = (source: string): LogSpec => ({ source, event: "ReserveFunded", args: { funder: WALLET, amount: 50n, shares: 50n, balanceAfter: 150n }, address: reserve, block: 40n, logIndex: 0 });
    await run.deliverAll([funded("AvanaFirstLossReserveListed"), funded("AvanaFirstLossReserve"), funded("DaoDeficitOffset")]);
    expect(run.store.rows(schema.eventLog).map((r) => r.kind)).toEqual(["AvanaFirstLossReserve.ReserveFunded"]);
    expect(run.store.rows(schema.coverageBalance)).toMatchObject([{ firstLossReserve: lower(reserve), balance: 150n }]);
  });

  it("records the funding of a manifest reserve before the MarketRegistry sets it", async () => {
    const run = new Run();
    const reserve = addr(0xf3);
    await run.deliver({ source: "AvanaFirstLossReserveListed", event: "ReserveFunded", args: { funder: WALLET, amount: 6n, shares: 6n, balanceAfter: 6n }, address: reserve, block: 12n, logIndex: 0 });
    expect(run.store.rows(schema.eventLog).map((r) => r.kind)).toEqual(["AvanaFirstLossReserve.ReserveFunded"]);
    expect(run.store.rows(schema.coverageBalance)).toMatchObject([{ firstLossReserve: lower(reserve), balance: 6n }]);
  });

  it("follows a deficit offset that only the Hub's AddSpoke announced", async () => {
    const run = new Run();
    const offset = addr(0xf2);
    await run.deliver({ source: "DaoDeficitOffset", event: "ReserveFunded", args: { funder: addr(0xda0), amount: 9n, shares: 9n, balanceAfter: 9n }, address: offset, block: 41n, logIndex: 0 });
    expect(run.store.rows(schema.coverageBalance)).toMatchObject([{ firstLossReserve: lower(offset), balance: 9n }]);
  });
});

describe("risk premium refresh", () => {
  it("keeps an attributed account's last premium and ignores other users", async () => {
    const run = new Run();
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
