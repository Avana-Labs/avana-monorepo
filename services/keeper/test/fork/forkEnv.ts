// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Shared setup of the fork tests: the RPC endpoints (RPC_MAINNET, RPC_BASE; .env.example), the pinned blocks every
// assertion is read at, and the Aave V3 Pool reads the operator helper makes for the keeper. A pin changes only by a
// reviewed edit of this file, together with the values the suites expect at it. The endpoints must serve archive state.

import { type Address, type PublicClient, createPublicClient, http, parseAbi } from "viem";
import { CHAINS, type ServiceManifest } from "@avana/services-common";
import type { ChainReader } from "../../src/chain/reads.ts";
import type { ChainConfig } from "../../src/config.ts";
import type { BlockContext } from "../../src/types.ts";

export const RPC_MAINNET = process.env.RPC_MAINNET?.trim() ?? "";
export const RPC_BASE = process.env.RPC_BASE?.trim() ?? "";

/** Ethereum block 26,400,000 (2026-11-12 16:16:23 UTC). */
export const ETHEREUM_BLOCK = 26_400_000n;
/** Base block 57,500,000 (2026-11-14 21:06:15 UTC). */
export const BASE_BLOCK = 57_500_000n;

/** Per-test timeout: a cold archive read can take several seconds. */
export const FORK_TIMEOUT_MS = 60_000;

/**
 * A client of the endpoint. vitest collects a skipped suite's body too, so an unset endpoint gets a placeholder URL
 * that nothing calls.
 */
export function forkClient(url: string): PublicClient {
  return createPublicClient({ transport: http(url || "http://not-configured.invalid", { retryCount: 3, timeout: 20_000 }) }) as PublicClient;
}

/** A client whose `readContract` is pinned to `blockNumber`, for keeper functions that read at `latest`. */
export function pinnedReads(client: PublicClient, blockNumber: bigint): Pick<PublicClient, "readContract"> {
  return { readContract: ((args: Parameters<PublicClient["readContract"]>[0]) => client.readContract({ ...args, blockNumber })) as PublicClient["readContract"] };
}

/** The reader needs Avana addresses only for Avana reads, which these suites do not make. */
const NO_AVANA = "0x000000000000000000000000000000000000dEaD" as Address;
export const NO_AVANA_MANIFEST = {
  avana: { lens: { address: NO_AVANA }, lpVaultSwap: { address: NO_AVANA }, marketRegistry: { address: NO_AVANA }, collateralization: { address: NO_AVANA } },
};

export function blockContext(chain: keyof typeof CHAINS, reader: ChainReader, blockNumber: bigint, blockTimestamp: bigint): BlockContext {
  return { config: { chain: CHAINS[chain], manifest: {} as ServiceManifest } as ChainConfig, blockNumber, blockTimestamp, reader };
}

/** Multicall3, at the same address with the same code on every chain the keeper runs on. */
export const MULTICALL3_CODE_HASH = "0xd5c15df687b16f2ff992fc8d767b4216323184a2bbc6ee2f9c398c318e770891";

const poolAbi = parseAbi([
  "function getConfiguration(address asset) view returns ((uint256 data))",
  "function getReserveAToken(address asset) view returns (address)",
  "function getVirtualUnderlyingBalance(address asset) view returns (uint128)",
  "function FLASHLOAN_PREMIUM_TOTAL() view returns (uint128)",
  "function ADDRESSES_PROVIDER() view returns (address)",
]);
const providerAbi = parseAbi(["function getACLManager() view returns (address)"]);
const aclAbi = parseAbi(["function isFlashBorrower(address borrower) view returns (bool)"]);
const erc20Abi = parseAbi(["function balanceOf(address owner) view returns (uint256)"]);

/**
 * The Pool reads behind the helper's `maxFlashLoan` (idle liquidity, M-17 and the flash/inventory split) and
 * `flashPremium` (the premium bound), as contracts/src/flash/AaveV3FlashSource.sol makes them: the reserve's active,
 * paused and flash-enabled bits, its aToken, min(aToken's balance, the virtual balance), and the premium rate unless the
 * borrower is a FLASH_BORROWER.
 */
export async function poolFlashReads(client: PublicClient, pool: Address, asset: Address, borrower: Address, blockNumber: bigint) {
  const at = { blockNumber } as const;
  const [{ data }, aToken, virtual, premiumBps, provider] = await Promise.all([
    client.readContract({ ...at, address: pool, abi: poolAbi, functionName: "getConfiguration", args: [asset] }),
    client.readContract({ ...at, address: pool, abi: poolAbi, functionName: "getReserveAToken", args: [asset] }),
    client.readContract({ ...at, address: pool, abi: poolAbi, functionName: "getVirtualUnderlyingBalance", args: [asset] }),
    client.readContract({ ...at, address: pool, abi: poolAbi, functionName: "FLASHLOAN_PREMIUM_TOTAL" }),
    client.readContract({ ...at, address: pool, abi: poolAbi, functionName: "ADDRESSES_PROVIDER" }),
  ]);
  const aclManager = await client.readContract({ ...at, address: provider, abi: providerAbi, functionName: "getACLManager" });
  const [held, waived] = await Promise.all([
    client.readContract({ ...at, address: asset, abi: erc20Abi, functionName: "balanceOf", args: [aToken] }),
    client.readContract({ ...at, address: aclManager, abi: aclAbi, functionName: "isFlashBorrower", args: [borrower] }),
  ]);
  const bit = (n: bigint) => ((data >> n) & 1n) === 1n;
  return {
    active: bit(56n),
    paused: bit(60n),
    flashEnabled: bit(63n),
    aToken,
    idle: held < virtual ? held : virtual,
    premiumBps: waived ? 0n : premiumBps,
    aclManager,
  };
}

/** The helper's premium: ⌈amount × rate / 10,000⌉. */
export const premiumOf = (amount: bigint, rateBps: bigint) => (amount * rateBps + 9_999n) / 10_000n;
