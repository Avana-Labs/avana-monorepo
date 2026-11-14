import { act, cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { useState, type ReactElement } from "react"
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest"
import type { LanguageCode } from "@/app/components/display-preferences"
import { TRANSLATIONS, translate } from "@/app/lib/i18n/translations"
import {
  ASSET_TABS,
  BORROW_MARKET_OPTIONS,
  CHAIN_OPTIONS,
  EMPTY_MARKET_FILTERS,
  HUB_OPTIONS,
  LEND_MARKET_OPTIONS,
  buildAssetOptions,
  lendFilterItem,
  type MarketFilterState,
} from "@/app/lib/markets/filters"

const i18n = vi.hoisted(() => ({ language: "EN" as string }))

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({
    language: i18n.language,
    t: (key: string) => (i18n.language === "EN" ? key : translate(i18n.language as LanguageCode, key)),
  }),
}))

import { MarketFiltersBar } from "@/app/lib/ui/market-filters"

beforeAll(() => {
  // Radix positions the panel with ResizeObserver; jsdom has none.
  globalThis.ResizeObserver ??= class {
    observe() {}
    unobserve() {}
    disconnect() {}
  } as unknown as typeof ResizeObserver
  window.HTMLElement.prototype.scrollIntoView ??= () => {}
  window.HTMLElement.prototype.hasPointerCapture ??= () => false
  window.HTMLElement.prototype.releasePointerCapture ??= () => {}
})

afterEach(() => {
  cleanup()
  i18n.language = "EN"
})

const ROWS = [
  { symbol: "USDC", name: "USD Coin" },
  { symbol: "USDT", name: "Tether USD" },
  { symbol: "WETH", name: "Wrapped Ether" },
  { symbol: "WBTC", name: "Wrapped BTC" },
  { symbol: "AAVE", name: "Aave Token" },
]

function Harness({ onChange }: { onChange?: (next: MarketFilterState) => void }) {
  const [value, setValue] = useState<MarketFilterState>(EMPTY_MARKET_FILTERS)
  const [search, setSearch] = useState("")
  return (
    <MarketFiltersBar
      items={ROWS.map((row) => lendFilterItem(row.symbol))}
      value={value}
      onChange={(update) => {
        setValue((current) => {
          const next = typeof update === "function" ? update(current) : update
          onChange?.(next)
          return next
        })
      }}
      marketOptions={LEND_MARKET_OPTIONS}
      assetOptions={buildAssetOptions(ROWS)}
      search={search}
      onSearchChange={setSearch}
      searchPlaceholder="Search assets"
    />
  )
}

/** Renders, then waits for the lazily loaded Radix popover to replace the static pills. */
async function renderBar(ui: ReactElement) {
  const result = render(ui)
  await waitFor(() => expect(result.container.querySelector("[data-pill=static]")).toBeNull())
  return result
}

function openFacet(name: RegExp) {
  fireEvent.click(screen.getByRole("button", { name }))
  return screen.getByRole("dialog")
}

