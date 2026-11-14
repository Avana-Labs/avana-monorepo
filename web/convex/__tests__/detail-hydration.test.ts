// @vitest-environment edge-runtime
import { convexTest } from "convex-test"
import { describe, expect, test } from "vitest"
import schema from "../schema"
import { api } from "../_generated/api"

const modules = import.meta.glob("../**/*.*s")

describe("batched detail hydration", () => {
  test("returns product-scoped envelopes without cross-product reads", async () => {
    const t = convexTest(schema, modules)

    const [lend, multiply, pool, asset] = await Promise.all([
      t.query(api.detailHydration.getLendDetail, { slug: "usdc" }),
      t.query(api.detailHydration.getMultiplyDetail, { slug: "eth-usdt" }),
      t.query(api.detailHydration.getBorrowPoolDetail, { slug: "pool" }),
      t.query(api.detailHydration.getBorrowAssetDetail, { slug: "uni-v2:usdc" }),
    ])

    expect(lend.snapshot).toBeNull()
    expect(multiply.snapshot).toBeNull()
    expect(pool.snapshot).toBeNull()
    expect(asset.snapshot).toBeNull()
    expect(lend.siloedMarket).toBeNull()
    expect(multiply.siloedMarket).toBeNull()
    expect(pool.siloedMarket).toBeNull()
    expect(asset.siloedMarket).toBeNull()
  })
})
