// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Against the real providers: skipped unless their credentials are in the environment (ALCHEMY_API_KEY;
// QUICKNODE_ENDPOINT_NAME and QUICKNODE_TOKEN). Each provider is checked alone on every chain it serves, so a missing
// network on one account shows as that provider's failure.

import { describe, expect, it } from "vitest";
import { AvanaRPCManager, CREDENTIAL_NAMES, RPC_CHAINS } from "../src/index.ts";

const env = process.env;
const providers = [
  { id: "alchemy", set: !!env.ALCHEMY_API_KEY },
  { id: "quicknode", set: !!env.QUICKNODE_ENDPOINT_NAME && !!env.QUICKNODE_TOKEN },
];

for (const p of providers) {
  describe.skipIf(!p.set)(`${p.id} (real endpoints)`, () => {
    const manager = AvanaRPCManager.fromEnv({ ...Object.fromEntries(CREDENTIAL_NAMES.map((n) => [n, env[n]])), AVANA_RPC_PROVIDERS: p.id }, { logger: null });

    for (const c of Object.values(RPC_CHAINS)) {
      it(`serves chain ${c.id} over HTTP: chain ID, a fresh head, a multicall read`, async () => {
        const client = manager.getClient(c.id);
        expect(await client.getChainId()).toBe(c.id);
        const [report] = await manager.probe(c.id);
        expect(report).toMatchObject({ provider: p.id, down: false });
        const block = await client.getBlock();
        expect(Date.now() / 1000 - Number(block.timestamp)).toBeLessThan(c.maxHeadAgeMs / 1000);
        const [a, b] = await Promise.all([client.getBalance({ address: "0x0000000000000000000000000000000000000000" }), client.getBlockNumber({ cacheTime: 0 })]);
        expect(a).toBeTypeOf("bigint");
        expect(b).toBeGreaterThan(0n);
      });
    }

    it("serves Sepolia over WebSocket", async () => {
      const client = manager.getWebSocketClient(11_155_111);
      expect(await client.getChainId()).toBe(11_155_111);
      await manager.close();
    });

    it("never names a credential in an error", async () => {
      const err = (await manager.getClient(11_155_111).request({ method: "eth_getBalance" as never, params: ["not-an-address", "latest"] as never }).catch((e: unknown) => e)) as Error;
      for (const n of CREDENTIAL_NAMES) if (env[n] && env[n]!.length >= 6) expect(`${err.message}\n${err.stack}`).not.toContain(env[n]);
    });
  });
}
