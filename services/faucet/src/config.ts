// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Configuration from the environment (.env.example lists every name).

import { listEnv, optionalEnv } from "@avana/services-common";
import type { ChainName } from "./grants.ts";
import type { ChainKind } from "./setup.ts";

export interface FaucetConfig {
  readonly host: string;
  readonly port: number;
  readonly dataDir: string;
  /** "fork" on the local chains; "testnet" (not built yet) on Sepolia. */
  readonly kind: ChainKind;
  /** Chain ids the faucet accepts; any other chain is refused. */
  readonly chainIds: readonly number[];
  readonly rpc: Readonly<Partial<Record<ChainName, string>>>;
}

export function loadConfig(env: NodeJS.ProcessEnv): FaucetConfig {
  const kind = optionalEnv(env, "FAUCET_CHAIN_KIND") ?? "fork";
  if (kind !== "fork" && kind !== "testnet") throw new Error(`FAUCET_CHAIN_KIND must be fork or testnet, not ${kind}`);
  const chainIds = (listEnv(env, "FAUCET_CHAIN_IDS").length > 0 ? listEnv(env, "FAUCET_CHAIN_IDS") : ["31337", "31338"]).map(Number);
  if (chainIds.some((id) => !Number.isSafeInteger(id) || id <= 0)) throw new Error("FAUCET_CHAIN_IDS must be chain ids");
  if (chainIds.includes(1) || chainIds.includes(8453)) throw new Error("FAUCET_CHAIN_IDS must not include Ethereum or Base mainnet");
  const rpc: Partial<Record<ChainName, string>> = {};
  const ethereum = optionalEnv(env, "FAUCET_RPC_ETHEREUM");
  const base = optionalEnv(env, "FAUCET_RPC_BASE");
  if (ethereum) rpc.ethereum = ethereum;
  if (base) rpc.base = base;
  if (!rpc.ethereum && !rpc.base) throw new Error("set FAUCET_RPC_ETHEREUM and/or FAUCET_RPC_BASE");
  const host = optionalEnv(env, "FAUCET_HOST") ?? "127.0.0.1";
  if (host !== "127.0.0.1" && host !== "localhost") throw new Error("the faucet listens on 127.0.0.1 only");
  return {
    host,
    port: Number(optionalEnv(env, "FAUCET_PORT") ?? "42080"),
    dataDir: optionalEnv(env, "FAUCET_DATA_DIR") ?? ".faucet",
    kind,
    chainIds,
    rpc,
  };
}
