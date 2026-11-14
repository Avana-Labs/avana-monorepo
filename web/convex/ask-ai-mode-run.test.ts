// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import { afterEach } from "vitest"
import { api, internal } from "./_generated/api"
import schema from "./schema"

const modules = import.meta.glob("./**/*.*s")
const WALLET_A = "0x00000000000000000000000000000000000000aa"
const WALLET_B = "0x00000000000000000000000000000000000000bb"

async function seed(t: ReturnType<typeof convexTest>, wallet: string) {
  return t.run(async (ctx) => {
    const positionId = await ctx.db.insert("positions", {
      wallet,
      product: "multiply",
      marketSlug: "eth-usdc",
      assetId: "ETH",
      status: "open",
      collateralValueUsd: 10_000,
      debtValueUsd: 3_500,
      openedAt: 1,
      lastUpdatedAt: 2,
    })
    await ctx.db.insert("markets", {
      scope: "multiply",
      slug: "eth-usdc",
      chainId: 1,
      name: "ETH / USDC",
      symbol: "ETH/USDC",
      maxLtvPct: 55,
      constituents: [
        { symbol: "ETH", weight: 0.5 },
        { symbol: "USDC", weight: 0.5 },
      ],
      createdAt: 1,
    })
    await ctx.db.insert("multiplyTokenParameters", {
      symbol: "ETH",
      supplyApyPct: 3,
      borrowAprPct: 5,
      availableUsd: 1_000_000,
      collateralFactorPct: 55,
      liquidationThresholdPct: 65,
      iconUrl: "/eth.svg",
      updatedAt: 1,
    })
    return positionId
  })
}

describe("buildModeRun", () => {
  test("assembles a risk run off the owner's live position", async () => {
    const t = convexTest(schema, modules)
    const positionId = await seed(t, WALLET_A)
    const result = await t
      .withIdentity({ subject: WALLET_A })
      .query(api.askAiModeRun.buildModeRun, { mode: "risk", queryText: "am I safe?", positionId })
    expect(result).toMatchObject({ walletRequired: false, rerouted: false })
    if (result.walletRequired === false) {
      expect(result.run.mode).toBe("risk")
      expect(result.run.widgets.map((w) => w.type)).toContain("risk_summary")
      expect(result.run.snapshotId).toMatch(/^snap_/)
    }
  })

  test("reroutes a leverage question asked in Returns mode to Risk", async () => {
    const t = convexTest(schema, modules)
    const positionId = await seed(t, WALLET_A)
    const result = await t
      .withIdentity({ subject: WALLET_A })
      .query(api.askAiModeRun.buildModeRun, { mode: "returns", queryText: "should I loop this?", positionId })
    expect(result).toMatchObject({ walletRequired: false, rerouted: true })
    if (result.walletRequired === false) expect(result.run.mode).toBe("risk")
  })

  test("returns wallet-required for a guest", async () => {
    const t = convexTest(schema, modules)
    const positionId = await seed(t, WALLET_A)
    await expect(
      t
        .withIdentity({ subject: "ask-guest:test" })
        .query(api.askAiModeRun.buildModeRun, { mode: "risk", queryText: "hi", positionId }),
    ).resolves.toMatchObject({ walletRequired: true })
  })

  test("does not expose another wallet's position", async () => {
    const t = convexTest(schema, modules)
    const positionId = await seed(t, WALLET_A)
    await expect(
      t
        .withIdentity({ subject: WALLET_B })
        .query(api.askAiModeRun.buildModeRun, { mode: "risk", queryText: "hi", positionId }),
    ).rejects.toThrow("Position not found")
  })
})

async function seedTurn(t: ReturnType<typeof convexTest>, wallet: string, prompt: string) {
  return t.run(async (ctx) =>
    ctx.db.insert("askAITurns", {
      threadId: "thread-1",
      ownerSubject: wallet,
      wallet,
      promptMessageId: "pm-1",
      prompt,
      status: "running",
      createdAt: 1,
      updatedAt: 1,
    }),
  )
}

