import { pathToFileURL } from "node:url"
import nextEnv from "@next/env"
import { ConvexHttpClient } from "convex/browser"
import { api } from "../convex/_generated/api.js"

const { loadEnvConfig } = nextEnv

function required(name, env) {
  const value = env[name]?.trim()
  if (!value) throw new Error(`${name} is required.`)
  return value
}

export function walletFromAuthToken(token) {
  const parts = token.split(".")
  if (parts.length !== 3) throw new Error("AVANA_E2E_AUTH_TOKEN must be a JWT.")
  let payload
  try {
    payload = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"))
  } catch {
    throw new Error("AVANA_E2E_AUTH_TOKEN has an invalid JWT payload.")
  }
  const wallet = String(payload.wallet ?? payload.sub ?? "").toLowerCase()
  if (!wallet) throw new Error("AVANA_E2E_AUTH_TOKEN must contain a wallet or sub claim.")
  if (typeof payload.exp === "number" && payload.exp * 1000 <= Date.now()) {
    throw new Error("AVANA_E2E_AUTH_TOKEN is expired.")
  }
  return wallet
}

export function assertIsolatedStaging(env) {
  if (env.AVANA_E2E_STAGING !== "1") throw new Error("AVANA_E2E_STAGING=1 is required.")
  const stagingUrl = required("AVANA_E2E_CONVEX_URL", env).replace(/\/$/, "")
  const applicationUrl = required("NEXT_PUBLIC_CONVEX_URL", env).replace(/\/$/, "")
  if (stagingUrl === applicationUrl) {
    throw new Error("Refusing to prepare fixtures on NEXT_PUBLIC_CONVEX_URL; use an isolated staging deployment.")
  }
  if (!/^https:\/\/[^/]+\.convex\.cloud$/.test(stagingUrl) && !/^http:\/\/localhost(?::\d+)?$/.test(stagingUrl)) {
    throw new Error("AVANA_E2E_CONVEX_URL must be a Convex Cloud deployment or localhost.")
  }
  return stagingUrl
}

function positive(rows, state) {
  return rows.filter(
    (row) =>
      row.state === state &&
      Number.isFinite(row.amount) &&
      row.amount > 0 &&
      Number.isFinite(row.valueUsd) &&
      row.valueUsd > 0,
  )
}

function amountForUsd(row, targetUsd) {
  const priceUsd = row.valueUsd / row.amount
  const amount = Math.min(row.amount / 100, targetUsd / priceUsd)
  if (!Number.isFinite(amount) || amount <= 0) throw new Error("Fixture balance has an invalid token price.")
  return Number(amount.toPrecision(8)).toString()
}

export function actionFixturePaths(balances) {
  const collateral = positive(balances.borrow, "collateral").sort((a, b) => b.valueUsd - a.valueUsd)[0]
  if (!collateral?.marketId) throw new Error("Onboarding did not create funded borrow collateral.")

  const liquid = positive(balances.liquid, "available").sort((a, b) => {
    const stable = (row) => ["usdc", "usdt", "dai", "gho"].includes(row.assetId.toLowerCase())
    return Number(stable(b)) - Number(stable(a)) || b.valueUsd - a.valueUsd
  })[0]
  if (!liquid) throw new Error("Onboarding did not create a funded liquid borrow asset.")

  const multiplyCandidates = positive(balances.multiply, "position")
  const multiply = multiplyCandidates
    .map((row) => ({
      row,
      source: positive(balances.liquid, "available").find(
        (candidate) => candidate.assetId.toLowerCase() === row.assetId.toLowerCase(),
      ),
    }))
    .filter((candidate) => candidate.row.marketId && candidate.source)
    .sort((a, b) => b.source.valueUsd - a.source.valueUsd)[0]
  if (!multiply?.row.marketId || !multiply.source) {
    throw new Error("Onboarding did not create a multiply market backed by matching liquid collateral.")
  }

  const borrowAmount = amountForUsd(liquid, 10)
  const multiplyAmount = amountForUsd(multiply.source, 10)
  const query = (params) => new URLSearchParams(params).toString()
  const borrowParams = {
    market: collateral.marketId,
    asset: liquid.assetId,
    amount: borrowAmount,
  }
  return {
    AVANA_E2E_BORROW_PATH: `/actions/borrow/borrow?${query(borrowParams)}`,
    AVANA_E2E_MULTIPLY_PATH: `/actions/multiply/multiply?${query({
      market: multiply.row.marketId,
      amount: multiplyAmount,
    })}`,
    AVANA_E2E_REPAY_PATH: `/actions/borrow/repay?${query(borrowParams)}`,
  }
}

async function ensureOnboarded(client, wallet) {
  let state = await client.query(api.sandbox.onboarding.getWalletOnboardingState, { wallet })
  if (state.onboardingStep === "waitlisted") throw new Error("The staging wallet is waitlisted.")
  if (state.onboardingStep !== "done") {
    await client.mutation(api.sandbox.onboarding.beginAnalysis, { wallet })
    await client.mutation(api.sandbox.onboarding.startAnalysis, { wallet })
    await client.mutation(api.sandbox.onboarding.skipTweet, { wallet })
    await client.mutation(api.sandbox.onboarding.beginClaim, { wallet })
    const result = await client.mutation(api.sandbox.onboarding.claim, { wallet })
    if (result.status !== "done") throw new Error(`Staging onboarding ended in ${result.status}.`)
    state = await client.query(api.sandbox.onboarding.getWalletOnboardingState, { wallet })
  }
  if (state.onboardingStep !== "done") throw new Error("Staging onboarding did not persist.")
}

export async function prepareActionFixtures(env = process.env) {
  const stagingUrl = assertIsolatedStaging(env)
  const token = required("AVANA_E2E_AUTH_TOKEN", env)
  const wallet = walletFromAuthToken(token)
  const client = new ConvexHttpClient(stagingUrl, { auth: token, logger: false })
  await ensureOnboarded(client, wallet)
  const balances = await client.query(api.wallet.productBalances.listForWallet, { wallet })
  return { wallet, paths: actionFixturePaths(balances) }
}

async function main() {
  loadEnvConfig(process.cwd())
  const result = await prepareActionFixtures(process.env)
  process.stdout.write(
    `${Object.entries(result.paths)
      .map(([key, value]) => `${key}=${JSON.stringify(value)}`)
      .join("\n")}\n`,
  )
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    process.stderr.write(`${error instanceof Error ? error.message : String(error)}\n`)
    process.exitCode = 1
  })
}
