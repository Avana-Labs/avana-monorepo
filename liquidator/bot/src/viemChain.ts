// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// The `Chain` surface on viem clients.

import { type LocalAccount, createPublicClient, createWalletClient, defineChain, http } from "viem";
import { adapterAbi } from "./abis.ts";
import type { Chain } from "./chain.ts";

export function viemChain(rpcUrl: string, chainId: number, signer: LocalAccount): Chain {
  const chain = defineChain({ id: chainId, name: `chain-${chainId}`, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [rpcUrl] } } });
  const pub = createPublicClient({ chain, transport: http(rpcUrl) });
  const wallet = createWalletClient({ chain, transport: http(rpcUrl), account: signer });
  return {
    getBlockNumber: () => pub.getBlockNumber(),
    async getAccountCreatedLogs(adapter, fromBlock, toBlock) {
      const logs = await pub.getContractEvents({ address: adapter, abi: adapterAbi, eventName: "AccountCreated", fromBlock, toBlock });
      return logs.map((l) => ({ account: l.args.account!, marketId: l.args.marketId! }));
    },
    read: (c) => pub.readContract(c as never) as never,
    async simulate(c) {
      const { result } = await pub.simulateContract({ ...c, account: c.account } as never);
      return result as never;
    },
    async send(c) {
      const { request } = await pub.simulateContract({ ...c, account: signer } as never);
      const hash = await wallet.writeContract(request as never);
      const receipt = await pub.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error(`transaction ${hash} reverted`);
      return hash;
    },
  };
}
