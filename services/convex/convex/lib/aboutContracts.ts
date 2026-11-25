// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The About card's four contract slots per page, as the app labels them: Vault, Token, Risk Manager and Oracle
// Router. Each slot shows the contract's short address and links to the explorer of the page's chain. A slot whose
// address the deployment does not name yet is left out.

import type { HubAssetRow, MarketRow, SpokeReserveRow } from "@avana/services-common/views";
import { explorerLinks } from "./explorer.ts";
import type { ContractAddressRow, PageScope } from "./uiTypes.ts";

export const ABOUT_SLOTS = ["vault", "token", "riskManager", "oracleRouter"] as const;
export type AboutSlot = (typeof ABOUT_SLOTS)[number];

/** The deployment fields the About card reads; the optional ones come from the release manifest. */
export interface AboutDeployment {
  readonly explorerUrl: string;
  /** `avana.lpVaults[]`: the LPVault of each integration. */
  readonly lpVaults?: readonly { readonly integrationId: number; readonly address: string }[];
  /** `avana.riskModule`. */
  readonly riskModule?: string;
  /** Each Aave V4 Spoke's oracle (`ISpoke.ORACLE()`). */
  readonly spokeOracles?: readonly { readonly spoke: string; readonly oracle: string }[];
}

const shortAddress = (a: string) => `${a.slice(0, 6)}...${a.slice(-4)}`;

/**
 * The slots of a page:
 * - pool: Vault = the market's LPVault, Token = its vault token, Risk Manager = the RiskModule, Oracle Router = its LP oracle;
 * - Borrow asset: Vault = the Hub, Token = the debt asset, Risk Manager = the CDP Spoke, Oracle Router = that Spoke's oracle;
 * - Lend: Vault = the Hub, Token = the underlying, Risk Manager = its Lend Spoke, Oracle Router = that Spoke's oracle.
 */
export function aboutContractRows(
  scope: PageScope,
  slug: string,
  chain: string,
  row: HubAssetRow | SpokeReserveRow | MarketRow,
  dep: AboutDeployment | null,
): ContractAddressRow[] {
  const oracleOf = (spoke: string | undefined) => (spoke ? dep?.spokeOracles?.find((o) => o.spoke === spoke)?.oracle : undefined);
  let slots: Record<AboutSlot, string | undefined>;
  if (scope === "pool") {
    const m = row as MarketRow;
    slots = {
      vault: dep?.lpVaults?.find((v) => v.integrationId === m.integrationId)?.address,
      token: m.vaultToken,
      riskManager: dep?.riskModule,
      oracleRouter: m.lpOracle,
    };
  } else if (scope === "asset") {
    const r = row as SpokeReserveRow;
    slots = { vault: r.hub, token: r.asset, riskManager: r.spoke, oracleRouter: oracleOf(r.spoke) };
  } else {
    const a = row as HubAssetRow;
    const spoke = a.lendReserves[0]?.spoke;
    slots = { vault: a.hub, token: a.underlying, riskManager: spoke, oracleRouter: oracleOf(spoke) };
  }
  const links = explorerLinks(dep?.explorerUrl);
  return ABOUT_SLOTS.flatMap((salt) => {
    const address = slots[salt]?.toLowerCase();
    if (!address) return [];
    return [{ slug, salt, address, label: shortAddress(address), href: links?.address(address) ?? "", chain, isSynthetic: false as const }];
  });
}
