// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Intents and SIWE sessions in Convex: only the signed-in wallet records and reads its intents, a hash is recorded
// once, no calldata field exists; a revoked or expired session ends access before the Convex JWT does; the session
// mutations refuse a caller without the server secret. The secret is generated at run time.

import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import schema from "../../convex/schema";
import { api, internal } from "../../convex/_generated/api";

const modules = import.meta.glob("../../convex/**/*.*s");
const WALLET = "0x00000000000000000000000000000000000000a1";
const OTHER = "0x00000000000000000000000000000000000000b2";
const TX = `0x${"ab".repeat(32)}`;
const SID = "c".repeat(64);
let secret = "";

beforeEach(() => {
  secret = [...crypto.getRandomValues(new Uint8Array(32))].map((b) => b.toString(16).padStart(2, "0")).join("");
  vi.stubEnv("CONVEX_SESSION_SECRET", secret);
});
afterEach(() => vi.unstubAllEnvs());

async function served(t: ReturnType<typeof convexTest>) {
  await t.mutation(internal.deployments.setDeployment, {
    chainId: 1,
    lens: OTHER,
    hubs: [{ address: OTHER, label: "Stable LP Hub", tier: 1 }],
    lendSpokes: [OTHER],
    cdpSpokes: [],
    firstLossReserves: [],
    marketRegistry: OTHER,
    timelock: OTHER,
    explorerUrl: "https://etherscan.io",
    nativeUsdFeed: OTHER,
    release: "v1.0.0",
  });
}

describe("intents", () => {
  test("the signed-in wallet records a hash once and reads it with its explorer link", async () => {
    const t = convexTest(schema, modules);
    await served(t);
    const me = t.withIdentity({ subject: WALLET });
    const first = await me.mutation(api.intents.submit, { wallet: WALLET, chainId: 1, txHash: TX.toUpperCase().replace("0X", "0x"), kind: "borrow", page: { scope: "pool", slug: "eth-usdc-usdt" } });
    const again = await me.mutation(api.intents.submit, { wallet: WALLET, chainId: 1, txHash: TX, kind: "borrow" });
    expect(again.id).toBe(first.id);
    const rows = await me.query(api.intents.listForWallet, { wallet: WALLET });
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ txHash: TX, status: "pending", final: false, href: `https://etherscan.io/tx/${TX}` });
    expect(Object.keys(rows[0]!)).not.toContain("calldata");
  });

  test("refuses another wallet, unknown kinds, malformed hashes and unserved chains", async () => {
    const t = convexTest(schema, modules);
    await served(t);
    const me = t.withIdentity({ subject: WALLET });
    await expect(me.mutation(api.intents.submit, { wallet: OTHER, chainId: 1, txHash: TX, kind: "borrow" })).rejects.toThrow(/WALLET_MISMATCH/);
    await expect(me.mutation(api.intents.submit, { wallet: WALLET, chainId: 1, txHash: TX, kind: "transfer-all" })).rejects.toThrow(/unknown kind/);
    await expect(me.mutation(api.intents.submit, { wallet: WALLET, chainId: 1, txHash: "0x12", kind: "borrow" })).rejects.toThrow(/32-byte/);
    await expect(me.mutation(api.intents.submit, { wallet: WALLET, chainId: 8453, txHash: TX, kind: "borrow" })).rejects.toThrow(/not served/);
    await me.mutation(api.intents.submit, { wallet: WALLET, chainId: 1, txHash: TX, kind: "borrow" });
    await expect(t.withIdentity({ subject: OTHER }).mutation(api.intents.submit, { wallet: OTHER, chainId: 1, txHash: TX, kind: "borrow" })).rejects.toThrow(/another wallet/);
  });
});

describe("SIWE sessions", () => {
  const future = () => Date.now() + 60 * 60 * 1000;

  test("refuse callers without the server secret", async () => {
    const t = convexTest(schema, modules);
    await expect(t.mutation(api.siweSessions.open, { secret: "wrong", sessionId: SID, wallet: WALLET, expiresAt: future() })).rejects.toThrow(/UNAUTHORIZED/);
    vi.stubEnv("CONVEX_SESSION_SECRET", "");
    await expect(t.mutation(api.siweSessions.open, { secret: "", sessionId: SID, wallet: WALLET, expiresAt: future() })).rejects.toThrow(/UNAUTHORIZED/);
  });

  test("a JWT naming a session works while it is open and stops after logout", async () => {
    const t = convexTest(schema, modules);
    await served(t);
    expect(await t.mutation(api.siweSessions.open, { secret, sessionId: SID, wallet: WALLET, expiresAt: future() })).toEqual({ opened: true });
    const me = t.withIdentity({ subject: WALLET, sid: SID } as never);
    expect(await me.query(api.intents.listForWallet, { wallet: WALLET })).toEqual([]);
    expect(await t.mutation(api.siweSessions.revoke, { secret, sessionId: SID })).toEqual({ revoked: true });
    await expect(me.query(api.intents.listForWallet, { wallet: WALLET })).rejects.toThrow(/SESSION_ENDED/);
    expect(await t.query(api.siweSessions.status, { secret, sessionId: SID })).toMatchObject({ active: false, wallet: WALLET });
  });

  test("sign out everywhere revokes every open session, and bounds are enforced", async () => {
    const t = convexTest(schema, modules);
    for (const sid of ["d".repeat(64), "e".repeat(64)]) await t.mutation(api.siweSessions.open, { secret, sessionId: sid, wallet: WALLET, expiresAt: future() });
    expect(await t.mutation(api.siweSessions.revokeWallet, { secret, wallet: WALLET })).toEqual({ revoked: 2 });
    await expect(t.mutation(api.siweSessions.open, { secret, sessionId: "F".repeat(64), wallet: WALLET, expiresAt: future() })).rejects.toThrow(/SHA-256/);
    await expect(t.mutation(api.siweSessions.open, { secret, sessionId: SID, wallet: WALLET, expiresAt: Date.now() + 8 * 24 * 60 * 60 * 1000 })).rejects.toThrow(/7 days/);
    await t.mutation(api.siweSessions.open, { secret, sessionId: SID, wallet: WALLET, expiresAt: future() });
    await expect(t.mutation(api.siweSessions.open, { secret, sessionId: SID, wallet: OTHER, expiresAt: future() })).rejects.toThrow(/another wallet/);
  });
});
