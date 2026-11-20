// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The addresses one chain's snapshot reads, from its verified release manifest. Every service that samples a chain
// (the indexer, Convex, the monitor) builds its ChainDeployment here, so they read the same contracts.

import type { ServiceManifest } from "../manifest.ts";
import { lower, uniq } from "./client.ts";
import type { Address, ChainDeployment } from "./types.ts";

export function chainDeploymentOf(m: ServiceManifest): ChainDeployment {
  const riskModuleOf = new Map(m.avana.integrations.map((x) => [x.integrationId, lower(x.riskModule.address)]));
  const homeHub = new Map<Address, Address>();
  for (const mk of m.markets) homeHub.set(lower(mk.spoke), lower(mk.hub));
  const cdpSpokes = uniq([...m.aave.borrowSpokes.map((s) => lower(s.address)), ...m.markets.map((mk) => lower(mk.spoke))]);
  return {
    chainId: m.chainId,
    hubs: m.aave.hubs.map((h) => ({ address: lower(h.address), label: h.label, tier: h.tier })),
    lendSpokes: m.aave.lendSpokes.map((s) => lower(s.address)),
    cdpSpokes: cdpSpokes.map((address) => ({ address, hub: homeHub.get(address) ?? ("0x0000000000000000000000000000000000000000" as Address) })),
    firstLossReserves: m.coverage.firstLossReserves.map((f) => ({ address: lower(f.address), asset: lower(f.asset), hub: lower(f.hub) })),
    deficitOffsets: m.coverage.daoDeficitOffsets.map((f) => ({ address: lower(f.address), asset: lower(f.asset), hub: lower(f.hub) })),
    riskModules: m.avana.integrations.map((x) => lower(x.riskModule.address)),
    markets: m.markets.map((mk) => {
      const riskModule = riskModuleOf.get(mk.integrationId);
      if (!riskModule) throw new Error(`market ${mk.marketId} names integration ${mk.integrationId}, which the manifest does not list`);
      return {
        marketId: mk.marketId,
        integrationId: mk.integrationId,
        riskModule,
        kind: mk.kind,
        name: mk.name,
        pool: mk.pool.toLowerCase() as `0x${string}`,
        spoke: lower(mk.spoke),
        hub: lower(mk.hub),
        vaultToken: lower(mk.vaultToken.address),
        lpOracle: lower(mk.lpOracle.address),
        reserveId: mk.reserveId,
        tokens: mk.tokens.map(lower),
      };
    }),
    debtReserves: m.debtReserves.map((r) => ({ spoke: lower(r.spoke), reserveId: r.debtReserveId, fixedPrice: r.isGho })),
  };
}
