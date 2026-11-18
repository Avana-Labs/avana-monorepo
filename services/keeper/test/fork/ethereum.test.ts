// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Fork tests on Ethereum at a pinned block: the keeper's reads of contracts Avana does not deploy. The Aave V3 Core
// Pool's implementation slot (the code check that switches liquidations to inventory only), its reserves behind flash
// sizing and M-17 (the aToken, idle liquidity and premium the operator helper reads), and Multicall3, through which
// every batched read goes. Not run without RPC_MAINNET.

import { describe, expect, it } from "vitest";
import type { Address } from "viem";
import { createChainReader } from "../../src/chain/reads.ts";
import { fundingPlan } from "../../src/jobs/liquidationRules.ts";
import { m17IdleLevel } from "../../src/monitoring/funding.ts";
import { checkTargets } from "../../src/safety/guards.ts";
import {
  ETHEREUM_BLOCK,
  FORK_TIMEOUT_MS,
  MULTICALL3_CODE_HASH,
  NO_AVANA_MANIFEST,
  RPC_MAINNET,
  blockContext,
  forkClient,
  poolFlashReads,
  premiumOf,
} from "./forkEnv.ts";

const POOL: Address = "0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2";
/** The Pool's implementation at ETHEREUM_BLOCK, and the keccak256 of its runtime code. */
const POOL_IMPLEMENTATION: Address = "0x4295fe69b3e978eb511e4558b4407ad871612fcb";
const POOL_IMPLEMENTATION_CODE_HASH = "0xe334f592d8ff872871487568216f48dfbe98822bbf8c9c2ec55242db3a07028e";
const ACL_MANAGER: Address = "0xc2aaCf6553D20d1e9d78E365AAba8032af9c85b0";
const USDC: Address = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
const A_USDC: Address = "0x98C23E9d8f34FEFb1B7BD6a91B7FF122F4e16F5c";
const GHO: Address = "0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f";
const A_GHO: Address = "0x00907f9921424583e7ffBfEdf84F92B7B2Be4977";
const MULTICALL3: Address = "0xcA11bde05977b3631167028862bE2a173976CA11";
/** Any address that is not a FLASH_BORROWER, standing in for an operator helper. */
const HELPER: Address = "0x00000000000000000000000000000000000a11ce";

describe.skipIf(!RPC_MAINNET)(`fork: Ethereum at block ${ETHEREUM_BLOCK} (not run without RPC_MAINNET)`, { timeout: FORK_TIMEOUT_MS }, () => {
  const client = forkClient(RPC_MAINNET);
  const reader = createChainReader(client, NO_AVANA_MANIFEST, ETHEREUM_BLOCK);
  const ctx = blockContext("mainnet", reader, ETHEREUM_BLOCK, 1_794_500_183n);

  it("reads the pinned block", async () => {
    const block = await client.getBlock({ blockNumber: ETHEREUM_BLOCK });
    expect(block.timestamp).toBe(ctx.blockTimestamp);
  });

  describe("Aave V3 Pool implementation check (flash funding or inventory only)", () => {
    it("reads the Pool's ERC-1967 implementation slot and its implementation's code hash", async () => {
      expect((await reader.implementationOf(POOL)).toLowerCase()).toBe(POOL_IMPLEMENTATION);
      expect(await reader.codeHashOf(POOL_IMPLEMENTATION)).toBe(POOL_IMPLEMENTATION_CODE_HASH);
    });

    it("passes a manifest that records the Pool and Multicall3 as found, and names the mismatch otherwise", async () => {
      const pool = { kind: "upgradeable", address: POOL, implementation: POOL_IMPLEMENTATION } as const;
      const multicall = { kind: "immutable", address: MULTICALL3, codeHash: MULTICALL3_CODE_HASH } as const;
      expect(await checkTargets(ctx, [pool, multicall])).toBeNull();

      const recorded: Address = "0x0000000000000000000000000000000000000001";
      const mismatch = await checkTargets(ctx, [{ ...pool, implementation: recorded }, multicall]);
      expect(mismatch).toEqual({ address: POOL, expected: recorded, found: expect.stringMatching(/^0x[0-9a-f]{40}$/) });
      expect(mismatch!.found.toLowerCase()).toBe(POOL_IMPLEMENTATION);

      const otherCode = await checkTargets(ctx, [{ ...multicall, codeHash: POOL_IMPLEMENTATION_CODE_HASH }]);
      expect(otherCode).toEqual({ address: MULTICALL3, expected: POOL_IMPLEMENTATION_CODE_HASH, found: MULTICALL3_CODE_HASH });
    });
  });

  describe("Aave V3 Pool reserves behind flash sizing and M-17", () => {
    it("routeDraws reads the aToken of each debt asset from the Pool", async () => {
      expect(await reader.routeDraws(POOL, [], USDC)).toEqual({ aToken: A_USDC, deps: [] });
      expect(await reader.routeDraws(POOL, [], GHO)).toEqual({ aToken: A_GHO, deps: [] });
    });

    it("answers every read of the helper's maxFlashLoan and flashPremium for USDC and GHO", async () => {
      const usdc = await poolFlashReads(client, POOL, USDC, HELPER, ETHEREUM_BLOCK);
      expect(usdc).toEqual({ active: true, paused: false, flashEnabled: true, aToken: A_USDC, idle: 155_481_535_954_473n, premiumBps: 5n, aclManager: ACL_MANAGER });
      const gho = await poolFlashReads(client, POOL, GHO, HELPER, ETHEREUM_BLOCK);
      expect(gho).toEqual({ active: true, paused: false, flashEnabled: true, aToken: A_GHO, idle: 34_581_684_418_419_172_046_625_802n, premiumBps: 5n, aclManager: ACL_MANAGER });
    });

    it("sizes a USDC liquidation and judges M-17 idle liquidity from those reads", async () => {
      const { idle, premiumBps } = await poolFlashReads(client, POOL, USDC, HELPER, ETHEREUM_BLOCK);
      const million = 1_000_000n * 10n ** 6n;
      expect(fundingPlan(million, idle, true)).toEqual({ flashAmount: million, inventoryAmount: 0n, inventoryOnly: false });
      expect(premiumOf(million, premiumBps)).toBe(500n * 10n ** 6n);
      // 155.48 million USDC idle: ok against a 50 million largest debtToCover, warn against 100 million, page against 200.
      expect(m17IdleLevel(idle, 50n * million)).toBe("ok");
      expect(m17IdleLevel(idle, 100n * million)).toBe("warn");
      expect(m17IdleLevel(idle, 200n * million)).toBe("page");
    });
  });

  describe("Multicall3 (batched account reads)", () => {
    it("has the expected code, and an entry that fails is left out rather than failing the batch", async () => {
      expect(await reader.codeHashOf(MULTICALL3)).toBe(MULTICALL3_CODE_HASH);
      // USDC is no Spoke: getUserAccountData reverts, so the second-provider check finds no health factor (hfNotConfirmed).
      const data = await reader.accountData([{ spoke: USDC, proxy: HELPER }]);
      expect(data.size).toBe(0);
    });
  });
});
