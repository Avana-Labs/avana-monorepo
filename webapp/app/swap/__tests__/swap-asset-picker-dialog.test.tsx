import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { SwapAssetPickerDialog } from "@/app/swap/swap-asset-picker-dialog"
import type { SwapAsset } from "@/app/lib/swap-system"

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (value: string) => value }),
}))

vi.mock("@/app/lib/currency/use-currency", () => ({
  useCurrency: () => ({ exact: (value: number) => `$${value.toFixed(2)}` }),
}))

afterEach(() => cleanup())

const asset = (id: string, symbol: string, name: string): SwapAsset => ({
  id,
  chainId: 1,
  symbol,
  name,
  decimals: 18,
  assetType: "erc20",
  isNative: false,
  isLpToken: false,
  isSwapEnabled: true,
  priceUsd: 1,
  minimumSwapAmount: 0,
  maximumSwapAmount: 1,
})

function renderPicker(assets: SwapAsset[]) {
  return render(
    <SwapAssetPickerDialog
      open
      onOpenChange={() => {}}
      title="Select asset"
      assets={assets}
      balances={[]}
      selectedAssetId={assets[0]?.id ?? ""}
      excludedAssetId=""
      onSelect={() => {}}
    />,
  )
}

describe("SwapAssetPickerDialog token icons", () => {
  it("renders a real logo image for mapped tokens", () => {
    const assets = [
      asset("eth", "ETH", "Ether"),
      asset("usdc", "USDC", "USD Coin"),
      asset("gho", "GHO", "GHO"),
      asset("wbtc", "WBTC", "Wrapped Bitcoin"),
      asset("aave", "AAVE", "Aave Token"),
    ]
    renderPicker(assets)

    const expectedSrc: Record<string, string> = {
      ETH: "/asset-icons/w96/eth.webp",
      USDC: "/asset-icons/w96/usdc.webp",
      GHO: "/asset-icons/w96/gho.webp",
      WBTC: "/asset-icons/w96/wbtc.webp",
      AAVE: "/asset-icons/w96/aave.webp",
    }

    for (const item of assets) {
      const option = screen.getByRole("option", { name: `${item.name} (${item.symbol})` })
      const img = option.querySelector("img")
      // Regression guard: these tokens previously rendered as blank gray circles
      // because the picker routed through next/image. They must now render the same
      // plain <img> logo the rest of the app uses.
      expect(img, `${item.symbol} should render a logo image`).not.toBeNull()
      expect(img?.getAttribute("src")).toBe(expectedSrc[item.symbol])
    }
  })

  it("falls back to a colored symbol badge when a token has no logo", () => {
    // A genuinely unmapped symbol — absent from both TOKEN_MAP and the local-asset
    // alias map (LINK/CRVUSD/etc. now resolve real logos via the alias fallback).
    renderPicker([asset("zzz", "ZZZ", "Zzz Token")])

    const option = screen.getByRole("option", { name: "Zzz Token (ZZZ)" })
    // No logo image for an unmapped symbol...
    expect(option.querySelector("img")).toBeNull()
    // ...and a symbol badge is shown instead of a blank circle.
    const badge = option.firstElementChild as HTMLElement
    expect(badge.textContent).toBe("ZZZ")
    expect(badge.className).toContain("rounded-full")
  })
})
