// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// How a grant is carried out, per kind of chain:
// - "fork" (the local Ethereum and Base forks): balances set with anvil cheatcodes; the later starting positions are
//   opened as the impersonated wallet, through the same contracts the app's own actions use. No key is involved.
// - "testnet" (Sepolia): impersonation does not exist there, and how test funds are given is not decided yet. The
//   strategy refuses until then.
// No setup step charges the Q-409 front-end fee: the faucet is not an app action (docs/spec/04-security/
// 04-design-decisions.md, Q-409 (1)), and it never calls the app's fee module.

import type { Address, Hex } from "viem";
import { checkLocalFork, fundToken, setNativeBalance, type Rpc } from "./chain.ts";
import type { ChainGrant } from "./grants.ts";

export type ChainKind = "fork" | "testnet";

export interface GrantStep {
  readonly step: string;
  readonly detail: string;
  /** Transaction hash, for steps that send one; cheatcodes send none. */
  readonly txHash?: Hex;
}

export interface SetupStrategy {
  readonly kind: ChainKind;
  /** Runs every step in order; the first failing step stops the grant and is named in the error. */
  run(wallet: Address, grant: ChainGrant): Promise<GrantStep[]>;
}

export class StepFailed extends Error {
  constructor(
    readonly step: string,
    readonly done: readonly GrantStep[],
    cause: unknown,
  ) {
    super(`grant step "${step}" failed: ${cause instanceof Error ? cause.message : String(cause)}`);
  }
}

export function forkStrategy(rpc: Rpc, allowedChainIds: readonly number[]): SetupStrategy {
  return {
    kind: "fork",
    async run(wallet, grant) {
      const done: GrantStep[] = [];
      const step = async (name: string, action: () => Promise<string>) => {
        try {
          done.push({ step: name, detail: await action() });
        } catch (error) {
          throw new StepFailed(name, done, error);
        }
      };
      await step("check chain", async () => `chain ${await checkLocalFork(rpc, allowedChainIds)}, anvil`);
      await step("gas", async () => `${grant.nativeEth} ETH (${await setNativeBalance(rpc, wallet, grant.nativeEth)} wei)`);
      for (const token of grant.tokens) {
        await step(`token ${token.symbol}`, async () => `${token.amount} ${token.symbol} (${await fundToken(rpc, token.address, wallet, token.amount)} units)`);
      }
      return done;
    },
  };
}

export function testnetStrategy(): SetupStrategy {
  return {
    kind: "testnet",
    async run() {
      throw new StepFailed("testnet", [], new Error("test-network grants are not built yet"));
    },
  };
}
