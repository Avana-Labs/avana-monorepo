// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// One chain's loop. Each new head: detect a reorg, read the instance's own status, run every job through the
// pipeline at that block, follow up pending transactions, then evaluate the block-cadence alerts (M-09, then M-16 and
// M-17) and report the head as processed (the monitor's heartbeat). Blocks are
// processed one at a time; a head that arrives during a pass is processed after it, newest first.

import { type Address, type PublicClient, decodeFunctionResult, encodeFunctionData } from "viem";
import { flashLiquidatorAbi } from "@avana/protocol/abis";
import type { ChainConfig, KeeperConfig } from "../config.ts";
import type { RetryHint } from "../jobs/failureReasons.ts";
import { createChainReader } from "../chain/reads.ts";
import type { AccountCache } from "../discovery/accountCache.ts";
import { type Head, isReorg } from "../discovery/stream.ts";
import { breakerPokeJob } from "../jobs/breakerPoke.ts";
import { liquidationJob } from "../jobs/liquidation.ts";
import { PokeBook, oraclePokeJob } from "../jobs/oraclePoke.ts";
import { settlePendingJob } from "../jobs/settlePending.ts";
import { blocksFor } from "@avana/services-common";
import { type AlertSink, m09Level, raise } from "../monitoring/alerts.ts";
import { RevertWindow, m10Level } from "../monitoring/m10.ts";
import { type PipelineDeps, runJob } from "../pipeline.ts";
import { type SafetyState, effectiveMode } from "../safety/guards.ts";
import type { BlockContext, Job } from "../types.ts";
import { type Submitter, simulate } from "./submitter.ts";

export interface ChainLoopDeps {
  readonly keeper: KeeperConfig;
  readonly cfg: ChainConfig;
  readonly primary: PublicClient;
  readonly fallback: PublicClient;
  readonly cache: AccountCache;
  readonly safety: SafetyState;
  readonly alerts: AlertSink;
  /** Null when no signer is configured: the chain runs in observe-only mode. */
  readonly submitter: Submitter | null;
  /** The signer the helper is bound to; in observe-only mode the manifest's signer of the helper, used only as `from` in eth_call. */
  readonly from: Address;
  readonly helper: { address: Address; maxTopUpBps: bigint };
  /** Re-reads accounts touched by removed blocks and rolls the cache back to the common ancestor. */
  onReorg(head: Head): Promise<void>;
  /** Polls the indexer stream before the pass (discovery/indexerStream.ts); a failure never stops the pass. */
  beforePass?(head: Head): Promise<void>;
  /** M-16 and M-17 at the head after the pass (monitoring/funding.ts); a failed read is logged, never stops the loop. */
  funding?(head: Head): Promise<void>;
  /** The head this instance has finished processing: the monitor's heartbeat. */
  processed?(head: Head): void;
}

