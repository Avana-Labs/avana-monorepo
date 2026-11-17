// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Live reads pinned to one block. Every decision reads through a ChainReader created for that block, so the
// health factor, prices, gates and sizing of one decision come from the same state. A view read is made once per
// reader: a second ask for the same read at the same block returns the first answer, so the chain loop can issue the
// pass's reads together up front (one batched eth_call through the client, chain/client.ts) and the jobs then read the
// same values as before without another request. Simulations of state-changing calls are never batched or reused.

import { type Address, type Hex, type PublicClient, decodeFunctionResult, encodeFunctionData, keccak256, multicall3Abi, parseAbi } from "viem";
import {
  aaveV4SpokeAbi,
  avanaGasVaultAbi,
  collateralizationAbi,
  debtOracleAbi,
  flashLiquidatorAbi,
  lensAbi,
  lpOracleAbi,
  lpVaultSwapAbi,
  marketRegistryAbi,
} from "@avana/protocol/abis";
import { MULTICALL3_ADDRESS } from "@avana/services-common/chains";

/** ERC-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1). */
export const IMPLEMENTATION_SLOT: Hex = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

/** Accounts per multicall: keeps each eth_call under a node's 50,000,000-gas call limit (services/README.md). */
export const ACCOUNTS_PER_CALL = 300;

const routeAbi = parseAbi(["function tokenOut() view returns (address)", "function dependencies() view returns (address[])"]);
const wrapperAbi = parseAbi(["function asset() view returns (address)", "function aToken() view returns (address)"]);
const v3PoolAbi = parseAbi(["function getReserveAToken(address asset) view returns (address)"]);

const multicall3BalanceAbi = parseAbi(["function getEthBalance(address addr) view returns (uint256 balance)"]);

const aggregatorAbi = parseAbi([
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
]);

/** An LPOracle (`lp`) or a DebtOracle (`debt`); both expose `poke()` and `getPriceState()`. */
export type OracleKind = "lp" | "debt";

/** `poke()` calldata, the same selector on both oracles. */
export const POKE_DATA: Hex = encodeFunctionData({ abi: lpOracleAbi, functionName: "poke" });

export interface AccountData {
  readonly healthFactor: bigint;
  readonly totalCollateralValue: bigint;
  readonly totalDebtValueRay: bigint;
  readonly borrowCount: bigint;
}

export type AccountRef = { readonly spoke: Address; readonly proxy: Address };

