// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Scenario runner of the local rehearsal: scripted actors against the deployment of contracts/deployments-local/<network>
// (anvil with --auto-impersonate, so every actor sends unlocked). Each scenario ends pass, fail or not-run; a not-run
// names the missing piece (for example no listed market while the concentrated-liquidity LPOracle has not landed).
// Results: deployments-local/<network>/scenarios.json. Every fail is also appended, with its numbers, to the findings
// file named by E2E_FINDINGS when it is set (an internal research file, outside the repository).
//
// Usage, from contracts/:  node script/e2e/scenarios/run.ts --network anvil [--only <name>]

import { appendFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { type Address, type Hex, encodeFunctionData, keccak256, parseAbi, stringToBytes } from "viem";
import {
  ACTORS,
  type Outcome,
  type Result,
  type Scenario,
  aave,
  client,
  config,
  ctx,
  arg,
  manifest,
  network,
  out,
  read,
  send,
  wallet,
  world,
} from "./context.ts";
import { marketScenarios } from "./market.ts";
import { OCR2_ABI, transmit } from "./ocr2.ts";

const only = arg("only");

const ERC20 = parseAbi([
  "function mint(address,uint256)",
  "function approve(address,uint256) returns (bool)",
  "function balanceOf(address) view returns (uint256)",
]);
const SPOKE = parseAbi([
  "function getReserveId(address hub, uint256 assetId) view returns (uint256)",
  "function supply(uint256 reserveId, uint256 amount, address onBehalfOf) returns (uint256, uint256)",
  "function withdraw(uint256 reserveId, uint256 amount, address onBehalfOf) returns (uint256, uint256)",
]);
const HUB = parseAbi([
  "function getAssetId(address underlying) view returns (uint256)",
  "function getAddedAssets(uint256 assetId) view returns (uint256)",
  "function getAddedShares(uint256 assetId) view returns (uint256)",
  "function getAssetLiquidity(uint256 assetId) view returns (uint256)",
]);
const REGISTRY = parseAbi([
  "function pause(address hub, uint8 reason)",
  "function unpause(address hub)",
  "function freeze(address hub)",
  "function unfreeze(address hub)",
  "function pauseState(address hub) view returns (uint8)",
  "function isRecordedHub(address) view returns (bool)",
  "function getHubs() view returns (address[])",
  "function hasRole(bytes32 role, address account) view returns (bool)",
  "function grantRole(bytes32 role, address account)",
]);
const TIMELOCK = parseAbi([
  "function scheduleBatch(address[] targets, uint256[] values, bytes[] payloads, bytes32 predecessor, bytes32 salt, uint256 delay)",
  "function cancel(bytes32 id)",
  "function hashOperationBatch(address[] targets, uint256[] values, bytes[] payloads, bytes32 predecessor, bytes32 salt) pure returns (bytes32)",
  "function isOperationPending(bytes32 id) view returns (bool)",
]);

const hubs = (manifest.aave.hubs as { address: Address; label: string }[]) ?? [];
const registry = manifest.avana.marketRegistry.address as Address;
const timelock = manifest.avana.timelock.address as Address;

const scenarios: Scenario[] = [
  {
    name: "lender supplies and withdraws on every Lend Spoke (Aave V4 shares = assets)",
    async run() {
      const numbers: Record<string, string> = {};
      const assets = config.aavePayload?.debtAssets ?? [];
      if (!aave.spokes || assets.length === 0) return { ok: false, detail: "no Aave payload executed (06_AaveDeploymentPayload)" };
      for (const h of config.aavePayload.hubs) {
        const hub = aave.hubs[h.label].proxy as Address;
        const lend = aave.spokes[h.lendSpoke].proxy as Address;
        for (const a of assets) {
          // An asset with `hubs` is only on those Hubs (06_AaveDeploymentPayload).
          if (a.hubs && !a.hubs.includes(h.label)) continue;
          const token = world.tokens[a.symbol] as Address;
          const assetId = await read(hub, HUB, "getAssetId", [token]);
          const reserveId = await read(lend, SPOKE, "getReserveId", [hub, assetId]);
          const amount = 1_000_000n * 10n ** BigInt(a.decimals);
          const before = (await read(hub, HUB, "getAddedAssets", [assetId])) as bigint;
          const steps = [
            await send(ACTORS.deployer!, token, ERC20, "mint", [ACTORS.lender, amount]),
            await send(ACTORS.lender!, token, ERC20, "approve", [lend, amount]),
            await send(ACTORS.lender!, lend, SPOKE, "supply", [reserveId, amount, ACTORS.lender]),
          ];
          const after = (await read(hub, HUB, "getAddedAssets", [assetId])) as bigint;
          // withdraw(amount) right after supply(amount) returns the whole amount; withdraw(max) is the fallback check.
          const exact = await send(ACTORS.lender!, lend, SPOKE, "withdraw", [reserveId, amount, ACTORS.lender]);
          const balBefore = (await read(token, ERC20, "balanceOf", [ACTORS.lender])) as bigint;
          const w = exact.ok ? exact : await send(ACTORS.lender!, lend, SPOKE, "withdraw", [reserveId, 2n ** 256n - 1n, ACTORS.lender]);
          const bal = (await read(token, ERC20, "balanceOf", [ACTORS.lender])) as bigint;
          const got = bal - balBefore + (exact.ok ? amount : 0n);
          numbers[`${h.label}.${a.symbol}`] =
            `added ${before} -> ${after}; withdraw(amount) ${exact.ok ? "ok" : exact.error.slice(0, 60)}; withdraw(max) ${w.ok ? "ok" : w.error}; received ${got} of ${amount}`;
          if (!steps.every((s) => s.ok) || !w.ok || after - before !== amount || got + 1n < amount) {
            return { ok: false, detail: `${h.label} ${a.symbol}: ${steps.map((s) => s.error).join(" ")} ${w.error}`, numbers };
          }
        }
      }
      return { ok: true, detail: `${Object.keys(numbers).length} (Hub, asset) pairs`, numbers };
    },
  },
  {
    name: "guardians pause and unpause each Avana Hub; an attacker cannot",
    async run() {
      if (hubs.length === 0) return { ok: false, detail: "no Hub in the manifest" };
      const numbers: Record<string, string> = {};
      for (const h of hubs) {
        const recorded = await read(registry, REGISTRY, "isRecordedHub", [h.address]);
        const bad = await send(ACTORS.attacker!, registry, REGISTRY, "pause", [h.address, 1]);
        const p = await send(ACTORS.emergencyGuardian!, registry, REGISTRY, "pause", [h.address, 1]);
        const s1 = await read(registry, REGISTRY, "pauseState", [h.address]);
        const u = await send(ACTORS.aaveProtocolGuardian!, registry, REGISTRY, "unpause", [h.address]);
        const s2 = await read(registry, REGISTRY, "pauseState", [h.address]);
        numbers[h.label] = `recorded ${recorded}; attacker ${bad.ok ? "SUCCEEDED" : "reverted"}; pause ${p.ok} state ${s1}; unpause ${u.ok} state ${s2}`;
        if (bad.ok || !p.ok || !u.ok || Number(s1) !== 2 || Number(s2) !== 0) return { ok: false, detail: `${h.label}: ${p.error} ${u.error}`, numbers };
      }
      return { ok: true, detail: `${hubs.length} Hubs`, numbers };
    },
  },
  {
    name: "a role grant through the timelock can be cancelled only by the Aave governance executor",
    async run() {
      const role = keccak256(stringToBytes("APPLICATION_PAUSE_GUARDIAN"));
      const payload = encodeFunctionData({ abi: REGISTRY, functionName: "grantRole", args: [role, ACTORS.attacker!] });
      const salt = keccak256(stringToBytes(`scenario.role-grant.${Date.now()}`)) as Hex;
      const args = [[registry], [0n], [payload], `0x${"00".repeat(32)}`, salt] as const;
      const s = await send(ACTORS.governanceSafe!, timelock, TIMELOCK, "scheduleBatch", [...args, 432_000n]);
      const id = await read(timelock, TIMELOCK, "hashOperationBatch", args);
      const byGuardian = await send(ACTORS.emergencyGuardian!, timelock, TIMELOCK, "cancel", [id]);
      const byDao = await send(ACTORS.aaveExecutor!, timelock, TIMELOCK, "cancel", [id]);
      const pending = await read(timelock, TIMELOCK, "isOperationPending", [id]);
      const numbers = { schedule: String(s.ok), guardianCancel: byGuardian.ok ? "SUCCEEDED" : "reverted", daoCancel: String(byDao.ok), pendingAfter: String(pending) };
      return { ok: s.ok && !byGuardian.ok && byDao.ok && !pending, detail: `${s.error} ${byDao.error}`.trim(), numbers };
    },
  },
  {
    name: "a Chainlink OCR2 feed moves only by a signed report; round ID and updatedAt follow, then age",
    async run() {
      const feeds = world.feeds?.WETH as Record<string, Address> | undefined;
      if (!feeds?.primaryAggregator) return { ok: false, detail: "no OCR2 feed in world.json" };
      const proxy = feeds.primary!;
      const before = (await read(proxy, OCR2_ABI, "latestRoundData")) as readonly [bigint, bigint, bigint, bigint, bigint];
      const crash = (before[1] * 4n) / 10n; // a 60 % crash
      const hash = await transmit(client, wallet, feeds.primaryAggregator, crash);
      const r = await client.waitForTransactionReceipt({ hash });
      const after = (await read(proxy, OCR2_ABI, "latestRoundData")) as readonly [bigint, bigint, bigint, bigint, bigint];
      await client.request({ method: "evm_increaseTime" as any, params: [90_000] as any });
      await client.request({ method: "evm_mine" as any, params: [] as any });
      const aged = (await read(proxy, OCR2_ABI, "latestRoundData")) as readonly [bigint, bigint, bigint, bigint, bigint];
      const now = (await client.getBlock()).timestamp;
      const numbers = {
        before: `round ${before[0]} answer ${before[1]} updatedAt ${before[3]}`,
        after: `round ${after[0]} answer ${after[1]} updatedAt ${after[3]} (transmit gas ${r.gasUsed})`,
        aged: `round ${aged[0]} age ${now - aged[3]} s`,
      };
      const ok = r.status === "success" && after[1] === crash && after[0] === before[0] + 1n && aged[3] === after[3] && now - aged[3] >= 90_000n;
      return { ok, detail: ok ? "WETH/USD primary: -60 % by report, then 25 h stale" : "unexpected round data", numbers };
    },
  },
  // The seven market scenarios (market.ts), each with `needs: "market"`.
  ...marketScenarios(ctx),
];

async function main() {
  // Every scripted actor gets 1,000 ETH for gas (anvil's balance RPC; nothing else changes state).
  for (const a of Object.values(ACTORS)) {
    await client.request({ method: "anvil_setBalance" as any, params: [a, "0x3635C9ADC5DEA00000"] as any }).catch(() => undefined);
  }
  const results: Result[] = [];
  const marketsListed = (manifest.markets as unknown[]).length > 0;
  for (const s of scenarios) {
    if (only && !s.name.includes(only)) continue;
    if (s.needs === "market" && !marketsListed) {
      results.push({
        name: s.name,
        outcome: "not-run",
        detail: manifest.avana.clOraclePricing
          ? "no market listed in the manifest"
          : "no market can be listed: the concentrated-liquidity LPOracle (LPOracleCL) is not in this build",
      });
      continue;
    }
    try {
      const r = await s.run();
      results.push({ name: s.name, outcome: r.ok ? "pass" : "fail", detail: r.detail, ...(r.numbers ? { numbers: r.numbers } : {}) });
    } catch (e) {
      results.push({ name: s.name, outcome: "fail", detail: (e as Error).message.split("\n")[0]! });
    }
  }
  writeFileSync(join(out, "scenarios.json"), `${JSON.stringify(results, null, 2)}\n`);
  const findings = process.env.E2E_FINDINGS;
  for (const r of results) {
    process.stdout.write(`${r.outcome.toUpperCase().padEnd(8)} ${r.name}${r.detail ? ` — ${r.detail}` : ""}\n`);
    if (r.numbers) for (const [k, v] of Object.entries(r.numbers)) process.stdout.write(`           ${k}: ${v}\n`);
    if (findings && r.outcome === "fail") {
      appendFileSync(findings, `\n### ${new Date().toISOString()} ${network}: ${r.name}\n\n- Outcome: fail — ${r.detail}\n${Object.entries(r.numbers ?? {}).map(([k, v]) => `- ${k}: ${v}`).join("\n")}\n`);
    }
  }
  const n = (o: Outcome) => results.filter((r) => r.outcome === o).length;
  process.stdout.write(`\n${n("pass")} passed, ${n("fail")} failed, ${n("not-run")} not run\n`);
  if (n("fail") > 0) process.exitCode = 1;
}

main().catch((e: unknown) => {
  process.stderr.write(`${(e as Error).message}\n`);
  process.exit(1);
});
