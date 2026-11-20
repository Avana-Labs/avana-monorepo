// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The public contract table of a final deployment (deployments/<network>/README.md): every contract the manifest
// names, Avana's and the third parties', with its address, proxy target for a third-party proxy, runtime code hash and explorer
// link, so anyone can check the deployment against the chain.

import type { External, Immutable, ReleaseManifest } from "./types.ts";

/** Explorer base URL per network; `--explorer` overrides it. */
export const EXPLORERS: Readonly<Record<string, string>> = {
  ethereum: "https://etherscan.io",
  base: "https://basescan.org",
  sepolia: "https://sepolia.etherscan.io",
  "base-sepolia": "https://sepolia.basescan.org",
};

interface Row {
  readonly group: string;
  readonly name: string;
  readonly address: string;
  readonly kind: string;
  readonly codeHash: string;
}

export function contractTable(m: ReleaseManifest, explorer: string | undefined = EXPLORERS[m.network]): string {
  const rows: Row[] = [];
  const imm = (group: string, name: string, x: Immutable) => rows.push({ group, name, address: x.address, kind: "immutable", codeHash: x.codeHash });
  const a = m.avana;
  imm("Avana", "AccessManager", a.accessManager);
  for (const x of a.integrations) {
    const g = `Avana integration ${x.integrationId} (${x.kind})`;
    imm(g, "LPVault", x.lpVault);
    imm(g, "RiskModule", x.riskModule);
    imm(g, "LiquidationModule", x.liquidationModule);
    imm(g, "AaveAdapter", x.aaveAdapter);
    imm(g, "FlashloanRepay", x.flashloanRepay);
    a.flashLiquidators.filter((f) => f.integrationId === x.integrationId).forEach((f) => imm(g, `FlashLiquidator (operator ${f.operator})`, f));
  }
  for (const mk of m.markets) {
    imm("Avana markets", `Vault token, market ${mk.marketId} (${mk.name})`, mk.vaultToken);
    imm("Avana markets", `LPOracle, market ${mk.marketId} (${mk.name})`, mk.lpOracle);
  }
  m.coverage.firstLossReserves.forEach((c) => imm("Coverage", `First-Loss Reserve ${c.hubLabel} ${c.symbol}`, c));
  m.coverage.daoDeficitOffsets.forEach((c) => imm("Coverage", `Aave DAO deficit offset ${c.hubLabel} ${c.symbol}`, c));
  const groupName: Record<string, string> = {
    "aave-v4": "Aave V4",
    "aave-v3": "Aave V3",
    "uniswap-v3": "Uniswap v3",
    "uniswap-v4": "Uniswap v4",
    slipstream: "Aerodrome Slipstream",
    token: "Tokens",
    feed: "Price feeds",
    safe: "Safes",
  };
  const pm = m.uniswapV4?.poolManager;
  if (pm && !m.external.some((e) => e.address.toLowerCase() === pm.address.toLowerCase())) imm("Uniswap v4", "PoolManager", pm);
  for (const e of m.external as External[]) {
    rows.push({
      group: groupName[e.group] ?? e.group,
      name: e.standIn ? `${e.name} (test-network stand-in)` : e.name,
      address: e.address,
      kind: e.implementation ? `ERC-1967 proxy → ${e.implementation}` : "contract",
      codeHash: e.codeHash,
    });
  }
  const link = (addr: string) => (explorer ? `[${addr}](${explorer}/address/${addr})` : `\`${addr}\``);
  const lines = [
    `# Avana ${m.release} on ${m.network}`,
    "",
    `Chain ID ${m.chainId}, commit \`${m.commit}\`, ABI hash \`${m.abiHash}\`. Generated from the release manifest by`,
    "`npm run manifest -- table`; every row can be checked with `cast codehash <address>` against the code hash column.",
    "",
  ];
  let current = "";
  for (const r of rows) {
    if (r.group !== current) {
      current = r.group;
      lines.push("", `## ${current}`, "", "| Contract | Address | Kind | Runtime code hash |", "|---|---|---|---|");
    }
    lines.push(`| ${r.name} | ${link(r.address)} | ${r.kind} | \`${r.codeHash}\` |`);
  }
  return `${lines.join("\n")}\n`;
}
