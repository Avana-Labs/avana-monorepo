// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The narrow chain surface the bot uses: viem's public and wallet client methods, so tests can stand in for a node.

import type { Abi, Address, Hash, Hex } from "viem";

export interface ReadCall {
  readonly address: Address;
  readonly abi: Abi;
  readonly functionName: string;
  readonly args?: readonly unknown[];
}

export interface WriteCall extends ReadCall {
  readonly account: Address;
}

export interface Chain {
  getBlockNumber(): Promise<bigint>;
  getAccountCreatedLogs(adapter: Address, fromBlock: bigint, toBlock: bigint): Promise<readonly { account: Address; marketId: bigint }[]>;
  read<T>(call: ReadCall): Promise<T>;
  /** Simulates the call from `account` and returns its result; throws on a revert. */
  simulate<T>(call: WriteCall): Promise<T>;
  /** Sends the call and waits for its receipt; throws on a revert. */
  send(call: WriteCall): Promise<Hash>;
}

export type { Hex };
