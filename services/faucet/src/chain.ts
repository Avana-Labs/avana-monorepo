// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The chain the faucet acts on, and the check that it is a local anvil fork: the reported chain id must be one of
// FAUCET_CHAIN_IDS and the node must answer web3_clientVersion as anvil. Every grant runs the check first, so the faucet
// can never act on a real network, whatever its RPC variables point at. On a test network (Sepolia, Base Sepolia) the
// check is the chain id, and the test tokens are minted by their minter (TestToken.mint), never set by a cheatcode.

import { decodeFunctionResult, encodeAbiParameters, encodeFunctionData, keccak256, parseAbi, parseEther, parseUnits, type Address, type Hex } from "viem";

/** The JSON-RPC the faucet needs: viem's client.request satisfies it. */
export interface Rpc {
  request(args: { method: string; params?: readonly unknown[] }): Promise<unknown>;
}

export class ChainRefused extends Error {}

export async function checkLocalFork(rpc: Rpc, allowedChainIds: readonly number[]): Promise<number> {
  const chainId = Number(BigInt((await rpc.request({ method: "eth_chainId" })) as string));
  if (!allowedChainIds.includes(chainId)) throw new ChainRefused(`chain ${chainId} is not a local fork chain (${allowedChainIds.join(", ")})`);
  const client = String(await rpc.request({ method: "web3_clientVersion" }));
  if (!client.toLowerCase().startsWith("anvil")) throw new ChainRefused(`chain ${chainId} is served by ${client}, not anvil`);
  return chainId;
}

/** Sepolia and Base Sepolia: the only chains a test-network faucet acts on. */
export const TEST_NETWORK_IDS: readonly number[] = [11155111, 84532];

/**
 * The test-network check: the reported chain id must be one of FAUCET_CHAIN_IDS and a public test network (Sepolia,
 * Base Sepolia), so a test-network faucet never sends on another chain, whatever its RPC variables point at.
 */
export async function checkTestNetwork(rpc: Rpc, allowedChainIds: readonly number[]): Promise<number> {
  const chainId = Number(BigInt((await rpc.request({ method: "eth_chainId" })) as string));
  if (!allowedChainIds.includes(chainId) || !TEST_NETWORK_IDS.includes(chainId)) {
    throw new ChainRefused(`chain ${chainId} is not an allowed test network (${allowedChainIds.filter((id) => TEST_NETWORK_IDS.includes(id)).join(", ")})`);
  }
  return chainId;
}

const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)", "function decimals() view returns (uint8)"]);
const testToken = parseAbi(["function MINTER() view returns (address)", "function mint(address to, uint256 amount)"]);

async function call(rpc: Rpc, to: Address, data: Hex): Promise<Hex> {
  return (await rpc.request({ method: "eth_call", params: [{ to, data }, "latest"] })) as Hex;
}

/** The test token's minter (TestToken.MINTER, the world deployer), or null when the token has none. */
export async function tokenMinter(rpc: Rpc, token: Address): Promise<Address | null> {
  try {
    const out = await call(rpc, token, encodeFunctionData({ abi: testToken, functionName: "MINTER" }));
    return decodeFunctionResult({ abi: testToken, functionName: "MINTER", data: out });
  } catch {
    return null;
  }
}

/** Calldata of TestToken.mint(to, amount). */
export const mintData = (to: Address, amount: bigint): Hex => encodeFunctionData({ abi: testToken, functionName: "mint", args: [to, amount] });

export async function tokenDecimals(rpc: Rpc, token: Address): Promise<number> {
  const out = await call(rpc, token, encodeFunctionData({ abi: erc20, functionName: "decimals" }));
  return Number(decodeFunctionResult({ abi: erc20, functionName: "decimals", data: out }));
}

export async function tokenBalance(rpc: Rpc, token: Address, holder: Address): Promise<bigint> {
  const out = await call(rpc, token, encodeFunctionData({ abi: erc20, functionName: "balanceOf", args: [holder] }));
  return decodeFunctionResult({ abi: erc20, functionName: "balanceOf", data: out });
}

/** Sets the wallet's native balance (anvil_setBalance). */
export async function setNativeBalance(rpc: Rpc, wallet: Address, eth: string): Promise<bigint> {
  const wei = parseEther(eth);
  await rpc.request({ method: "anvil_setBalance", params: [wallet, `0x${wei.toString(16)}`] });
  return wei;
}

/** Storage slot of `holder` in a Solidity mapping at `slot`, and the same for Vyper's key order. */
function mappingSlots(holder: Address, slot: number): Hex[] {
  const h = encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [holder, BigInt(slot)]);
  const v = encodeAbiParameters([{ type: "uint256" }, { type: "address" }], [BigInt(slot), holder]);
  return [keccak256(h), keccak256(v)];
}

const word = (value: bigint): Hex => `0x${value.toString(16).padStart(64, "0")}`;

/**
 * Sets the wallet's balance of an ERC-20 to `amount` whole tokens, with anvil_dealERC20 when the node has it, else with
 * a write to the balance slot found by probing the first mapping slots. This is the one place that changes on a test network, where
 * tokens come from a real test faucet instead.
 */
export async function fundToken(rpc: Rpc, token: Address, wallet: Address, amount: string): Promise<bigint> {
  const units = parseUnits(amount, await tokenDecimals(rpc, token));
  try {
    await rpc.request({ method: "anvil_dealERC20", params: [wallet, token, `0x${units.toString(16)}`] });
    if ((await tokenBalance(rpc, token, wallet)) === units) return units;
  } catch {
    // Older anvil without anvil_dealERC20: fall back to the storage write below.
  }
  for (let slot = 0; slot < 64; slot++) {
    for (const key of mappingSlots(wallet, slot)) {
      const before = (await rpc.request({ method: "eth_getStorageAt", params: [token, key, "latest"] })) as Hex;
      await rpc.request({ method: "anvil_setStorageAt", params: [token, key, word(units)] });
      if ((await tokenBalance(rpc, token, wallet)) === units) return units;
      await rpc.request({ method: "anvil_setStorageAt", params: [token, key, before] });
    }
  }
  throw new Error(`no balance slot found for ${token}`);
}
