// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// How a grant is carried out, per kind of chain:
// - "fork" (the local Ethereum and Base forks): balances set with anvil cheatcodes; the later starting positions are
//   opened as the impersonated wallet, through the same contracts the app's own actions use. No key is involved.
// - "testnet" (Sepolia, Base Sepolia): impersonation does not exist there, so the test tokens are minted to the wallet
//   by their minter, the world deployer, signing from its encrypted keystore; gas is optional (FAUCET_GAS_ETH).
// No setup step charges the Q-409 front-end fee: the faucet is not an app action (docs/spec/04-security/
// 04-design-decisions.md, Q-409 (1)), and it never calls the app's fee module.

import { getAddress, parseEther, parseUnits, type Address, type Hex } from "viem";
import { checkLocalFork, checkTestNetwork, fundToken, mintData, setNativeBalance, tokenDecimals, tokenMinter, type Rpc } from "./chain.ts";
import type { GrantSpec } from "./grants.ts";
import { LineFailed, resolveLine, type ExternalEntry } from "./manifest.ts";
import { openStartingPositions, type PositionsManifest } from "./positions.ts";

export type ChainKind = "fork" | "testnet";

export interface GrantStep {
  readonly step: string;
  readonly detail: string;
  /** Transaction hash, for steps that send one; cheatcodes send none. */
  readonly txHash?: Hex;
  /** A token line the chain's manifest cannot serve (no such token or feed); the grant goes on without it. */
  readonly failed?: true;
}

export interface SetupStrategy {
  readonly kind: ChainKind;
  /** Runs every step in order; the first failing step stops the grant and is named in the error. */
  run(wallet: Address, grant: GrantSpec): Promise<GrantStep[]>;
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

/**
 * The local fork: cheatcodes for gas and tokens, token addresses and USD prices from the chain's manifest (`external`),
 * then, with the manifest's markets, the starting positions opened as the wallet (positions.ts).
 */
export function forkStrategy(
  rpc: Rpc,
  allowedChainIds: readonly number[],
  external: readonly ExternalEntry[] = [],
  positions?: PositionsManifest,
): SetupStrategy {
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
      for (const line of grant.tokens) {
        const name = `token ${line.symbol}`;
        let token;
        try {
          token = await resolveLine(rpc, external, line);
        } catch (error) {
          if (!(error instanceof LineFailed)) throw new StepFailed(name, done, error);
          done.push({ step: name, detail: error.message, failed: true });
          continue;
        }
        await step(name, async () => `${token.amount} ${token.symbol} (${await fundToken(rpc, token.address, wallet, token.amount)} units)`);
      }
      if (positions) done.push(...(await openStartingPositions(rpc, wallet, positions, external)));
      return done;
    },
  };
}

/**
 * The account that funds test-network grants: the test tokens' minter (the world deployer), signing from its encrypted
 * keystore (main.ts). Sends take an explicit nonce, so one grant's mints go out together and are confirmed after.
 */
export interface Minter {
  readonly address: Address;
  /** The next nonce, pending transactions counted. */
  nonce(): Promise<number>;
  /** Signs and sends; returns the transaction hash. */
  send(tx: { readonly to: Address; readonly data?: Hex; readonly value?: bigint; readonly nonce: number }): Promise<Hex>;
  /** Waits for the transaction's receipt; true when it succeeded. */
  confirmed(hash: Hex): Promise<boolean>;
}

export interface TestnetOptions {
  readonly rpc: Rpc;
  readonly allowedChainIds: readonly number[];
  readonly external: readonly ExternalEntry[];
  readonly minter: Minter;
  /** Native ETH the wallet is topped up to from the minter's balance, in ETH; "0" (the default) gives none. */
  readonly gasEth?: string;
}

/**
 * A public test network (Sepolia, Base Sepolia): the chain id is checked, the wallet is topped up to `gasEth` test ETH
 * when that is set, and each wallet token of the grant is minted to the wallet by the minter (TestToken.mint). A token
 * the minter cannot mint fails its line only. No starting positions: they need impersonation. Without a minter every
 * grant is refused.
 */
export function testnetStrategy(options?: TestnetOptions): SetupStrategy {
  return {
    kind: "testnet",
    async run(wallet, grant) {
      if (!options) throw new StepFailed("testnet", [], new Error("test-network grants need the minter's keystore (FAUCET_SIGNER_KEYSTORE)"));
      const { rpc, allowedChainIds, external, minter } = options;
      const done: GrantStep[] = [];
      const step = async <T>(name: string, action: () => Promise<T>): Promise<T> => {
        try {
          return await action();
        } catch (error) {
          throw new StepFailed(name, done, error);
        }
      };
      const chainId = await step("check chain", () => checkTestNetwork(rpc, allowedChainIds));
      done.push({ step: "check chain", detail: `chain ${chainId}, test network` });
      let nonce = await step("nonce", () => minter.nonce());
      const sent: { step: GrantStep; hash: Hex }[] = [];

      const gasWei = parseEther(options.gasEth ?? "0");
      if (gasWei > 0n) {
        await step("gas", async () => {
          const balance = BigInt((await rpc.request({ method: "eth_getBalance", params: [wallet, "latest"] })) as string);
          if (balance >= gasWei) {
            done.push({ step: "gas", detail: `${options.gasEth} ETH already held` });
            return;
          }
          const hash = await minter.send({ to: wallet, value: gasWei - balance, nonce });
          nonce++;
          sent.push({ step: { step: "gas", detail: `topped up to ${options.gasEth} ETH (${gasWei - balance} wei)`, txHash: hash }, hash });
        });
      }

      for (const line of grant.tokens) {
        const name = `token ${line.symbol}`;
        let token;
        try {
          token = await resolveLine(rpc, external, line);
        } catch (error) {
          if (!(error instanceof LineFailed)) throw new StepFailed(name, done, error);
          done.push({ step: name, detail: error.message, failed: true });
          continue;
        }
        const minterOf = await step(name, () => tokenMinter(rpc, token.address));
        if (minterOf === null || getAddress(minterOf) !== getAddress(minter.address)) {
          done.push({ step: name, detail: `${token.symbol} is not minted by the faucet's signer`, failed: true });
          continue;
        }
        const units = await step(name, async () => parseUnits(token.amount, await tokenDecimals(rpc, token.address)));
        const hash = await step(name, () => minter.send({ to: token.address, data: mintData(wallet, units), nonce }));
        nonce++;
        sent.push({ step: { step: name, detail: `${token.amount} ${token.symbol} (${units} units) minted`, txHash: hash }, hash });
      }

      for (const s of sent) {
        const ok = await step(s.step.step, () => minter.confirmed(s.hash));
        if (!ok) throw new StepFailed(s.step.step, done, new Error(`transaction ${s.hash} reverted`));
        done.push(s.step);
      }
      return done;
    },
  };
}
