// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// LPOracle and DebtOracle events. A state written here is the state at the oracle's last poke or read;
// Cached and Expired begin by time alone, so the keeper and Convex read Lens.getPriceState for the live state.

import { ponder } from "ponder:registry";
import schema from "ponder:schema";
import type { Hex } from "viem";
import { PRICE_STATE, enumName, logOnly } from "../lib/logOnly.ts";
import { recordLog } from "../lib/record.ts";

type Patch = Partial<typeof schema.oracleState.$inferInsert>;

async function patchOracle(db: any, chainId: number, oracle: Hex, kind: "lp" | "debt", block: bigint, patch: Patch) {
  await db
    .insert(schema.oracleState)
    .values({ chainId, oracle, kind, state: "Live", reasons: 0n, lastBlock: block, ...patch })
    .onConflictDoUpdate({ ...patch, lastBlock: block });
}

ponder.on("LPOracle:PriceStateChanged", async ({ event, context }) => {
  const p = await recordLog(event, context, "LPOracle.PriceStateChanged");
  await patchOracle(context.db, p.chainId, event.log.address, "lp", p.blockNumber, {
    state: enumName(PRICE_STATE, event.args.current),
    reasons: event.args.reasons,
  });
});

ponder.on("LPOracle:PriceAccepted", async ({ event, context }) => {
  const p = await recordLog(event, context, "LPOracle.PriceAccepted");
  await patchOracle(context.db, p.chainId, event.log.address, "lp", p.blockNumber, {
    acceptedPrice: BigInt(event.args.answer),
    acceptedAt: BigInt(event.args.updatedAt),
  });
});

ponder.on("LPOracle:DisagreementRecorded", async ({ event, context }) => {
  const p = await recordLog(event, context, "LPOracle.DisagreementRecorded");
  await patchOracle(context.db, p.chainId, event.log.address, "lp", p.blockNumber, { disagreeSince: BigInt(event.args.since) });
});

ponder.on("LPOracle:DisagreementCleared", async ({ event, context }) => {
  const p = await recordLog(event, context, "LPOracle.DisagreementCleared");
  await patchOracle(context.db, p.chainId, event.log.address, "lp", p.blockNumber, { disagreeSince: null });
});

ponder.on("LPOracle:GraceStarted", async ({ event, context }) => {
  const p = await recordLog(event, context, "LPOracle.GraceStarted");
  await patchOracle(context.db, p.chainId, event.log.address, "lp", p.blockNumber, { graceEndsAt: BigInt(event.args.graceEndsAt) });
});

logOnly("LPOracle", [
  "PriceSeeded",
  "RouteChanged",
  "FailureRecorded",
  "FailureCleared",
  "OutageExpiredLatched",
  "QuoteChangeCapped",
  "PokeMinGasUpdated",
  "PriceCheckpointed",
  "PriceRouteVersionObserved",
]);

ponder.on("DebtOracle:DebtPriceStateChanged", async ({ event, context }) => {
  const p = await recordLog(event, context, "DebtOracle.DebtPriceStateChanged");
  await patchOracle(context.db, p.chainId, event.log.address, "debt", p.blockNumber, {
    state: enumName(PRICE_STATE, event.args.current),
    reasons: event.args.reasons,
  });
});

ponder.on("DebtOracle:DebtPriceAccepted", async ({ event, context }) => {
  const p = await recordLog(event, context, "DebtOracle.DebtPriceAccepted");
  await patchOracle(context.db, p.chainId, event.log.address, "debt", p.blockNumber, {
    acceptedPrice: event.args.price8,
    acceptedAt: BigInt(event.args.updatedAt),
  });
});

ponder.on("DebtOracle:DebtDisagreementRecorded", async ({ event, context }) => {
  const p = await recordLog(event, context, "DebtOracle.DebtDisagreementRecorded");
  await patchOracle(context.db, p.chainId, event.log.address, "debt", p.blockNumber, { disagreeSince: BigInt(event.args.since) });
});

ponder.on("DebtOracle:DebtDisagreementCleared", async ({ event, context }) => {
  const p = await recordLog(event, context, "DebtOracle.DebtDisagreementCleared");
  await patchOracle(context.db, p.chainId, event.log.address, "debt", p.blockNumber, { disagreeSince: null });
});

ponder.on("DebtOracle:DebtGraceStarted", async ({ event, context }) => {
  const p = await recordLog(event, context, "DebtOracle.DebtGraceStarted");
  await patchOracle(context.db, p.chainId, event.log.address, "debt", p.blockNumber, { graceEndsAt: BigInt(event.args.graceEndsAt) });
});

logOnly("DebtOracle", [
  "DebtPriceSeeded",
  "DebtRouteChanged",
  "DebtFailureRecorded",
  "DebtFailureCleared",
  "DebtOutageExpiredLatched",
  "DebtRouteVersionObserved",
  "PokeMinGasUpdated",
]);
