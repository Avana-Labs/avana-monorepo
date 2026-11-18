// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Fork tests on Base at a pinned block: the keeper's reads of contracts Avana does not deploy. The L1 data fee from
// the OP Stack GasPriceOracle (the fee ceiling's worst-case cost), the Aave V3 Pool's implementation slot and reserves
// behind flash sizing and M-17, and the second-provider health-factor
// read against a live Aave V4 Spoke (Spoke.getUserAccountData through Multicall3). Not run without RPC_BASE.

import { describe, expect, it } from "vitest";
import { type Address, type Hex, concat, keccak256, maxUint256, toHex } from "viem";
import { CHAINS } from "@avana/services-common";
import { GAS_PRICE_ORACLE, type UnsignedTx, aboveCeiling, l1DataFee, paysL1DataFee, worstCaseCost } from "../../src/chain/gas.ts";
import { createChainReader } from "../../src/chain/reads.ts";
import { checkTargets } from "../../src/safety/guards.ts";
import {
  BASE_BLOCK,
  FORK_TIMEOUT_MS,
  MULTICALL3_CODE_HASH,
  NO_AVANA_MANIFEST,
  RPC_BASE,
  blockContext,
  forkClient,
  pinnedReads,
  poolFlashReads,
} from "./forkEnv.ts";

const POOL: Address = "0xA238Dd80C259a72e81d7e4664a9801593F98d1c5";
/** The Pool's implementation at BASE_BLOCK, and the keccak256 of its runtime code. */
const POOL_IMPLEMENTATION: Address = "0xf248dd0adb01e78043e8a423b8504c8129f11918";
const POOL_IMPLEMENTATION_CODE_HASH = "0xa4d2855cd851dc69a5bef2dfc99504ab6b101f29c5353a4b043eece444780771";
const ACL_MANAGER: Address = "0x43955b0899Ab7232E3a454cf84AedD22Ad46FD33";
const USDC: Address = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";
const A_USDC: Address = "0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB";
const MULTICALL3: Address = "0xcA11bde05977b3631167028862bE2a173976CA11";
/** The tokenized-equities Spoke of Aave V4's equities Hub on Base (EXT-031), and one of its borrowers at BASE_BLOCK. */
const V4_SPOKE: Address = "0x17905Db0e4A3514467539956c084180616AE7B8D";
const V4_BORROWER: Address = "0x9a29e286bf6597552b7fc3b984c78b3875f05d00";
const NO_POSITION: Address = "0x000000000000000000000000000000000000dEaD";
const HELPER: Address = "0x00000000000000000000000000000000000a11ce";
const WAD = 10n ** 18n;
/** GasPriceOracle.getL1Fee of tx(1_000) at BASE_BLOCK, in wei. */
const L1_FEE_1000_BYTES = 208_546_082_872n;

/**
 * An unsigned transaction as the Submitter prices it before signing, with `dataBytes` of calldata that does not
 * compress (a keccak chain): since Fjord the fee follows the estimated compressed size, with a floor of 100 bytes.
 */
const tx = (dataBytes: number): UnsignedTx => ({
  chainId: CHAINS.base.id,
  to: HELPER,
  data: concat(Array.from({ length: Math.ceil(dataBytes / 32) }, (_, i) => keccak256(toHex(i)))).slice(0, 2 + 2 * dataBytes) as Hex,
  nonce: 42,
  gas: 2_000_000n,
  maxFeePerGas: 20_000_000n,
  maxPriorityFeePerGas: 1_000_000n,
});