export function chainLoop(d: ChainLoopDeps) {
  const book = new PokeBook();
  const hints = new Map<string, RetryHint>();
  let previous: Head | null = null;
  const reverts = new RevertWindow(BigInt(blocksFor(d.cfg.chain, 3_600)));
  const alert = (signal: `M-${string}`, level: "warn" | "page", subject: string, detail: Readonly<Record<string, string>>) => {
    const blockNumber = previous?.number ?? 0n;
    // M-10 is judged per market: the account's market from the cache, the account and its reason in the detail.
    const account = signal === "M-10" ? d.cache.ofChain(d.cfg.chain.id).find((x) => subject.endsWith(x.proxy)) : undefined;
    if (account) {
      const market = account.marketId.toString(10);
      const accounts = reverts.record(market, account.proxy, blockNumber);
      const m10 = { account: subject, accountsInHour: String(accounts), playbook: "P-04", ...detail };
      return void d.alerts.send({ signal, level: m10Level(accounts, level), chainId: d.cfg.chain.id, blockNumber, subject: `market:${market}`, detail: m10 });
    }
    void d.alerts.send({ signal, level, chainId: d.cfg.chain.id, blockNumber, subject, detail });
  };
  const jobs: Job<any, any>[] = [
    liquidationJob({
      cache: d.cache,
      role: d.keeper.role,
      shard: d.keeper.shard,
      helper: d.helper,
      // flashLiquidate at the decision block with minPayout 0 returns the payout to the Safe, which includes the
      // inventory it fronted: net = payout − inventory = keeperOut − debtToCover − premium.
      simulateNet: async (ctx, request) => {
        const data = encodeFunctionData({ abi: flashLiquidatorAbi, functionName: "flashLiquidate", args: [request] });
        const { data: ret } = await ctx.reader.callAt(d.helper.address, data, d.from);
        if (!ret) throw new Error("flashLiquidate simulation returned no data");
        const payout = decodeFunctionResult({ abi: flashLiquidatorAbi, functionName: "flashLiquidate", data: ret }) as bigint;
        return payout - (request.params.debtToCover - request.flashAmount);
      },
      hints,
      alert,
      stopHelper: (chainId) => d.safety.frozenHelperChains.add(chainId),
    }),
    settlePendingJob(),
    oraclePokeJob(book),
    breakerPokeJob(),
  ];
  const chainId = d.cfg.chain.id;
  const pipeline: PipelineDeps = {
    safety: d.safety,
    mode: () => effectiveMode(d.keeper.mode, d.submitter !== null, d.safety),
    simulate: (_ctx, plan) => simulate(d.primary, d.from, plan),
    submit: async (ctx, plan, sim) => {
      if (!d.submitter) throw new Error("no signer");
      const hash = await d.submitter.submit(ctx, plan, sim);
      // The account stays in flight until the tracker sees this transaction mined, cancelled or expired.
      const a = d.cache.ofChain(chainId).find((x) => plan.subject.endsWith(x.proxy));
      if (plan.job === "liquidation" && a) a.pendingTx = hash;
      return hash;
    },
    page: (signal, detail) =>
      void d.alerts.send({ signal: signal as `M-${string}`, level: "page", chainId, blockNumber: previous?.number ?? 0n, subject: detail.address ?? "", detail }),
  };

  return async function onHead(head: Head): Promise<void> {
    if (isReorg(previous, head)) {
      await d.onReorg(head);
      // Transactions mined in removed blocks return to pending with their flags and reservations, then the nonce is re-read.
      await d.submitter?.onReorg(head.number, (plan, hash) => {
        const a = d.cache.ofChain(chainId).find((x) => plan.subject.endsWith(x.proxy));
        if (plan.job === "liquidation" && a) a.pendingTx = hash;
      });
      await d.submitter?.nonces.resync();
    }
    await d.beforePass?.(head);
    previous = head;
    const ctx: BlockContext = { config: d.cfg, blockNumber: head.number, blockTimestamp: head.timestamp, reader: createChainReader(d.primary, d.cfg.manifest, head.number) };

    // The instance's own status: a frozen helper stops submissions and pages; an unregistered one only warns (Q-404).
    const status = await ctx.reader.operatorStatus(d.helper.address);
    if (status.frozen) d.safety.frozenHelperChains.add(chainId);
    else d.safety.frozenHelperChains.delete(chainId);

    for (const job of jobs) await runJob(job, ctx, pipeline);

    await d.submitter?.followUps(
      ctx,
      async (plan) => plan.job !== "liquidation" || (d.cache.ofChain(chainId).find((a) => plan.subject.endsWith(a.proxy))?.liquidatableSince ?? null) !== null,
      (plan) => {
        const a = d.cache.ofChain(chainId).find((x) => plan.subject.endsWith(x.proxy));
        if (a) a.pendingTx = null;
      },
    );

    for (const a of d.cache.ofChain(chainId)) {
      const level = m09Level(d.cfg.chain, a.liquidatableSince, head.number);
      if (level === "ok") continue;
      await raise(
        d.alerts,
        { signal: "M-09", level: level === "escalate" ? "page" : level, chainId, blockNumber: head.number, subject: a.proxy, detail: { since: String(a.liquidatableSince), escalate: String(level === "escalate") } },
        async () => (await createChainReader(d.fallback, d.cfg.manifest, head.number).accountData([a])).get(a.proxy)!.healthFactor < 10n ** 18n,
      );
    }

    try {
      await d.funding?.(head);
    } catch (err) {
      process.stdout.write(`${JSON.stringify({ type: "keeper.fundingCheck", chainId, blockNumber: head.number.toString(10), error: String(err) })}
`);
    }
    d.processed?.(head);
  };
}
