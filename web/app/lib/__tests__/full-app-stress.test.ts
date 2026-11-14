/**
 * Full-app engine stress test.
 *
 * Spins up 10,000 wallets across several behavioural personas and drives the
 * Borrow / Lend / Multiply / Rewards engines through long randomized action
 * sequences, asserting the engines' own invariants plus a set of economic
 * oracles after every mutation.
 *
 * Goal: surface correctness cracks (state corruption, NaN/Infinity leakage,
 * accounting drift, double-claims, codec round-trip loss) that only appear
 * under heavy, varied, "users behaving like crazy" load.
 *
 * Run just this file:
 *   npx vitest run app/lib/__tests__/full-app-stress.test.ts
 * Tune scale with STRESS_USERS / STRESS_SEED env vars.
 */
import { writeFileSync } from "node:fs"
import path from "node:path"
import { describe, expect, it } from "vitest"

import {
  assertBorrowSystemInvariants,
  evaluateBorrowAction,
  type BorrowAction,
  type BorrowSystemState,
} from "@/app/lib/borrow-system/model"
import { buildMockBorrowSystemState } from "@/app/lib/borrow-system/mock"
import { serializeBorrowSystemState, deserializeBorrowSystemState } from "@/app/lib/borrow-system/codec"

import {
  applyLendAction,
  assertLendSystemInvariants,
  type LendAction,
  type LendSystemState,
} from "@/app/lib/lend-system/model"
import { buildMockLendSystemState } from "@/app/lib/lend-system/mock"
import { serializeLendSystemState, deserializeLendSystemState } from "@/app/lib/lend-system/codec"

import { applyMultiplyAction, assertMultiplySystemInvariants, type MultiplyAction } from "@/app/lib/multiply-engine"
import { buildMockMultiplySystemState } from "@/app/lib/multiply-system/mock"
import { serializeMultiplySystemState, deserializeMultiplySystemState } from "@/app/lib/multiply-system/codec"

import {
  applyActivityEvent,
  buildDefaultRewardsCatalog,
  claimReward as buildClaimReward,
  evaluateAllTasksForUser,
  type RewardActivityEvent,
  type RewardsEngineState,
} from "@/app/lib/rewards-engine"

// --------------------------------------------------------------------------
// Config + deterministic RNG
// --------------------------------------------------------------------------
const USERS = Number(process.env.STRESS_USERS ?? 10_000)
const ACTIONS_PER_USER = Number(process.env.STRESS_ACTIONS_PER_USER ?? 100)
const SEED = Number(process.env.STRESS_SEED ?? 0xc0ffee)