describe("MarketFiltersBar", () => {
  it("renders the four filter pills and the page search once", () => {
    render(<Harness />)
    for (const name of [/All Chains/, /^Hubs$/, /^Markets$/, /^Assets$/]) {
      expect(screen.getAllByRole("button", { name })).toHaveLength(1)
    }
    expect(screen.getAllByRole("textbox", { name: "Search assets" })).toHaveLength(1)
  })

  it("opens a pill clicked before the popover chunk loads", async () => {
    render(<Harness />)
    fireEvent.click(screen.getByRole("button", { name: /^Hubs$/ }))
    // The popover chunk loads on first use; a busy runner can take several seconds.
    const panel = await screen.findByRole("dialog", {}, { timeout: 15_000 })
    expect(within(panel).getByText("Hubs", { selector: "span" })).toBeInTheDocument()
  }, 20_000)

  it("opens and closes a panel from its pill", async () => {
    await renderBar(<Harness />)
    const trigger = screen.getByRole("button", { name: /All Chains/ })
    expect(trigger).toHaveAttribute("aria-expanded", "false")
    fireEvent.click(trigger)
    expect(trigger).toHaveAttribute("aria-expanded", "true")
    const panel = screen.getByRole("dialog")
    expect(within(panel).getByText("Filter by")).toBeInTheDocument()
    for (const chain of CHAIN_OPTIONS) {
      expect(within(panel).getByRole("checkbox", { name: new RegExp(chain.label) })).toBeInTheDocument()
    }
    fireEvent.keyDown(panel, { key: "Escape" })
    expect(screen.queryByRole("dialog")).toBeNull()
    expect(trigger).toHaveAttribute("aria-expanded", "false")
  })

  it("names the chain pill after the selection", async () => {
    const onChange = vi.fn()
    await renderBar(<Harness onChange={onChange} />)
    const panel = openFacet(/All Chains/)
    fireEvent.click(within(panel).getByRole("checkbox", { name: /Ethereum/ }))
    expect(onChange).toHaveBeenLastCalledWith({ ...EMPTY_MARKET_FILTERS, chains: ["ethereum"] })
    expect(within(panel).getByRole("checkbox", { name: /Ethereum/ })).toHaveAttribute("aria-checked", "true")
    expect(screen.getByRole("button", { name: /^Ethereum/ })).toBeInTheDocument()
    fireEvent.click(within(panel).getByRole("checkbox", { name: /Local/ }))
    expect(screen.getByRole("button", { name: /Chains \(2\)/ })).toBeInTheDocument()
  })

  it("shows the selection count on the pill and clears it from the × and from Clear", async () => {
    const onChange = vi.fn()
    await renderBar(<Harness onChange={onChange} />)
    const panel = openFacet(/^Hubs$/)
    const clear = within(panel).getByRole("button", { name: "Clear" })
    expect(clear).toBeDisabled()
    fireEvent.click(within(panel).getByRole("checkbox", { name: /Stable/ }))
    fireEvent.click(within(panel).getByRole("checkbox", { name: /Correlated/ }))
    expect(screen.getByRole("button", { name: "Hubs (2)" })).toBeInTheDocument()
    expect(clear).toBeEnabled()
    fireEvent.click(clear)
    expect(onChange).toHaveBeenLastCalledWith(EMPTY_MARKET_FILTERS)

    fireEvent.click(within(panel).getByRole("checkbox", { name: /Volatile/ }))
    fireEvent.click(screen.getByRole("button", { name: "Clear Hubs filter" }))
    expect(onChange).toHaveBeenLastCalledWith(EMPTY_MARKET_FILTERS)
    expect(screen.getByRole("button", { name: /^Hubs$/ })).toBeInTheDocument()
  })

  it("keeps every option when toggled in quick succession", async () => {
    await renderBar(<Harness />)
    const panel = openFacet(/^Markets$/)
    const [first, second] = within(panel).getAllByRole("checkbox")
    act(() => {
      first.click()
      second.click()
    })
    expect(screen.getByRole("button", { name: "Markets (2)" })).toBeInTheDocument()
  })

  it("shows per-option counts that follow the other active filters", async () => {
    await renderBar(<Harness />)
    const hubs = openFacet(/^Hubs$/)
    // 2 stablecoins, WETH + WBTC correlated, AAVE volatile.
    expect(within(hubs).getByRole("checkbox", { name: /Stable/ })).toHaveTextContent("2")
    expect(within(hubs).getByRole("checkbox", { name: /Correlated/ })).toHaveTextContent("2")
    fireEvent.click(within(hubs).getByRole("checkbox", { name: /Stable/ }))
    fireEvent.keyDown(hubs, { key: "Escape" })

    const markets = openFacet(/^Markets$/)
    expect(within(markets).getByRole("checkbox", { name: /Forex Based/ })).toHaveTextContent("2")
    expect(within(markets).getByRole("checkbox", { name: /ETH Based/ })).toHaveTextContent("0")
  })

  it("narrows a panel's options with its search box", async () => {
    await renderBar(<Harness />)
    const panel = openFacet(/^Markets$/)
    fireEvent.change(within(panel).getByRole("textbox", { name: "Search markets" }), { target: { value: "eth" } })
    expect(within(panel).getAllByRole("checkbox")).toHaveLength(1)
    fireEvent.change(within(panel).getByRole("textbox", { name: "Search markets" }), { target: { value: "zzz" } })
    expect(within(panel).queryAllByRole("checkbox")).toHaveLength(0)
    expect(within(panel).getByText("No matches")).toBeInTheDocument()
  })

  it("groups assets under tabs and hides tabs with no assets", async () => {
    await renderBar(<Harness />)
    const panel = openFacet(/^Assets$/)
    const tabs = within(panel).getAllByRole("tab")
    expect(tabs.map((tab) => tab.textContent)).toEqual(["All", "Stablecoins", "ETH", "BTC", "Other"])
    expect(within(panel).getAllByRole("checkbox")).toHaveLength(5)
    fireEvent.click(within(panel).getByRole("tab", { name: "Stablecoins" }))
    expect(
      within(panel)
        .getAllByRole("checkbox")
        .map((row) => row.textContent),
    ).toEqual(["Tether USDUSDT", "USD CoinUSDC"])
    fireEvent.click(within(panel).getByRole("checkbox", { name: /USD Coin/ }))
    expect(screen.getByRole("button", { name: "Assets (1)" })).toBeInTheDocument()
  })

  it("offers a single Clear all once anything is filtered", async () => {
    const onChange = vi.fn()
    await renderBar(<Harness onChange={onChange} />)
    expect(screen.queryByRole("button", { name: "Clear all" })).toBeNull()
    const panel = openFacet(/^Hubs$/)
    fireEvent.click(within(panel).getByRole("checkbox", { name: /Stable/ }))
    fireEvent.keyDown(panel, { key: "Escape" })
    fireEvent.click(screen.getByRole("button", { name: "Clear all" }))
    expect(onChange).toHaveBeenLastCalledWith(EMPTY_MARKET_FILTERS)
  })

  it("lists the Borrow DEXes", async () => {
    await renderBar(
      <MarketFiltersBar
        items={[]}
        value={EMPTY_MARKET_FILTERS}
        onChange={() => {}}
        marketOptions={BORROW_MARKET_OPTIONS}
        assetOptions={[]}
        search=""
        onSearchChange={() => {}}
        searchPlaceholder="Filter markets"
      />,
    )
    const panel = openFacet(/^Markets$/)
    expect(within(panel).getByRole("checkbox", { name: /Uniswap V3/ })).toBeEnabled()
    expect(within(panel).getByRole("checkbox", { name: /Aerodrome Slipstream/ })).toBeEnabled()
  })

  it("renders translated labels", async () => {
    i18n.language = "DE"
    await renderBar(<Harness />)
    expect(screen.getByRole("button", { name: /Alle Chains/ })).toBeInTheDocument()
    const panel = openFacet(/^Knotenpunkte$/)
    expect(within(panel).getByRole("checkbox", { name: /Stabil/ })).toBeInTheDocument()
    expect(within(panel).getByRole("button", { name: "Löschen" })).toBeInTheDocument()
    act(() => {
      fireEvent.keyDown(panel, { key: "Escape" })
    })
  })
})