describe("buildModeRunForTurn (flag-gated per-turn trigger)", () => {
  afterEach(() => {
    delete process.env.NEXT_PUBLIC_ASK_AI_MODE_RUNS
  })

  test("classifies a mode prompt and builds a run for the wallet's single position when enabled", async () => {
    process.env.NEXT_PUBLIC_ASK_AI_MODE_RUNS = "1"
    const t = convexTest(schema, modules)
    const positionId = await seed(t, WALLET_A)
    const turnId = await seedTurn(t, WALLET_A, "am I safe?")
    const run = await t.query(internal.askAiModeRun.buildModeRunForTurn, { turnId, prompt: "am I safe?", positionId })
    expect(run?.mode).toBe("risk")
    expect(run?.widgets.map((w) => w.type)).toContain("risk_summary")
  })

  test("returns null when the feature flag is off (default)", async () => {
    const t = convexTest(schema, modules)
    await seed(t, WALLET_A)
    const turnId = await seedTurn(t, WALLET_A, "am I safe?")
    expect(await t.query(internal.askAiModeRun.buildModeRunForTurn, { turnId, prompt: "am I safe?" })).toBeNull()
  })

  test("returns null when the prompt is not a mode question", async () => {
    process.env.NEXT_PUBLIC_ASK_AI_MODE_RUNS = "1"
    const t = convexTest(schema, modules)
    await seed(t, WALLET_A)
    const turnId = await seedTurn(t, WALLET_A, "what markets do you support?")
    expect(
      await t.query(internal.askAiModeRun.buildModeRunForTurn, { turnId, prompt: "what markets do you support?" }),
    ).toBeNull()
  })

  test("returns null when the wallet has no position", async () => {
    process.env.NEXT_PUBLIC_ASK_AI_MODE_RUNS = "1"
    const t = convexTest(schema, modules)
    const turnId = await seedTurn(t, WALLET_A, "am I safe?")
    expect(await t.query(internal.askAiModeRun.buildModeRunForTurn, { turnId, prompt: "am I safe?" })).toBeNull()
  })
})

describe("per-turn mode-run scope", () => {
  afterEach(() => {
    delete process.env.NEXT_PUBLIC_ASK_AI_MODE_RUNS
  })
  test("does not read a personal position for a public market question addressed to me", async () => {
    process.env.NEXT_PUBLIC_ASK_AI_MODE_RUNS = "1"
    const t = convexTest(schema, modules)
    await seed(t, WALLET_A)
    const prompt = "Show me the current GHO supply APY"
    const turnId = await seedTurn(t, WALLET_A, prompt)
    expect(await t.query(internal.askAiModeRun.buildModeRunForTurn, { turnId, prompt })).toBeNull()
  })
  test("omits the implicit card when two positions could be selected", async () => {
    process.env.NEXT_PUBLIC_ASK_AI_MODE_RUNS = "1"
    const t = convexTest(schema, modules)
    const positionId = await seed(t, WALLET_A)
    await t.run((ctx) =>
      ctx.db.insert("positions", {
        wallet: WALLET_A,
        product: "borrow",
        marketSlug: "another-market",
        status: "open",
        collateralValueUsd: 1_000,
        debtValueUsd: 900,
        openedAt: 1,
        lastUpdatedAt: 2,
      }),
    )
    const prompt = "am I safe?"
    const turnId = await seedTurn(t, WALLET_A, prompt)
    expect(await t.query(internal.askAiModeRun.buildModeRunForTurn, { turnId, prompt })).toBeNull()
    expect(await t.query(internal.askAiModeRun.buildModeRunForTurn, { turnId, prompt, positionId })).toMatchObject({
      mode: "risk",
    })
    const foreignPositionId = await t.run((ctx) =>
      ctx.db.insert("positions", {
        wallet: WALLET_B,
        product: "multiply",
        marketSlug: "eth-usdc",
        assetId: "ETH",
        status: "open",
        collateralValueUsd: 10_000,
        debtValueUsd: 3_500,
        openedAt: 1,
        lastUpdatedAt: 2,
      }),
    )
    expect(
      await t.query(internal.askAiModeRun.buildModeRunForTurn, { turnId, prompt, positionId: foreignPositionId }),
    ).toBeNull()
    // Explicit position selection remains available and wallet-scoped.
    expect(
      await t.withIdentity({ subject: WALLET_A }).query(api.askAiModeRun.buildModeRun, {
        positionId,
        mode: "risk",
        queryText: prompt,
      }),
    ).toMatchObject({ walletRequired: false, run: { mode: "risk" } })
  })
})
