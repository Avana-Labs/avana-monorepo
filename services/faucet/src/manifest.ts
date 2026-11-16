// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The chain's tokens and USD feeds, from its release manifest's `external` list: group "token" names each token by
// symbol, group "feed" names each feed "<SYMBOL> / USD (primary)" (and alternate, standby…).

import { readFileSync } from "node:fs";
import { decodeFunctionResult, encodeFunctionData, formatUnits, getAddress, parseAbi, type Address, type Hex } from "viem";
import type { Rpc } from "./chain.ts";
import type { TokenGrant, TokenLine } from "./grants.ts";

export interface ExternalEntry {
  readonly group: string;
  readonly name: string;
  readonly address: string;
}

/** The manifest's `external` list; empty when no manifest is given. */
export function loadExternal(path: string | undefined): ExternalEntry[] {
  if (!path) return [];
  const manifest = JSON.parse(readFileSync(path, "utf8")) as { external?: ExternalEntry[] };
  return manifest.external ?? [];
}

const feedAbi = parseAbi([
  "function decimals() view returns (uint8)",
  "function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)",
]);

async function call(rpc: Rpc, to: Address, data: Hex): Promise<Hex> {
  return (await rpc.request({ method: "eth_call", params: [{ to, data }, "latest"] })) as Hex;
}

async function feedDecimals(rpc: Rpc, feed: Address): Promise<number> {
  const data = await call(rpc, feed, encodeFunctionData({ abi: feedAbi, functionName: "decimals" }));
  return decodeFunctionResult({ abi: feedAbi, functionName: "decimals", data });
}

async function feedAnswer(rpc: Rpc, feed: Address): Promise<bigint> {
  const data = await call(rpc, feed, encodeFunctionData({ abi: feedAbi, functionName: "latestRoundData" }));
  return decodeFunctionResult({ abi: feedAbi, functionName: "latestRoundData", data })[1];
}

/** A token line that cannot be resolved, and why. */
export class LineFailed extends Error {}

/**
 * A token line against the manifest: the token's address by symbol, and for a USD line the whole tokens it buys at the
 * primary feed's latest answer (rounded down to 8 decimals). A missing token or feed fails the line, naming it.
 */
export async function resolveLine(rpc: Rpc, external: readonly ExternalEntry[], line: TokenLine): Promise<TokenGrant> {
  const token = external.find((e) => e.group === "token" && e.name.toUpperCase() === line.symbol.toUpperCase());
  if (!token) throw new LineFailed(`no ${line.symbol} token in the manifest`);
  const address = getAddress(token.address);
  if ("amount" in line) return { symbol: line.symbol, address, amount: line.amount };
  const feedName = `${line.symbol} / USD (primary)`;
  const feed = external.find((e) => e.group === "feed" && e.name.toUpperCase() === feedName.toUpperCase());
  if (!feed) throw new LineFailed(`no "${feedName}" feed in the manifest`);
  const [decimals, answer] = await Promise.all([feedDecimals(rpc, getAddress(feed.address)), feedAnswer(rpc, getAddress(feed.address))]);
  if (answer <= 0n) throw new LineFailed(`"${feedName}" has no price`);
  const tokens8 = (BigInt(Math.round(line.usd * 100)) * 10n ** BigInt(decimals) * 10n ** 8n) / (answer * 100n);
  return { symbol: line.symbol, address, amount: formatUnits(tokens8, 8) };
}
