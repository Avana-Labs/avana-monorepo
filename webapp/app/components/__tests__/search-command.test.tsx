import { renderToString } from "react-dom/server"
import { SearchTrigger } from "../search-trigger"
import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"

const push = vi.fn()

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push }),
  usePathname: () => "/",
  useSearchParams: () => new URLSearchParams(),
}))

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (key: string) => key, language: "en" }),
}))

vi.mock("@/app/lib/page-loading", () => ({
  triggerPageLoading: vi.fn(),
}))

import { SearchCommand } from "@/app/components/search-command"

describe("SearchCommand keyboard navigation", () => {
  beforeEach(() => {
    class LoadedImage {
      complete = false
      onerror: (() => void) | null = null
      onload: (() => void) | null = null

      decode() {
        return Promise.resolve()
      }

      set src(_value: string) {
        this.complete = true
        queueMicrotask(() => this.onload?.())
      }
    }

    vi.stubGlobal("Image", LoadedImage)
  })

  afterEach(() => {
    cleanup()
    push.mockReset()
    vi.unstubAllGlobals()
  })

  it("keeps the server-rendered search trigger disabled until hydration", () => {
    const html = renderToString(<SearchTrigger iconOnly />)
    expect(html).toContain('disabled=""')
    render(<SearchTrigger iconOnly />)
    expect(screen.getByRole("button", { name: "Search Avana" })).toBeEnabled()
  })

  it("opens immediately after an intent-loaded trigger requests the module", () => {
    render(<SearchCommand initialOpen />)
    expect(screen.getByRole("dialog")).toBeInTheDocument()
  })

  it("lists the server index's markets when the header has no session", async () => {
    const fetchMock = vi.fn(async () =>
      new Response(
        JSON.stringify({
          pools: [],
          assets: [],
          lendMarkets: [
            {
              marketId: "ethereum-gho",
              asset: { symbol: "GHO", name: "Gho Token" },
              utilization: 0.1,
              supplyApy: 0.03,
            },
          ],
        }),
        { status: 200, headers: { "content-type": "application/json" } },
      ),
    )
    vi.stubGlobal("fetch", fetchMock)
    render(<SearchCommand initialOpen />)
    expect(await screen.findByText("Gho Token")).toBeInTheDocument()
    expect(fetchMock).toHaveBeenCalledWith("/api/search-index", expect.anything())
  })
})
