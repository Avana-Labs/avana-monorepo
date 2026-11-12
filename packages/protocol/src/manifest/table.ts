// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The public contract table of a final deployment (deployments/<network>/README.md): every contract the manifest
// names, Avana's and the third parties', with its address, proxy and implementation, runtime code hash and explorer
// link, so anyone can check the deployment against the chain.

import type { External, Immutable, ReleaseManifest, Upgradeable } from "./types.ts";

/** Explorer base URL per network; a Tenderly Virtual TestNet passes its own with `--explorer`. */
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
  const upg = (group: string, name: string, u: Upgradeable) => {
    rows.push({ group, name, address: u.address, kind: `ERC-1967 proxy → ${u.implementation}`, codeHash: u.codeHash });
    rows.push({ group, name: `${name} implementation`, address: u.implementation, kind: "implementation", codeHash: u.implementationCodeHash });
    for (const l of u.logics) rows.push({ group, name: `${name} · ${l.name}`, address: l.address, kind: "logic (delegatecall target)", codeHash: l.codeHash });
  };
  const a = m.avana;
  upg("Avana", "AaveAdapter", a.aaveAdapter);
  upg("Avana", "LPVaultSwap", a.lpVaultSwap);
  upg("Avana", "MarketRegistry", a.marketRegistry);
  upg("Avana", "ParameterStore", a.parameterStore);
  upg("Avana", "RiskModule", a.riskModule);
  imm("Avana", "AvanaTimelock", a.timelock);
  imm("Avana", "Lock", a.lock);
  imm("Avana", "Collateralization", a.collateralization);
  imm("Avana", "VaultTokenFactory", a.vaultTokenFactory);
  imm("Avana", "ProxyManager", a.proxyManager);
  imm("Avana", "PayoutEscrow", a.payoutEscrow);
  imm("Avana", "AaveV3FlashSource", a.flashSource);
  imm("Avana", "FlashLiquidator", a.flashLiquidator);
  a.operatorHelpers.forEach((h, i) => imm("Avana", `OperatorFlashLiquidator ${i} (signer ${h.signer})`, h));
  a.lpVaults.forEach((v) => imm("Avana", `LPVault ${v.integrationId} (${v.kind})`, v));
  a.coverageSpokes.forEach((c) => imm("Avana", `Coverage Spoke (${c.asset})`, c));
  imm("Avana", "Lens", a.lens);
  a.lensModules.forEach((x, i) => imm("Avana", `Lens module ${i}`, x));
  imm("Avana", "LensAaveSizing", a.lensAaveSizing);
  imm("Avana", "DebtOracle implementation", a.debtOracleImplementation);
  if (a.clOraclePricing) imm("Avana", "LPOracleCL implementation", a.clOraclePricing);
  for (const mk of m.markets) {
    imm("Avana markets", `Vault token, market ${mk.marketId}`, mk.vaultToken);
    upg("Avana markets", `LPOracle, market ${mk.marketId}`, mk.lpOracle);
    mk.routes.forEach((r, i) => imm("Avana markets", `Swap route ${i}, market ${mk.marketId}`, r));
  }
  for (const d of m.debtReserves) if (d.debtOracle) upg("Avana markets", `DebtOracle ${d.asset}`, d.debtOracle);
  const groupName: Record<string, string> = {
    "aave-v4": "Aave V4",
    "aave-v3": "Aave V3",
    "uniswap-v3": "Uniswap v3",
    slipstream: "Aerodrome Slipstream",
    token: "Tokens",
    feed: "Price feeds",
    safe: "Safes",
  };
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
