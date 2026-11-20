// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The manifests the handlers look integrations up in during the harness runs (chain 1 and the development nodes):
// integration 1 (Uniswap v3) and integration 3 (Uniswap v4), each with its core stack at fixed addresses.

import type { ServiceManifest } from "@avana/services-common";
import { addr } from "./addr.ts";

const im = (n: number) => ({ address: addr(n), codeHash: `0x${"00".repeat(32)}` as const, startBlock: 1 });
const stack = (integrationId: number, kind: string, base: number) => ({
  integrationId,
  kind,
  lpVault: im(base),
  riskModule: im(base + 1),
  liquidationModule: im(base + 2),
  aaveAdapter: im(base + 3),
  flashloanRepay: im(base + 4),
});

/** Integration 1's contracts. */
export const V3 = { lpVault: addr(0x100), riskModule: addr(0x101), liquidationModule: addr(0x102), aaveAdapter: addr(0x103), flashloanRepay: addr(0x104) };
/** Integration 3's contracts. */
export const V4 = { lpVault: addr(0x300), riskModule: addr(0x301), liquidationModule: addr(0x302), aaveAdapter: addr(0x303), flashloanRepay: addr(0x304) };

const manifestOf = (chainId: number) =>
  ({
    chainId,
    avana: { accessManager: im(0x10), integrations: [stack(1, "uniswap-v3", 0x100), stack(3, "uniswap-v4", 0x300)], flashLiquidators: [] },
  }) as unknown as ServiceManifest;

/** The same deployment on chain 1 and on both development nodes. */
export const HARNESS_MANIFESTS = [1, 31_337, 31_338].map(manifestOf);
