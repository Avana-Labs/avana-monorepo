// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Environment reads shared by the services. Names follow services/README.md (Keeper > Configuration):
// RPC_<CHAIN> for the primary endpoint and RPC_<CHAIN>_<ROLE> for each extra endpoint of the same chain.

import type { ChainInfo } from "./chains.ts";

export type RpcRole = "PRIMARY" | "FALLBACK" | "WS" | "PRIVATE";

export function rpcEnvName(chain: ChainInfo, role: RpcRole): string {
  return role === "PRIMARY" ? `RPC_${chain.envSuffix}` : `RPC_${chain.envSuffix}_${role}`;
}

/** Reads a required variable; a missing or empty value stops the process at startup. */
export function requireEnv(env: NodeJS.ProcessEnv, name: string): string {
  const value = env[name];
  if (value === undefined || value.trim() === "") throw new Error(`missing environment variable ${name}`);
  return value.trim();
}

export function optionalEnv(env: NodeJS.ProcessEnv, name: string): string | undefined {
  const value = env[name]?.trim();
  return value === undefined || value === "" ? undefined : value;
}

/** Comma-separated list, empty entries dropped (RPC_<CHAIN>_PRIVATE may name several builder endpoints). */
export function listEnv(env: NodeJS.ProcessEnv, name: string): string[] {
  return (optionalEnv(env, name) ?? "").split(",").map((s) => s.trim()).filter((s) => s !== "");
}

export function intEnv(env: NodeJS.ProcessEnv, name: string): number {
  const raw = requireEnv(env, name);
  if (!/^\d+$/.test(raw)) throw new Error(`${name} must be a non-negative integer`);
  return Number(raw);
}
