// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Live reads pinned to one block. Every decision reads through a ChainReader created for that block, so the
// health factor, prices, gates and sizing of one decision come from the same state.

import { type Address, type Hex, type PublicClient, keccak256, parseAbi } from "viem";
import {
  aaveV4SpokeAbi,
  collateralizationAbi,
  flashLiquidatorAbi,
  lensAbi,
  lpVaultSwapAbi,
  marketRegistryAbi,
} from "@avana/protocol/abis";

/** ERC-1967 implementation slot: bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1). */
export const IMPLEMENTATION_SLOT: Hex = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

/** Accounts per multicall: keeps each eth_call under a node's 50,000,000-gas call limit (services/README.md). */
export const ACCOUNTS_PER_CALL = 300;

const aggregatorAbi = parseAbi([
  "function latestRoundData() view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)",
]);

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

  return {
    blockNumber,

    /** `Spoke.getUserAccountData` for every account, in batches of ACCOUNTS_PER_CALL; a failed entry is absent. */
    async accountData(accounts: readonly AccountRef[]): Promise<Map<Address, AccountData>> {
      const out = new Map<Address, AccountData>();
      for (let i = 0; i < accounts.length; i += ACCOUNTS_PER_CALL) {
        const batch = accounts.slice(i, i + ACCOUNTS_PER_CALL);
        const results = await client.multicall({
          ...at,
          allowFailure: true,
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
      client.readContract({ ...at, address: spoke, abi: aaveV4SpokeAbi, functionName: "getUserTotalDebt", args: [debtReserveId, proxy] }),

    priceState: (vaultToken: Address) => client.readContract({ ...at, address: lens, abi: lensAbi, functionName: "getPriceState", args: [vaultToken] }),
    debtPriceState: (spoke: Address, debtReserveId: bigint) =>
      client.readContract({ ...at, address: lens, abi: lensAbi, functionName: "getDebtPriceState", args: [spoke, debtReserveId] }),
    previewLiquidation: (proxy: Address, debtReserveId: bigint, deadline: bigint) =>
      client.readContract({ ...at, address: lens, abi: lensAbi, functionName: "previewLiquidation", args: [proxy, debtReserveId, deadline] }),
    breakerStatus: (marketId: bigint) => client.readContract({ ...at, address: lens, abi: lensAbi, functionName: "getBreakerStatus", args: [marketId] }),
    pendingSettlement: (vaultToken: Address) =>
      client.readContract({ ...at, address: lens, abi: lensAbi, functionName: "getPendingSettlement", args: [vaultToken] }),
    pending: (vaultToken: Address) =>
      client.readContract({ ...at, address: manifest.avana.collateralization.address, abi: collateralizationAbi, functionName: "getPending", args: [vaultToken] }),
    settlementReserve: (marketId: bigint) =>
      client.readContract({ ...at, address: manifest.avana.marketRegistry.address, abi: marketRegistryAbi, functionName: "settlementReserve", args: [marketId] }),

    /** Registry and freeze status of this instance's helper (REQ-SWAP-105, Q-404). */
    async operatorStatus(helper: Address) {
      const swap = manifest.avana.lpVaultSwap.address;
      const [approved, active, frozen] = await Promise.all([
        client.readContract({ ...at, address: swap, abi: lpVaultSwapAbi, functionName: "isApprovedKeeper", args: [helper] }),
        client.readContract({ ...at, address: swap, abi: lpVaultSwapAbi, functionName: "activeKeeperCount" }),
        client.readContract({ ...at, address: lens, abi: lensAbi, functionName: "isFrozenAddress", args: [helper] }),
      ]);
      return { approved, activeKeeperCount: active, frozen };
    },

    /** Flash capacity and premium the helper would pay for `amount` of `asset`. */
    async flashQuote(helper: Address, asset: Address, amount: bigint) {
      const [max, premium] = await Promise.all([
        client.readContract({ ...at, address: helper, abi: flashLiquidatorAbi, functionName: "maxFlashLoan", args: [asset] }),
        client.readContract({ ...at, address: helper, abi: flashLiquidatorAbi, functionName: "flashPremium", args: [asset, amount] }),
      ]);
      return { max, premium };
    },

    feedRound: (feed: Address) => client.readContract({ ...at, address: feed, abi: aggregatorAbi, functionName: "latestRoundData" }),

    /** eth_call of a state-changing function at this block (pokeBreakers, pokeConfig): its return, without sending. */
    callAt: (to: Address, data: Hex, from?: Address) => client.call({ ...at, to, data, account: from }),

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
