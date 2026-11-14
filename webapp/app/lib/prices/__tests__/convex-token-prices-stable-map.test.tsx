import * as React from "react"
import { act, render } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { getFunctionName, type FunctionReference } from "convex/server"

const { useQuery } = vi.hoisted(() => ({ useQuery: vi.fn() }))
vi.mock("convex/react", () => ({ useQuery }))

import ConvexTokenPricesSubscriber from "@/app/lib/prices/convex-token-prices"
import type { LivePrices } from "@/app/lib/prices/token-prices-context"

describe("ConvexTokenPricesSubscriber", () => {
  beforeEach(() => {
    vi.useFakeTimers()
    const now = Date.now()
    const rows = [
      { symbol: "ETH", priceUsd: 3000, status: "fresh", fetchedAt: now, sourceUpdatedAt: now, updatedAt: now },
    ]
    const snapshot = {
      prices: rows,
      status: { updatedAt: now, staleAfterMs: 1_200_000, invalidAfterMs: 3_600_000, count: 1 },
    }
    const status = { updatedAt: now, staleAfterMs: 1_200_000, count: 1 }
    const fx = { rates: [] }
    const byName: Record<string, unknown> = {
      "prices:getPriceSnapshot": snapshot,
      "prices:getPriceStatus": status,
      "fx:getFxRates": fx,
    }
    useQuery.mockImplementation((ref: FunctionReference<"query">) => byName[getFunctionName(ref)])
  })
  afterEach(() => {
    vi.useRealTimers()
    useQuery.mockReset()
  })

  it("keeps the prices map identity across the 60s validation tick when nothing changed", () => {
    const published: LivePrices[] = []
    const onChange = (live: LivePrices) => published.push(live)
    render(<ConvexTokenPricesSubscriber onChange={onChange} />)
    const publishedBefore = published.length
    expect(published.at(-1)?.map.eth).toBe(3000)
    expect(published.at(-1)?.status?.count).toBe(1)

    act(() => {
      vi.advanceTimersByTime(60_000)
    })
    act(() => {
      vi.advanceTimersByTime(60_000)
    })

    // Same contents → same map/status identity → nothing re-published to consumers.
    expect(published.length).toBe(publishedBefore)
  })
})
