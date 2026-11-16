// @vitest-environment edge-runtime
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Avana Labs
// Fee points: the ERC-20 fee transfer in a confirmed transaction's receipt, from the wallet to the fee recipient,
// priced at the Hub asset's price: 1 point per whole dollar, once per transaction.
import { convexTest } from "convex-test"
import { keccak256, toBytes } from "viem"
import { describe, expect, test } from "vitest"
import { fixtureHubAsset } from "@avana/services-common/fixtures"
import { internal, api } from "../../convex/_generated/api"
import { awardFeePoints, feeTransfers, feeUsdOf, TRANSFER_TOPIC, type ReceiptLog } from "../../convex/lib/feePoints"
import schema from "../../convex/schema"

const modules = import.meta.glob("../../convex/**/*.*s")
const WALLET = "0xAbC0000000000000000000000000000000000001"
const RECIPIENT = "0x00000000000000000000000000000000000000f1"
const TOKEN = fixtureHubAsset.underlying.toLowerCase()
const TX = `0x${"ab".repeat(32)}`
const pad = (a: string) => `0x${"0".repeat(24)}${a.slice(2).toLowerCase()}`
const word = (n: bigint) => `0x${n.toString(16).padStart(64, "0")}`
const transfer = (token: string, from: string, to: string, value: bigint): ReceiptLog => ({
  address: token,
  topics: [TRANSFER_TOPIC, pad(from), pad(to)],
  data: word(value),
})

describe("fee transfers in a receipt", () => {
  test("the topic is the ERC-20 Transfer event", () => {
    expect(keccak256(toBytes("Transfer(address,address,uint256)"))).toBe(TRANSFER_TOPIC)
  })

  test("keeps the transfers from the wallet to the recipient, summed per token, and nothing else", () => {
    const other = "0x00000000000000000000000000000000000000e2"
    const logs: ReceiptLog[] = [
      transfer(TOKEN, WALLET, RECIPIENT, 1_000_000n),
      transfer(TOKEN, WALLET, RECIPIENT, 500_000n),
      transfer(TOKEN, WALLET, other, 9n),
      transfer(TOKEN, other, RECIPIENT, 9n),
      transfer(other, WALLET, RECIPIENT, 7n),
      { address: TOKEN, topics: [TRANSFER_TOPIC, pad(WALLET), pad(RECIPIENT), word(1n)], data: "0x" },
      { address: TOKEN, topics: ["0x" + "11".repeat(32), pad(WALLET), pad(RECIPIENT)], data: word(5n) },
    ]
    expect(feeTransfers(logs, WALLET, RECIPIENT).sort((a, b) => a.token.localeCompare(b.token))).toEqual(
      [
        { token: TOKEN, amount: "1500000" },
        { token: other, amount: "7" },
      ].sort((a, b) => a.token.localeCompare(b.token)),
    )
    expect(feeTransfers([], WALLET, RECIPIENT)).toEqual([])
  })
})

async function seeded() {
  const t = convexTest(schema, modules)
  await t.run(async (ctx) => {
    await ctx.db.insert("hubAssets", { ...fixtureHubAsset, slug: "usdc", updatedAt: 0, decimals: 6, priceUsd8: "100000000", lendReserves: [...fixtureHubAsset.lendReserves] })
  })
  return t
}

describe("fee points", () => {
  test("values the transfers at the Hub asset price and ignores a token with no price", async () => {
    const t = await seeded()
    const usd = await t.run((ctx) =>
      feeUsdOf(ctx, fixtureHubAsset.chainId, [
        { token: TOKEN, amount: "12500000" },
        { token: "0x00000000000000000000000000000000000000e2", amount: "999" },
        { token: TOKEN, amount: "oops" },
      ]),
    )
    expect(usd).toBe(12.5)
  })

  test("awards one point per whole dollar, once per transaction", async () => {
    const t = await seeded()
    const transfers = [{ token: TOKEN, amount: "12500000" }]
    const chainId = fixtureHubAsset.chainId
    const first = await t.mutation(internal.intents.awardFee, { wallet: WALLET, chainId, txHash: TX, transfers })
    const again = await t.mutation(internal.intents.awardFee, { wallet: WALLET, chainId, txHash: TX.toUpperCase().replace("0X", "0x"), transfers })
    expect([first, again]).toEqual([12, 0])
    const small = await t.run((ctx) => awardFeePoints(ctx, { wallet: WALLET, chainId, txHash: `0x${"cd".repeat(32)}`, transfers: [{ token: TOKEN, amount: "900000" }], at: 1 }))
    expect(small).toBe(0)
    expect(await t.query(api.wallet.rewards.summary, { wallet: WALLET })).toMatchObject({ feePoints: 12, questPoints: 0 })
  })
})