describe("filter labels are translated in every locale", () => {
  const LOCALES: LanguageCode[] = ["AR", "DE", "ES", "FR", "HI", "ID", "JA", "KO", "NL", "PT", "RU", "TR", "ZH"]
  // Option labels are translated at runtime (not as t("…") literals), so the source-key parity
  // gate can't see them; check them here. Acronym tabs (ETH, BTC) read the same everywhere.
  const RUNTIME_KEYS = [
    ...CHAIN_OPTIONS.filter((option) => !option.brand).map((option) => option.label),
    ...HUB_OPTIONS.map((option) => option.label),
    ...LEND_MARKET_OPTIONS.map((option) => option.label),
    ...ASSET_TABS.filter((tab) => tab.id !== "eth" && tab.id !== "btc").map((tab) => tab.label),
    "Chains",
    "Hubs",
    "Markets",
    "Assets",
  ]

  it.each(LOCALES)("%s", (language) => {
    // A key may legitimately read the same as English (German "Chains"), as long as the locale
    // declares it; a key the locale never declares is an untranslated fallback.
    const dict = TRANSLATIONS[language] ?? {}
    const missing = RUNTIME_KEYS.filter((key) => !(key in dict) && translate(language, key) === key)
    expect(missing).toEqual([])
  })
})