function mulberry32(seed: number) {
  let a = seed >>> 0
  return () => {
    a |= 0
    a = (a + 0x6d2b79f5) | 0
    let t = Math.imul(a ^ (a >>> 15), 1 | a)
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

type Persona = "conservative" | "normal" | "degen" | "whale" | "dust" | "chaos"
const PERSONAS: Persona[] = ["conservative", "normal", "degen", "whale", "dust", "chaos"]

function pick<T>(rng: () => number, arr: T[]): T {
  return arr[Math.floor(rng() * arr.length)] ?? arr[0]!
}

function usd6(value: number): bigint {
  if (!Number.isFinite(value)) return 0n
  return BigInt(Math.trunc(value * 1_000_000))
}

// Persona-driven magnitude for fiat amounts.
function amountFor(rng: () => number, persona: Persona): number {
  switch (persona) {
    case "dust":
      return rng() * 0.01
    case "whale":
      return 1_000_000 + rng() * 50_000_000
    case "degen":
      return 1_000 + rng() * 250_000
    case "conservative":
      return rng() * 500
    case "chaos": {
      const choices = [
        () => -(rng() * 1e9),
        () => 0,
        () => Number.POSITIVE_INFINITY,
        () => Number.NaN,
        () => rng() * 1e15,
        () => rng() * 100,
      ]
      return pick(rng, choices)()
    }
    default:
      return rng() * 25_000
  }
}

function multiplierFor(rng: () => number, persona: Persona): number {
  switch (persona) {
    case "conservative":
      return 1.1 + rng() * 0.9
    case "degen":
      return 5 + rng() * 20
    case "chaos":
      return pick(rng, [Number.NaN, Number.POSITIVE_INFINITY, -3, 0, 1, 1_000, 2 + rng() * 6])
    default:
      return 1.5 + rng() * 4
  }
}

// Plain domain rejections throw `Error`; genuine engine bugs surface as
// TypeError / RangeError (undefined access, NaN→BigInt, etc.).
function isCrash(err: unknown): boolean {
  if (err instanceof TypeError || err instanceof RangeError) return true
  const message = err instanceof Error ? err.message : String(err)
  return /cannot read|undefined is not|is not a function|reading '|of undefined|of null/i.test(message)
}

function scanNumbersForNonFinite(value: unknown, seen = new Set<unknown>()): boolean {
  if (typeof value === "number") return !Number.isFinite(value)
  if (typeof value !== "object" || value === null || seen.has(value)) return false
  seen.add(value)
  for (const entry of Object.values(value as Record<string, unknown>)) {
    if (scanNumbersForNonFinite(entry, seen)) return true
  }
  return false
}

// --------------------------------------------------------------------------
// Report accumulator
// --------------------------------------------------------------------------
type EngineTally = { ok: number; rejected: number; crash: number }
const report = {
  users: USERS,
  actionsPerUser: ACTIONS_PER_USER,
  seed: SEED,
  totalActions: 0,
  durationMs: 0,
  byEngine: {
    borrow: { ok: 0, rejected: 0, crash: 0 } as EngineTally,
    lend: { ok: 0, rejected: 0, crash: 0 } as EngineTally,
    multiply: { ok: 0, rejected: 0, crash: 0 } as EngineTally,
    rewards: { ok: 0, rejected: 0, crash: 0 } as EngineTally,
  },
  crashes: [] as Array<{ engine: string; persona: Persona; action: string; message: string }>,
  invariantViolations: [] as Array<{ engine: string; persona: Persona; when: string; message: string }>,
  economic: {
    borrowNotCreditedToWallet: 0,
    repayNotDebitedFromWallet: 0,
    nonFiniteFromFiniteInput: 0,
    multiplyNegativeEquity: 0,
    doubleClaim: 0,
    claimAmountMismatch: 0,
    lendWithdrawExceededSupplied: 0,
    stateCorruptionAfterReject: 0,
    codecRoundTripLoss: 0,
  },
  // Findings produced only when feeding deliberately malformed (NaN/Infinity)
  // input via the "chaos" persona. Reported as robustness gaps (missing input
  // guards), not gated as correctness failures.
  fuzzFindings: {
    invariantViolationsFromMalformedInput: 0,
    nonFiniteFromMalformedInput: 0,
  },
  samples: [] as string[],
}

function sample(message: string, limit = 40) {
  if (report.samples.length < limit) report.samples.push(message)
}

function recordCrash(engine: string, persona: Persona, action: string, err: unknown) {
  report.byEngine[engine as keyof typeof report.byEngine].crash += 1
  const message = err instanceof Error ? `${err.name}: ${err.message}` : String(err)
  if (report.crashes.length < 200) report.crashes.push({ engine, persona, action, message })
  sample(`[crash][${engine}/${persona}] ${action} -> ${message}`)
}

function recordInvariant(engine: string, persona: Persona, when: string, err: unknown, fromMalformedInput = false) {
  const message = err instanceof Error ? err.message : String(err)
  if (fromMalformedInput) {
    report.fuzzFindings.invariantViolationsFromMalformedInput += 1
    return
  }
  if (report.invariantViolations.length < 200) report.invariantViolations.push({ engine, persona, when, message })
  sample(`[invariant][${engine}/${persona}] ${when} -> ${message}`)
}

// --------------------------------------------------------------------------
// Per-engine helpers
// --------------------------------------------------------------------------
function totalBorrowDebtUsd6(state: BorrowSystemState, walletId: string): bigint {
  const account = state.accounts[walletId]
  if (!account) return 0n
  return account.debtPositions.reduce((sum, p) => sum + p.debtSharesUsd6, 0n)
}

function borrowMarketChoices(state: BorrowSystemState) {
  return Object.values(state.markets)
    .map((market) => ({
      marketId: market.id,
      assetIds: market.relations.supportedBorrowAssetIds.filter((id) => id && state.assets[id]),
    }))
    .filter((entry) => entry.assetIds.length > 0)
}

function findLendPosition(state: LendSystemState, walletId: string, marketId: string) {
  return Object.values(state.positions).find(
    (p) => p.walletId === walletId && p.marketId === marketId && p.status === "active",
  )
}

// --------------------------------------------------------------------------
// The run
// --------------------------------------------------------------------------
describe.skipIf(process.env.RUN_FULL_APP_STRESS !== "1")("full-app engine stress (10k personas)", () => {
  it(`drives ${USERS} wallets through Borrow/Lend/Multiply/Rewards`, () => {
    const startedAt = Date.now()
    const rng = mulberry32(SEED)

    const lendMarketIds = Object.keys(buildMockLendSystemState("probe").markets)
    const multiplyMarketIds = Object.keys(buildMockMultiplySystemState("probe").markets)
    const rewardTasks = buildDefaultRewardsCatalog(Date.UTC(2026, 5, 19))
    const rewardEventTypes = [
      "borrow_opened",
      "borrow_repaid",
      "lend_deposited",
      "lend_withdrawn",
      "multiply_opened",
      "multiply_deleveraged",
      "daily_checkin",
      "wallet_connected",
      "profile_completed",
      "education_completed",
      "market_favorited",
      "referral_connected",
      "referral_activated",
      "referral_funded",
      "simulation_created",
    ] as const

    for (let u = 0; u < USERS; u += 1) {
      const persona = PERSONAS[u % PERSONAS.length]!
      const walletId = `w-${persona}-${u}`
      const actionCount = ACTIONS_PER_USER

      // ---- engine states for this wallet -------------------------------
      let borrow = buildMockBorrowSystemState(walletId)
      let borrowBaseline = serializeBorrowSystemState(borrow)
      let lend = buildMockLendSystemState(walletId)
      let multiply = buildMockMultiplySystemState(walletId)
      let rewards: RewardsEngineState = { events: [], claims: [] }
      const firstLoginAt = Date.UTC(2026, 5, 19)
      let now = firstLoginAt

      const bMarkets = borrowMarketChoices(borrow)

      for (let a = 0; a < actionCount; a += 1) {
        now += 1 + Math.floor(rng() * 3_600_000)
        report.totalActions += 1
        const engine = pick(rng, ["borrow", "lend", "multiply", "rewards"] as const)

        // ============================= BORROW ========================
        if (engine === "borrow") {
          const kind = pick(rng, ["borrow", "supplyCollateral", "repay", "removeCollateral", "claim"] as const)
          const account = borrow.accounts[walletId]!
          let action: BorrowAction | null = null
          const choice = bMarkets.length > 0 ? pick(rng, bMarkets) : null

          if (kind === "borrow" && choice) {
            action = {
              type: "borrow",
              walletId,
              marketId: choice.marketId,
              assetId: pick(rng, choice.assetIds),
              amountUsd6: usd6(amountFor(rng, persona)),
              at: now,
            }
          } else if (kind === "supplyCollateral" && choice) {
            action = {
              type: "supplyCollateral",
              walletId,
              marketId: choice.marketId,
              amountUsd6: usd6(amountFor(rng, persona)),
              at: now,
            }
          } else if (kind === "repay" && account.debtPositions.length > 0) {
            action = {
              type: "repay",
              walletId,
              debtPositionId: pick(rng, account.debtPositions).id,
              amountUsd6: usd6(amountFor(rng, persona)),
              at: now,
            }
          } else if (kind === "removeCollateral" && account.collateralPositions.length > 0) {
            action = {
              type: "removeCollateral",
              walletId,
              positionId: pick(rng, account.collateralPositions).id,
              percentBps: Math.floor(rng() * 12_000),
              at: now,
            }
          } else if (kind === "claim" && account.rewardPositions.length > 0) {
            const rp = pick(rng, account.rewardPositions)
            action = { type: "claim", walletId, rewardPositionIds: [rp.id], amountUsd6: rp.claimableUsd6, at: now }
          }
          if (!action) continue

          const debtBefore = totalBorrowDebtUsd6(borrow, walletId)
          const walletBefore = borrow.accounts[walletId]!.walletBalanceUsd6
          try {
            borrow = evaluateBorrowAction(borrow, action, "commit")
            report.byEngine.borrow.ok += 1

            try {
              assertBorrowSystemInvariants(borrow)
            } catch (err) {
              recordInvariant("borrow", persona, `after ${action.type}`, err)
            }

            const debtAfter = totalBorrowDebtUsd6(borrow, walletId)
            const walletAfter = borrow.accounts[walletId]!.walletBalanceUsd6
            if (action.type === "borrow" && debtAfter > debtBefore && walletAfter <= walletBefore) {
              report.economic.borrowNotCreditedToWallet += 1
              sample(
                `[econ] borrow added debt ${debtAfter - debtBefore} but wallet balance did not increase (${walletBefore}->${walletAfter})`,
              )
            }
            if (action.type === "repay" && debtAfter < debtBefore && walletAfter >= walletBefore) {
              report.economic.repayNotDebitedFromWallet += 1
            }
            borrowBaseline = serializeBorrowSystemState(borrow)
          } catch (err) {
            if (isCrash(err)) {
              recordCrash("borrow", persona, action.type, err)
            } else {
              report.byEngine.borrow.rejected += 1
            }
            // A rejected action must not corrupt committed state.
            try {
              assertBorrowSystemInvariants(borrow)
            } catch (invErr) {
              report.economic.stateCorruptionAfterReject += 1
              recordInvariant("borrow", persona, `after REJECTED ${action.type}`, invErr)
            }
            borrow = deserializeBorrowSystemState(borrowBaseline)
          }
          continue
        }

        // ============================== LEND =========================
        if (engine === "lend") {
          const marketId = pick(rng, lendMarketIds)
          const kind = pick(rng, ["deposit", "deposit", "withdraw", "claim"] as const)
          let action: LendAction
          const existing = findLendPosition(lend, walletId, marketId)

          if (kind === "withdraw" && existing) {
            action = {
              type: "withdraw",
              walletId,
              marketId,
              positionId: existing.positionId,
              withdrawAmount: amountFor(rng, persona),
              at: now,
            }
          } else if (kind === "claim") {
            action = { type: "claim", walletId, at: now }
          } else {
            const amt = amountFor(rng, persona)
            action = {
              type: "deposit",
              walletId,
              marketId,
              depositAmount: amt,
              walletBalance: Math.abs(amt) + 1,
              at: now,
            }
          }

          const suppliedBefore = existing?.currentSuppliedAmount ?? 0
          const lendInputAmount =
            "depositAmount" in action
              ? action.depositAmount
              : ((action as { withdrawAmount?: number }).withdrawAmount ?? 0)
          const lendInputFinite = Number.isFinite(lendInputAmount)
          try {
            const next = applyLendAction(lend, action, {
              positionId: `${walletId}:${marketId}:${a}`,
              transactionId: `tx-${walletId}-${a}`,
            })
            const changed = next !== lend
            lend = next
            if (changed) report.byEngine.lend.ok += 1
            else report.byEngine.lend.rejected += 1

            try {
              assertLendSystemInvariants(lend)
            } catch (err) {
              recordInvariant("lend", persona, `after ${action.type}`, err, !lendInputFinite)
            }
            if (scanNumbersForNonFinite(findLendPosition(lend, walletId, marketId))) {
              if (lendInputFinite) {
                report.economic.nonFiniteFromFiniteInput += 1
                sample(
                  `[econ] lend produced non-finite from FINITE input (${persona}, ${action.type}, amt=${lendInputAmount})`,
                )
              } else {
                report.fuzzFindings.nonFiniteFromMalformedInput += 1
              }
            }
            if (action.type === "withdraw" && action.withdrawAmount > suppliedBefore + 1e-6 && changed) {
              const after = findLendPosition(lend, walletId, marketId)
              if (!after && suppliedBefore <= 0) {
                report.economic.lendWithdrawExceededSupplied += 1
              }
            }
          } catch (err) {
            if (isCrash(err)) recordCrash("lend", persona, action.type, err)
            else report.byEngine.lend.rejected += 1
          }
          continue
        }

        // ============================ MULTIPLY =======================
        if (engine === "multiply") {
          const marketId = pick(rng, multiplyMarketIds)
          const positionId = `${walletId}:${marketId}`
          const hasPosition = Boolean(multiply.positions[positionId])
          const kind = hasPosition ? pick(rng, ["multiply", "deleverage"] as const) : "multiply"
          const action: MultiplyAction =
            kind === "deleverage"
              ? { type: "deleverage", walletId, positionId, targetMultiplier: multiplierFor(rng, persona), at: now }
              : {
                  type: "multiply",
                  walletId,
                  marketId,
                  collateralAmount: amountFor(rng, persona) / 1000,
                  selectedMultiplier: multiplierFor(rng, persona),
                  at: now,
                }

          const mulInputFinite =
            action.type === "deleverage"
              ? Number.isFinite(action.targetMultiplier)
              : Number.isFinite(action.collateralAmount) && Number.isFinite(action.selectedMultiplier)
          try {
            multiply = applyMultiplyAction(multiply, action)
            report.byEngine.multiply.ok += 1
            try {
              assertMultiplySystemInvariants(multiply)
            } catch (err) {
              recordInvariant("multiply", persona, `after ${action.type}`, err, !mulInputFinite)
            }
            const pos = multiply.positions[positionId]
            if (pos) {
              if (scanNumbersForNonFinite(pos)) {
                if (mulInputFinite) {
                  report.economic.nonFiniteFromFiniteInput += 1
                  sample(`[econ] multiply non-finite from FINITE input (${persona}, ${action.type})`)
                } else {
                  report.fuzzFindings.nonFiniteFromMalformedInput += 1
                }
              }
              if (pos.collateralValueUsd - pos.debtValueUsd < -1e-3) {
                report.economic.multiplyNegativeEquity += 1
                sample(`[econ] multiply negative equity coll=${pos.collateralValueUsd} debt=${pos.debtValueUsd}`)
              }
            }
          } catch (err) {
            if (isCrash(err)) recordCrash("multiply", persona, action.type, err)
            else report.byEngine.multiply.rejected += 1
          }
          continue
        }

        // ============================= REWARDS =======================
        {
          const type = pick(rng, rewardEventTypes as unknown as string[])
          const event: RewardActivityEvent = {
            id: `${walletId}:${type}:${a}:${Math.floor(rng() * 1e9)}`,
            wallet: walletId,
            product: pick(rng, [
              "borrow",
              "lend",
              "multiply",
              "profile",
              "referral",
              "rewards",
            ]) as RewardActivityEvent["product"],
            type: type as RewardActivityEvent["type"],
            amountUsd: Math.abs(amountFor(rng, persona)),
            marketId: pick(rng, [...lendMarketIds, ...multiplyMarketIds, undefined]),
            referredWallet: `${walletId}-ref-${a}`,
            timestamp: now,
          }
          try {
            rewards = applyActivityEvent(rewards, event)
            report.byEngine.rewards.ok += 1

            const progress = evaluateAllTasksForUser({
              tasks: rewardTasks,
              wallet: walletId,
              events: rewards.events,
              claims: rewards.claims,
              now,
              firstLoginAt,
            })
            for (const entry of progress) {
              if (entry.status !== "claimable") continue
              if (rng() > 0.5) continue
              const task = rewardTasks.find((t) => t.id === entry.taskId)!
              const alreadyClaimed = rewards.claims.some((c) => c.wallet === walletId && c.taskId === entry.taskId)
              try {
                const { claim, event: claimEvent } = buildClaimReward({ wallet: walletId, task, progress: entry, now })
                if (alreadyClaimed) {
                  report.economic.doubleClaim += 1
                  sample(`[econ] rewards allowed building a second claim for ${entry.taskId}`)
                }
                if (claim.amount !== task.rewardAmount) {
                  report.economic.claimAmountMismatch += 1
                }
                rewards = { ...rewards, claims: [...rewards.claims, claim] }
                rewards = applyActivityEvent(rewards, claimEvent as RewardActivityEvent)
              } catch (err) {
                if (isCrash(err)) recordCrash("rewards", persona, "claim", err)
                else report.byEngine.rewards.rejected += 1
              }
            }
          } catch (err) {
            if (isCrash(err)) recordCrash("rewards", persona, event.type, err)
            else report.byEngine.rewards.rejected += 1
          }
        }
      }

      // ---- per-user codec round-trip integrity --------------------------
      if (u % 7 === 0) {
        try {
          const rtBorrow = deserializeBorrowSystemState(serializeBorrowSystemState(borrow))
          if (totalBorrowDebtUsd6(rtBorrow, walletId) !== totalBorrowDebtUsd6(borrow, walletId)) {
            report.economic.codecRoundTripLoss += 1
            sample(`[codec] borrow debt drifted after round-trip for ${walletId}`)
          }
          const rtLend = deserializeLendSystemState(serializeLendSystemState(lend))
          if (Object.keys(rtLend.positions).length !== Object.keys(lend.positions).length) {
            report.economic.codecRoundTripLoss += 1
          }
          const rtMul = deserializeMultiplySystemState(serializeMultiplySystemState(multiply))
          if (Object.keys(rtMul.positions).length !== Object.keys(multiply.positions).length) {
            report.economic.codecRoundTripLoss += 1
          }
        } catch (err) {
          report.economic.codecRoundTripLoss += 1
          sample(`[codec] round-trip threw: ${err instanceof Error ? err.message : String(err)}`)
        }
      }

      void firstLoginAt
    }

    report.durationMs = Date.now() - startedAt

    // ---- print report --------------------------------------------------
    const outPath = path.resolve(process.cwd(), "stress-report.json")
    writeFileSync(outPath, JSON.stringify(report, null, 2))
    // eslint-disable-next-line no-console
    console.log("\n================ FULL-APP STRESS REPORT ================")
    // eslint-disable-next-line no-console
    console.log(JSON.stringify({ ...report, samples: report.samples.slice(0, 25) }, null, 2))
    // eslint-disable-next-line no-console
    console.log(`Report written to ${outPath}`)

    // ---- health gates (each failure = a discovered class of bug) -------
    const gateFailures: string[] = []
    if (report.crashes.length > 0)
      gateFailures.push(`unexpected engine crashes on well-formed input: ${report.crashes.length}`)
    if (report.invariantViolations.length > 0)
      gateFailures.push(`engine invariant violations (well-formed input): ${report.invariantViolations.length}`)
    if (report.economic.nonFiniteFromFiniteInput > 0)
      gateFailures.push(`NaN/Infinity produced from finite input: ${report.economic.nonFiniteFromFiniteInput}`)
    if (report.economic.stateCorruptionAfterReject > 0)
      gateFailures.push(`borrow state corrupted after a rejected action: ${report.economic.stateCorruptionAfterReject}`)
    if (report.economic.multiplyNegativeEquity > 0)
      gateFailures.push(`multiply positions with negative equity: ${report.economic.multiplyNegativeEquity}`)
    if (report.economic.doubleClaim > 0)
      gateFailures.push(`rewards double-claims allowed: ${report.economic.doubleClaim}`)
    if (report.economic.claimAmountMismatch > 0)
      gateFailures.push(`reward claim amount mismatches: ${report.economic.claimAmountMismatch}`)
    if (report.economic.lendWithdrawExceededSupplied > 0)
      gateFailures.push(`lend withdraw exceeded supplied: ${report.economic.lendWithdrawExceededSupplied}`)
    if (report.economic.codecRoundTripLoss > 0)
      gateFailures.push(`session codec round-trip data loss: ${report.economic.codecRoundTripLoss}`)
    if (report.economic.borrowNotCreditedToWallet > 0)
      gateFailures.push(
        `borrow added debt without crediting wallet balance: ${report.economic.borrowNotCreditedToWallet}`,
      )
    if (report.economic.repayNotDebitedFromWallet > 0)
      gateFailures.push(
        `repay reduced debt without debiting wallet balance: ${report.economic.repayNotDebitedFromWallet}`,
      )

    // eslint-disable-next-line no-console
    console.log(
      "\nROBUSTNESS GAPS (malformed/chaos input, not gated):\n" +
        ` - engine persisted non-finite state from NaN/Infinity input: ${report.fuzzFindings.nonFiniteFromMalformedInput}\n` +
        ` - invariant violations from NaN/Infinity input: ${report.fuzzFindings.invariantViolationsFromMalformedInput}\n` +
        "   (engines accept NaN/Infinity numeric inputs and persist them instead of rejecting — add input guards)",
    )
    // eslint-disable-next-line no-console
    console.log("\nGATE FAILURES:\n" + (gateFailures.length ? gateFailures.map((g) => ` - ${g}`).join("\n") : " none"))
    // eslint-disable-next-line no-console
    console.log("=======================================================\n")

    expect(report.totalActions).toBe(USERS * ACTIONS_PER_USER)
    expect(gateFailures, gateFailures.join("\n")).toEqual([])
  }, 1_200_000)
})