export function createChainReader(client: PublicClient, manifest: { avana: { lens: { address: Address }; lpVaultSwap: { address: Address }; marketRegistry: { address: Address }; collateralization: { address: Address } } }, blockNumber: bigint) {
  const at = { blockNumber } as const;
  const lens = manifest.avana.lens.address;
  // One answer per view read at this block; a failed read fails the same way for every caller.
  const memo = new Map<string, Promise<unknown>>();
  const once = <T>(key: string, read: () => Promise<T>): Promise<T> => {
    let p = memo.get(key) as Promise<T> | undefined;
    if (p === undefined) {
      p = read();
      memo.set(key, p);
    }
    return p;
  };

  return {
    blockNumber,

    /** `Spoke.getUserAccountData` for every account, in batches of ACCOUNTS_PER_CALL; a failed entry is absent. */
    async accountData(accounts: readonly AccountRef[]): Promise<Map<Address, AccountData>> {
      const out = new Map<Address, AccountData>();
      for (let i = 0; i < accounts.length; i += ACCOUNTS_PER_CALL) {
        const batch = accounts.slice(i, i + ACCOUNTS_PER_CALL);
        // One eth_call per ACCOUNTS_PER_CALL accounts: that bound is set by gas, not by calldata size.
        const results = await client.multicall({
          ...at,
          allowFailure: true,
          batchSize: 0,
          multicallAddress: MULTICALL3_ADDRESS,
          contracts: batch.map((a) => ({ address: a.spoke, abi: aaveV4SpokeAbi, functionName: "getUserAccountData", args: [a.proxy] }) as const),
        });
        results.forEach((r, j) => {
          if (r.status === "success") out.set(batch[j]!.proxy, r.result as unknown as AccountData);
        });
      }
      return out;
    },

    /** Debt with accrued interest of one reserve, in the debt asset's units. */
    userTotalDebt: (spoke: Address, debtReserveId: bigint, proxy: Address) =>
      once(`userTotalDebt:${spoke}:${debtReserveId}:${proxy}`, () =>
        client.readContract({ ...at, address: spoke, abi: aaveV4SpokeAbi, functionName: "getUserTotalDebt", args: [debtReserveId, proxy] }),
      ),

    priceState: (vaultToken: Address) =>
      once(`priceState:${vaultToken}`, () => client.readContract({ ...at, address: lens, abi: lensAbi, functionName: "getPriceState", args: [vaultToken] })),
    debtPriceState: (spoke: Address, debtReserveId: bigint) =>
      once(`debtPriceState:${spoke}:${debtReserveId}`, () =>
        client.readContract({ ...at, address: lens, abi: lensAbi, functionName: "getDebtPriceState", args: [spoke, debtReserveId] }),
      ),
    previewLiquidation: (proxy: Address, debtReserveId: bigint, deadline: bigint) =>
      client.readContract({ ...at, address: lens, abi: lensAbi, functionName: "previewLiquidation", args: [proxy, debtReserveId, deadline] }),
    breakerStatus: (marketId: bigint) =>
      once(`breakerStatus:${marketId}`, () => client.readContract({ ...at, address: lens, abi: lensAbi, functionName: "getBreakerStatus", args: [marketId] })),
    pendingSettlement: (vaultToken: Address) =>
      once(`pendingSettlement:${vaultToken}`, () =>
        client.readContract({ ...at, address: lens, abi: lensAbi, functionName: "getPendingSettlement", args: [vaultToken] }),
      ),
    pending: (vaultToken: Address) =>
      once(`pending:${vaultToken}`, () =>
        client.readContract({ ...at, address: manifest.avana.collateralization.address, abi: collateralizationAbi, functionName: "getPending", args: [vaultToken] }),
      ),
    settlementReserve: (marketId: bigint) =>
      once(`settlementReserve:${marketId}`, () =>
        client.readContract({ ...at, address: manifest.avana.marketRegistry.address, abi: marketRegistryAbi, functionName: "settlementReserve", args: [marketId] }),
      ),
    /** The CDP Spokes the MarketRegistry approved (`getSpokes`); a manifest Spoke may not be approved yet. */
    approvedSpokes: () =>
      once("approvedSpokes", () => client.readContract({ ...at, address: manifest.avana.marketRegistry.address, abi: marketRegistryAbi, functionName: "getSpokes" })),

    /** Registry and freeze status of this instance's helper (REQ-SWAP-105, Q-404). */
    operatorStatus: (helper: Address) =>
      once(`operatorStatus:${helper}`, async () => {
        const swap = manifest.avana.lpVaultSwap.address;
        const [approved, active, frozen] = await Promise.all([
          client.readContract({ ...at, address: swap, abi: lpVaultSwapAbi, functionName: "isApprovedKeeper", args: [helper] }),
          client.readContract({ ...at, address: swap, abi: lpVaultSwapAbi, functionName: "activeKeeperCount" }),
          client.readContract({ ...at, address: lens, abi: lensAbi, functionName: "isFrozenAddress", args: [helper] }),
        ]);
        return { approved, activeKeeperCount: active, frozen };
      }),

    /** Flash capacity and premium the helper would pay for `amount` of `asset`. */
    async flashQuote(helper: Address, asset: Address, amount: bigint) {
      const [max, premium] = await Promise.all([
        client.readContract({ ...at, address: helper, abi: flashLiquidatorAbi, functionName: "maxFlashLoan", args: [asset] }),
        client.readContract({ ...at, address: helper, abi: flashLiquidatorAbi, functionName: "flashPremium", args: [asset, amount] }),
      ]);
      return { max, premium };
    },

    /**
     * The Aave V3 Pool's aToken of `asset` (null when the Pool cannot say) and the dependencies of every route of
     * `routes` whose output is `asset`, each with what it wraps; failed reads count as nothing wrapped.
     */
    async routeDraws(pool: Address, routes: readonly Address[], asset: Address) {
      const aToken = await client.readContract({ ...at, address: pool, abi: v3PoolAbi, functionName: "getReserveAToken", args: [asset] }).catch(() => null);
      const heads = await client.multicall({
        ...at,
        allowFailure: true,
        multicallAddress: MULTICALL3_ADDRESS,
        contracts: routes.flatMap((r) => [
          { address: r, abi: routeAbi, functionName: "tokenOut" } as const,
          { address: r, abi: routeAbi, functionName: "dependencies" } as const,
        ]),
      });
      const deps: Address[] = [];
      routes.forEach((_, i) => {
        const out = heads[2 * i];
        const d = heads[2 * i + 1];
        // A route whose output cannot be read is checked anyway: assuming it reaches the asset is the safe side.
        const intoAsset = out?.status !== "success" || (out.result as Address).toLowerCase() === asset.toLowerCase();
        if (intoAsset && d?.status === "success") deps.push(...(d.result as readonly Address[]));
      });
      const wraps = await client.multicall({
        ...at,
        allowFailure: true,
        multicallAddress: MULTICALL3_ADDRESS,
        contracts: deps.flatMap((x) => [
          { address: x, abi: wrapperAbi, functionName: "asset" } as const,
          { address: x, abi: wrapperAbi, functionName: "aToken" } as const,
        ]),
      });
      return {
        aToken: aToken as Address | null,
        deps: deps.map((address, i) => ({
          address,
          wraps: [wraps[2 * i], wraps[2 * i + 1]].filter((w) => w?.status === "success").map((w) => w!.result as Address),
        })),
      };
    },

    feedRound: (feed: Address) =>
      once(`feedRound:${feed}`, () => client.readContract({ ...at, address: feed, abi: aggregatorAbi, functionName: "latestRoundData" })),

    /** The oracle's price state at this block (`getPriceState().state`: 0 Live, 1 Drifting, 2 Cached, 3 Expired). */
    oracleState: (oracle: Address, kind: OracleKind): Promise<number> =>
      once(`oracleState:${oracle}:${kind}`, async () => {
        const report = kind === "lp"
          ? await client.readContract({ ...at, address: oracle, abi: lpOracleAbi, functionName: "getPriceState" })
          : await client.readContract({ ...at, address: oracle, abi: debtOracleAbi, functionName: "getPriceState" });
        return Number(report.state);
      }),

    /**
     * The logs `poke()` would emit if sent from `from` on top of this block (`eth_simulateV1`); null when the provider
     * does not answer the method, so the caller falls back to `pokeEffect`. A reverting poke emits nothing: [].
     */
    async simulateLogs(oracle: Address, from: Address): Promise<readonly { readonly address: Address; readonly topics: readonly Hex[] }[] | null> {
      try {
        const [block] = await client.simulateBlocks({ ...at, blocks: [{ calls: [{ to: oracle, data: POKE_DATA, account: from }] }] });
        const call = block?.calls[0];
        if (!call || call.status !== "success") return [];
        return (call.logs ?? []).map((l) => ({ address: l.address, topics: l.topics as readonly Hex[] }));
      } catch {
        return null;
      }
    },

    /**
     * Without `eth_simulateV1`: one `eth_call` of Multicall3 at this block runs `getPriceState()`, `poke()` and
     * `getPriceState()` in order, so the second report reads the storage the poke wrote. Returns both raw reports and
     * whether the poke succeeded; a report the call could not read is null.
     */
    async pokeEffect(oracle: Address): Promise<{ readonly before: Hex | null; readonly after: Hex | null; readonly pokeOk: boolean }> {
      const view = encodeFunctionData({ abi: lpOracleAbi, functionName: "getPriceState" });
      const data = encodeFunctionData({
        abi: multicall3Abi,
        functionName: "aggregate3",
        args: [[{ target: oracle, allowFailure: true, callData: view }, { target: oracle, allowFailure: true, callData: POKE_DATA }, { target: oracle, allowFailure: true, callData: view }]],
      });
      const { data: ret } = await client.call({ ...at, to: MULTICALL3_ADDRESS, data, batch: false });
      if (!ret) return { before: null, after: null, pokeOk: false };
      const [before, poke, after] = decodeFunctionResult({ abi: multicall3Abi, functionName: "aggregate3", data: ret });
      const ok = (r: { success: boolean; returnData: Hex } | undefined) => (r?.success ? r.returnData : null);
      return { before: ok(before), after: ok(after), pokeOk: poke?.success ?? false };
    },

    /**
     * eth_call of a state-changing function at this block (pokeBreakers, pokeConfig): its return, without sending. Never
     * batched: inside one aggregate3 a simulated write would be seen by the calls after it.
     */
    callAt: (to: Address, data: Hex, from?: Address) => client.call({ ...at, to, data, account: from, batch: false }),

    /**
     * The gas vault's view of `signer` at this block (2.24): whether it is listed, its refill trigger, the signer's
     * balance and what `topUp(signer)` would send now and request (0 while paused, not due or capped to 0).
     */
    gasVaultQuote: (vault: Address, signer: Address): Promise<{ listed: boolean; minBalance: bigint; balance: bigint; amount: bigint; requested: bigint; paused: boolean }> =>
      once(`gasVaultQuote:${vault}:${signer}`, async () => {
        const v = { ...at, address: vault, abi: avanaGasVaultAbi } as const;
        // The balance through Multicall3's getEthBalance, so it joins the same batched eth_call as the vault's reads.
        const [listed, config, quote, paused, balance] = await Promise.all([
          client.readContract({ ...v, functionName: "isSigner", args: [signer] }),
          client.readContract({ ...v, functionName: "signerConfig", args: [signer] }),
          client.readContract({ ...v, functionName: "quoteTopUp", args: [signer] }),
          client.readContract({ ...v, functionName: "paused" }),
          client.readContract({ ...at, address: MULTICALL3_ADDRESS, abi: multicall3BalanceAbi, functionName: "getEthBalance", args: [signer] }),
        ]);
        return { listed, minBalance: config.minBalance, balance, amount: quote[0], requested: quote[1], paused };
      }),

    async implementationOf(proxy: Address): Promise<Address> {
      const word = await client.getStorageAt({ ...at, address: proxy, slot: IMPLEMENTATION_SLOT });
      return `0x${(word ?? "0x").slice(-40).padStart(40, "0")}` as Address;
    },

    async codeHashOf(address: Address): Promise<Hex> {
      const code = await client.getCode({ ...at, address });
      return keccak256(code ?? "0x");
    },
  };
}

export type ChainReader = ReturnType<typeof createChainReader>;
