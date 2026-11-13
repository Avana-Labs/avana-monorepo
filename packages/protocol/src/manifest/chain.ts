// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Chain reads shared by the manifest producer and the verification: runtime code hashes, ERC-1967 slots, deployment
// blocks from Foundry broadcast files.

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { type Address, type Hex, type PublicClient, getAddress, keccak256 } from "viem";

/** ERC-1967 implementation slot, `bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1)`. */
export const IMPLEMENTATION_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc" as const;
/** ERC-1967 admin slot; Avana has no ProxyAdmin, so it must read zero on every Avana proxy (TEST-137). */
export const ADMIN_SLOT = "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103" as const;

export async function codeHash(client: PublicClient, address: Address): Promise<Hex> {
  const code = await client.getCode({ address });
  if (!code || code === "0x") throw new Error(`no code at ${address}`);
  return keccak256(code);
}

export async function implementationOf(client: PublicClient, proxy: Address): Promise<Address | null> {
  const word = await client.getStorageAt({ address: proxy, slot: IMPLEMENTATION_SLOT });
  if (!word || BigInt(word) === 0n) return null;
  return getAddress(`0x${word.slice(-40)}`);
}

export async function adminOf(client: PublicClient, proxy: Address): Promise<bigint> {
  const word = await client.getStorageAt({ address: proxy, slot: ADMIN_SLOT });
  return word ? BigInt(word) : 0n;
}

/**
 * Deployment block of every contract a Foundry broadcast created on `chainId`, from each script's `run-latest.json`:
 * the transaction's `contractAddress` and every `additionalContracts` entry (contracts created inside the transaction,
 * which is how a CREATE3 deployment through the factory appears), mapped to its receipt's block.
 */
export function broadcastBlocks(contractsDir: string, chainId: number): Map<string, number> {
  const blocks = new Map<string, number>();
  const root = join(contractsDir, "broadcast");
  if (!existsSync(root)) return blocks;
  // Every run of every script, not only run-latest.json: a script run in several steps (07 deploy then fund) or
  // rerun from a saved state keeps its earlier deployments in the timestamped run files.
  const files: string[] = [];
  for (const script of readdirSync(root)) {
    const dir = join(root, script, String(chainId));
    if (!existsSync(dir)) continue;
    for (const f of readdirSync(dir)) if (/^run-.*\.json$/.test(f)) files.push(join(dir, f));
  }
  for (const file of files) {
    const run = JSON.parse(readFileSync(file, "utf8")) as {
      transactions: {
        hash: string;
        transactionType?: string;
        contractAddress?: string | null;
        additionalContracts?: { address: string }[];
      }[];
      receipts: { transactionHash: string; blockNumber: string }[];
    };
    const blockOf = new Map(run.receipts.map((r) => [r.transactionHash.toLowerCase(), Number(BigInt(r.blockNumber))]));
    for (const tx of run.transactions) {
      const b = blockOf.get(tx.hash?.toLowerCase() ?? "");
      if (b === undefined) continue;
      // `contractAddress` is the callee for a CALL, so only a CREATE or CREATE2 transaction names a new contract there.
      const top = tx.transactionType === "CREATE" || tx.transactionType === "CREATE2" ? [tx.contractAddress] : [];
      const created = [...top, ...(tx.additionalContracts ?? []).map((c) => c.address)];
      for (const a of created) {
        if (!a) continue;
        const k = a.toLowerCase();
        blocks.set(k, Math.min(blocks.get(k) ?? b, b));
      }
    }
  }
  return blocks;
}

/** First block at which `address` has code, by binary search (used when no broadcast file names it). */
export async function firstBlockWithCode(client: PublicClient, address: Address): Promise<number> {
  let hi = await client.getBlockNumber();
  let lo = 0n;
  const has = async (b: bigint) => {
    const code = await client.getCode({ address, blockNumber: b });
    return Boolean(code && code !== "0x");
  };
  if (!(await has(hi))) throw new Error(`no code at ${address}`);
  while (lo < hi) {
    const mid = (lo + hi) / 2n;
    if (await has(mid)) hi = mid;
    else lo = mid + 1n;
  }
  return Number(lo);
}

/** Commit of the checkout at `repoRoot`, read from `.git` files (a worktree's `.git` file points at its git dir). */
export function readGitCommit(repoRoot: string): string {
  let gitDir = join(repoRoot, ".git");
  if (!existsSync(gitDir)) throw new Error(`no .git in ${repoRoot}`);
  if (statSync(gitDir).isFile()) {
    const pointer = readFileSync(gitDir, "utf8");
    if (pointer.startsWith("gitdir:")) gitDir = pointer.slice(7).trim();
  }
  const head = readFileSync(join(gitDir, "HEAD"), "utf8").trim();
  if (!head.startsWith("ref:")) return head;
  const ref = head.slice(4).trim();
  const candidates = [join(gitDir, ref)];
  const common = join(gitDir, "commondir");
  if (existsSync(common)) candidates.push(join(gitDir, readFileSync(common, "utf8").trim(), ref));
  for (const c of candidates) if (existsSync(c)) return readFileSync(c, "utf8").trim();
  const packedDirs = [gitDir, ...(existsSync(common) ? [join(gitDir, readFileSync(common, "utf8").trim())] : [])];
  for (const d of packedDirs) {
    const packed = join(d, "packed-refs");
    if (!existsSync(packed)) continue;
    const line = readFileSync(packed, "utf8").split("\n").find((l: string) => l.endsWith(` ${ref}`));
    if (line) return line.split(" ")[0]!;
  }
  throw new Error(`cannot resolve ${ref}`);
}
