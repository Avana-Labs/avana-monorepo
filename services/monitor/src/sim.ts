// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Simulates a route swap at the latest block with `eth_call` state overrides, as LPVaultSwap would make it inside a
// liquidation, without a fork: LPVaultSwap is given the input tokens and the route's allowance by writing the token's
// balance and allowance slots, and the Lock's code is replaced by a stub whose `holder()` answers LPVaultSwap (the
// real Lock keeps its holder in transient storage, which an override cannot set). Nothing is sent.

import { type Address, type Hex, decodeFunctionResult, encodeAbiParameters, encodeFunctionData, keccak256, numberToHex, parseAbi } from "viem";
import type { Override, RawRpc } from "./probe.ts";

const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)", "function allowance(address, address) view returns (uint256)"]);
const routeAbi = parseAbi(["function swap(uint256 amountIn, uint256 minOut) returns (uint256 amountOut)"]);

/** OpenZeppelin v5's ERC-7201 ERC20 storage: `_balances` at the base, `_allowances` one slot after. */
const OZ_ERC20_BASE = 0x52c63247e1f47db19d5ce0460030c497f067ca4cebf71ba98eeadabe20bace00n;
const CANDIDATES: readonly bigint[] = [...Array.from({ length: 64 }, (_, i) => BigInt(i)), OZ_ERC20_BASE, OZ_ERC20_BASE + 1n];
const MAGIC = 0x5ec0_7a11_c0ffeen;

const word = (x: bigint) => numberToHex(x, { size: 32 });
const pair = (a: Hex, b: Hex) => keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }], [a, b]));
const addr = (a: Address) => word(BigInt(a));

/** Where a token keeps `balanceOf(holder)` and `allowance(owner, spender)`: the mapping's slot and the key order. */
export interface TokenSlots {
  readonly balance: { readonly slot: bigint; readonly keyFirst: boolean };
  readonly allowance: { readonly slot: bigint; readonly keyFirst: boolean };
}

/** Solidity hashes `keccak(key . slot)` (key first); Vyper `keccak(slot . key)`. */
const mapSlot = (slot: bigint, key: Hex, keyFirst: boolean) => (keyFirst ? pair(key, word(slot)) : pair(word(slot), key));
export const balanceSlot = (s: TokenSlots, holder: Address) => mapSlot(s.balance.slot, addr(holder), s.balance.keyFirst);
export const allowanceSlot = (s: TokenSlots, owner: Address, spender: Address) => mapSlot(BigInt(mapSlot(s.allowance.slot, addr(owner), s.allowance.keyFirst)), addr(spender), s.allowance.keyFirst);

/** The Lock stand-in: answers every call with `who`, ABI-encoded (PUSH20 who, MSTORE at 0, RETURN 32 bytes). */
export const lockStub = (who: Address): Hex => `0x73${who.slice(2).toLowerCase()}60005260206000f3`;

async function reads(rpc: RawRpc, from: Address, token: Address, data: Hex, override: Override): Promise<bigint | null> {
  const r = await rpc.call(from, token, data, [override]);
  return r.ok && r.data.length >= 66 ? BigInt(r.data.slice(0, 66)) : null;
}

/** Finds the token's balance and allowance slots by writing a marker and reading it back; null if none matches. */
export async function findSlots(rpc: RawRpc, token: Address, probe: Address): Promise<TokenSlots | null> {
  const spender = "0x000000000000000000000000000000000000beef" as Address;
  let balance: TokenSlots["balance"] | null = null;
  for (const slot of CANDIDATES) {
    for (const keyFirst of [true, false]) {
      const s = mapSlot(slot, addr(probe), keyFirst);
      const v = await reads(rpc, probe, token, encodeFunctionData({ abi: erc20, functionName: "balanceOf", args: [probe] }), { address: token, stateDiff: [{ slot: s, value: word(MAGIC) }] });
      if (v === MAGIC) balance = { slot, keyFirst };
      if (balance) break;
    }
    if (balance) break;
  }
  if (!balance) return null;
  for (const slot of CANDIDATES) {
    for (const keyFirst of [true, false]) {
      const s = allowanceSlot({ balance, allowance: { slot, keyFirst } }, probe, spender);
      const v = await reads(rpc, probe, token, encodeFunctionData({ abi: erc20, functionName: "allowance", args: [probe, spender] }), { address: token, stateDiff: [{ slot: s, value: word(MAGIC) }] });
      if (v === MAGIC) return { balance, allowance: { slot, keyFirst } };
    }
  }
  return null;
}

export interface SwapSetup {
  readonly lpVaultSwap: Address;
  readonly lock: Address;
  readonly route: Address;
  readonly token: Address;
  readonly slots: TokenSlots;
}

export type SwapOutcome = { readonly ok: true; readonly amountOut: bigint } | { readonly ok: false; readonly error: string };

/** One simulated `route.swap(amountIn, 1)` from LPVaultSwap holding exactly `amountIn` of the token. */
export async function simulateSwap(rpc: RawRpc, s: SwapSetup, amountIn: bigint): Promise<SwapOutcome> {
  const overrides: Override[] = [
    { address: s.lock, code: lockStub(s.lpVaultSwap) },
    {
      address: s.token,
      stateDiff: [
        { slot: balanceSlot(s.slots, s.lpVaultSwap), value: word(amountIn) },
        { slot: allowanceSlot(s.slots, s.lpVaultSwap, s.route), value: word(amountIn) },
      ],
    },
  ];
  const r = await rpc.call(s.lpVaultSwap, s.route, encodeFunctionData({ abi: routeAbi, functionName: "swap", args: [amountIn, 1n] }), overrides);
  if (!r.ok) return r;
  return { ok: true, amountOut: decodeFunctionResult({ abi: routeAbi, functionName: "swap", data: r.data }) };
}
