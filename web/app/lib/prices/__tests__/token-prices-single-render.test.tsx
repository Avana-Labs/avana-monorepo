// @vitest-environment node
import * as React from "react"
import { PassThrough } from "node:stream"
import { renderToPipeableStream } from "react-dom/server"
import { describe, expect, it, vi } from "vitest"

vi.mock("@/app/lib/convex/market-liquidity-provider", () => ({ hasConvexClient: true }))
vi.mock("@/app/lib/test-mode", () => ({
  isLighthouseAuditMode: () => false,
  shouldUseOpenGateSession: () => false,
}))
// The realtime subscriber is lazy; on the server it suspends, exactly like production SSR.
vi.mock("@/app/lib/prices/convex-token-prices", () => ({ default: () => null }))

import { TokenPricesProvider } from "@/app/lib/prices/token-prices-context"

/** Streams like Next.js SSR (Suspense fallbacks first, resolved content in hidden chunks). */
function streamToHtml(element: React.ReactElement): Promise<string> {
  return new Promise((resolve, reject) => {
    const sink = new PassThrough()
    let html = ""
    sink.on("data", (chunk) => (html += chunk.toString()))
    sink.on("end", () => resolve(html))
    const { pipe } = renderToPipeableStream(element, {
      onAllReady: () => pipe(sink),
      onError: reject,
    })
  })
}

describe("TokenPricesProvider server render", () => {
  it("streams the page once, not once as a Suspense fallback and again as hidden content", async () => {
    const html = await streamToHtml(
      <TokenPricesProvider initialPrices={{ ETH: 3000 }}>
        <main>page body</main>
      </TokenPricesProvider>,
    )
    expect(html.match(/<main>/g)).toHaveLength(1)
  })
})