describe.skipIf(!RPC_BASE)(`fork: Base at block ${BASE_BLOCK} (not run without RPC_BASE)`, { timeout: FORK_TIMEOUT_MS }, () => {
  const client = forkClient(RPC_BASE);
  const reader = createChainReader(client, NO_AVANA_MANIFEST, BASE_BLOCK);
  const ctx = blockContext("base", reader, BASE_BLOCK, 1_794_690_375n);

  it("reads the pinned block", async () => {
    const block = await client.getBlock({ blockNumber: BASE_BLOCK });
    expect(block.timestamp).toBe(ctx.blockTimestamp);
  });

  describe("L1 data fee (GasPriceOracle.getL1Fee)", () => {
    it("is charged on Base and read from the predeploy", async () => {
      expect(paysL1DataFee(CHAINS.base)).toBe(true);
      expect(paysL1DataFee(CHAINS.mainnet)).toBe(false);
      expect(await client.getCode({ address: GAS_PRICE_ORACLE, blockNumber: BASE_BLOCK })).toMatch(/^0x[0-9a-f]{2,}$/);
    });

    it("prices the serialized transaction at the block, in proportion to its calldata", async () => {
      const pinned = pinnedReads(client, BASE_BLOCK);
      const fee = await l1DataFee(pinned, tx(1_000));
      expect(fee).toBe(L1_FEE_1000_BYTES);
      expect(await l1DataFee(pinned, tx(4_000))).toBeGreaterThan(3n * fee);
    });

    it("adds the L1 data fee to the worst-case cost the fee ceiling is checked against", async () => {
      const t = tx(1_000);
      const fee = await l1DataFee(pinnedReads(client, BASE_BLOCK), t);
      const cost = worstCaseCost(t.gas, t.maxFeePerGas, fee);
      expect(cost).toBe(t.gas * t.maxFeePerGas + L1_FEE_1000_BYTES);
      expect(aboveCeiling(cost, t.gas * t.maxFeePerGas)).toBe(true);
      expect(aboveCeiling(cost, cost)).toBe(false);
    });
  });

  describe("Aave V3 Pool implementation check and reserves", () => {
    it("reads the Pool's implementation slot and passes a manifest that records it", async () => {
      expect((await reader.implementationOf(POOL)).toLowerCase()).toBe(POOL_IMPLEMENTATION);
      expect(await reader.codeHashOf(POOL_IMPLEMENTATION)).toBe(POOL_IMPLEMENTATION_CODE_HASH);
      const targets = [
        { kind: "upgradeable", address: POOL, implementation: POOL_IMPLEMENTATION },
        { kind: "immutable", address: MULTICALL3, codeHash: MULTICALL3_CODE_HASH },
      ] as const;
      expect(await checkTargets(ctx, targets)).toBeNull();
    });

    it("reads USDC's aToken, idle liquidity and premium as the helper does", async () => {
      expect(await reader.routeDraws(POOL, [], USDC)).toEqual({ aToken: A_USDC, deps: [] });
      expect(await poolFlashReads(client, POOL, USDC, HELPER, BASE_BLOCK)).toEqual({
        active: true,
        paused: false,
        flashEnabled: true,
        aToken: A_USDC,
        idle: 16_931_332_612_700n,
        premiumBps: 5n,
        aclManager: ACL_MANAGER,
      });
    });
  });

  describe("second-provider health factor (Aave V4 Spoke.getUserAccountData)", () => {
    it("decodes a live V4 account and leaves out an entry that fails", async () => {
      const data = await reader.accountData([
        { spoke: V4_SPOKE, proxy: V4_BORROWER },
        { spoke: V4_SPOKE, proxy: NO_POSITION },
        { spoke: USDC, proxy: NO_POSITION },
      ]);
      expect(data.get(V4_BORROWER)).toMatchObject({ healthFactor: 1_923_716_170_952_891_326n, totalCollateralValue: 980_024_548_443_979_305_550_000_000_000n, borrowCount: 1n });
      expect(data.get(NO_POSITION)).toMatchObject({ healthFactor: maxUint256, totalCollateralValue: 0n, borrowCount: 0n });
      // The USDC entry reverted and is absent; the NO_POSITION key holds the Spoke's answer.
      expect(data.size).toBe(2);
    });

    it("does not confirm a liquidation of an account the second provider reads at HF ≥ 1", async () => {
      // chainLoop's confirm: the fallback's read at the decision block must be below 1e18.
      const hf = (await createChainReader(client, NO_AVANA_MANIFEST, BASE_BLOCK).accountData([{ spoke: V4_SPOKE, proxy: V4_BORROWER }])).get(V4_BORROWER)?.healthFactor;
      expect(hf !== undefined && hf < WAD).toBe(false);
    });
  });
});
