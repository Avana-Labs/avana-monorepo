import { renderToString } from "react-dom/server"
import { SearchTrigger } from "../search-trigger"
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
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

  const openAndLoad = async () => {
    render(<SearchCommand />)
    fireEvent.click(screen.getByRole("button", { name: "Search Avana" }))
    // Results load via dynamic import; wait until at least one option appears.
    await waitFor(() => expect(screen.getAllByRole("option").length).toBeGreaterThan(0))
    return screen.getByRole("combobox")
  }

  it("opens immediately after an intent-loaded trigger requests the module", () => {
    render(<SearchCommand initialOpen />)
    expect(screen.getByRole("dialog")).toBeInTheDocument()
  })

  it("shows loading state before results arrive, not an empty-results message", async () => {
    render(<SearchCommand />)
    fireEvent.click(screen.getByRole("button", { name: "Search Avana" }))

    expect(screen.getByText("Loading results")).toBeInTheDocument()
    expect(screen.queryByText("No results found")).not.toBeInTheDocument()

    await waitFor(() => expect(screen.getAllByRole("option").length).toBeGreaterThan(0))
    expect(screen.queryByText("Loading results")).not.toBeInTheDocument()
  })

  it("publishes result rows with non-blocking icons", async () => {
    await openAndLoad()

    const icon = screen.getAllByRole("option")[0].querySelector("img")
    expect(icon).not.toBeNull()
    expect(icon).toHaveAttribute("loading", "lazy")
    expect(icon).toHaveAttribute("decoding", "async")
    expect(icon).not.toHaveAttribute("fetchpriority", "high")
  })

  it("shows usable results even when image requests never finish", async () => {
    vi.stubGlobal("Image", class PendingImage {})
    const input = await openAndLoad()
    fireEvent.keyDown(input, { key: "Enter" })
    expect(push).toHaveBeenCalledTimes(1)
  })

  it("navigates results with ArrowDown/ArrowUp and opens with Enter", async () => {
    const input = await openAndLoad()

    const optionsBefore = screen.getAllByRole("option")
    expect(optionsBefore[0]).toHaveAttribute("aria-selected", "true")

    fireEvent.keyDown(input, { key: "ArrowDown" })
    const optionsAfterDown = screen.getAllByRole("option")
    expect(optionsAfterDown[0]).toHaveAttribute("aria-selected", "false")
    expect(optionsAfterDown[1]).toHaveAttribute("aria-selected", "true")

    fireEvent.keyDown(input, { key: "ArrowUp" })
    const optionsAfterUp = screen.getAllByRole("option")
    expect(optionsAfterUp[0]).toHaveAttribute("aria-selected", "true")

    fireEvent.keyDown(input, { key: "Enter" })
    expect(push).toHaveBeenCalledTimes(1)
    expect(push.mock.calls[0][0]).toBeTruthy()
  })

  it("keeps a valid active item after typing a query", async () => {
    const input = await openAndLoad()

    fireEvent.change(input, { target: { value: "usdc" } })
    await waitFor(() => expect(screen.getAllByRole("option").length).toBeGreaterThan(0))

    // First result is active after re-filtering.
    const options = screen.getAllByRole("option")
    expect(options[0]).toHaveAttribute("aria-selected", "true")

    fireEvent.keyDown(input, { key: "Enter" })
    expect(push).toHaveBeenCalledTimes(1)
  })

  it("labels a pool's fee tier as a 'pool fee' to distinguish it from the annualized borrow Fees APR", async () => {
    await openAndLoad()

    // Pool result subtitles read like "Venue / 0.30% pool fee / …" so the swap
    // fee tier isn't confused with the annualized "Fees" APR on borrow tables.
    await waitFor(() => expect(screen.getAllByText(/pool fee/i).length).toBeGreaterThan(0))
  })

  it("closes on a single Escape even when a query is present", async () => {
    const input = await openAndLoad()

    fireEvent.change(input, { target: { value: "usdc" } })
    await waitFor(() => expect(screen.getAllByRole("option").length).toBeGreaterThan(0))

    fireEvent.keyDown(input, { key: "Escape" })

    // One Escape must dismiss the dialog outright (no residual combobox/options).
    await waitFor(() => expect(screen.queryByRole("combobox")).not.toBeInTheDocument())
    expect(screen.queryAllByRole("option")).toHaveLength(0)
  })
})
