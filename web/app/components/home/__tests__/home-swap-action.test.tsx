import { lazy, Suspense, type ComponentType } from "react"
import { cleanup, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, expect, it, vi } from "vitest"
import { HomeSwapAction } from "../home-swap-action"
import { AvanaSessionsProvider } from "@/app/lib/avana-session/avana-sessions-provider"
import { MockSwapProvider } from "@/app/lib/swap-system"
import { TransactAccessContext } from "@/app/lib/transact-access"

const { loadPicker } = vi.hoisted(() => ({ loadPicker: vi.fn() }))
vi.mock("next/dynamic", () => ({
  default: (loader: () => Promise<ComponentType>) => {
    const Component = lazy(async () => {
      loadPicker()
      return { default: await loader() }
    })
    return function DynamicPicker(props: Record<string, unknown>) {
      return (
        <Suspense fallback={null}>
          <Component {...props} />
        </Suspense>
      )
    }
  },
}))
vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (value: string) => value }),
}))
vi.mock("@/app/lib/currency/use-currency", () => ({
  useCurrency: () => ({ exact: (value: number) => `$${value.toFixed(2)}` }),
}))
afterEach(() => cleanup())

it("loads the asset picker on demand and preserves sell/buy selection across openings", async () => {
  render(
    <AvanaSessionsProvider walletId="demo-wallet" persistLocalState={false}>
      <HomeSwapAction />
    </AvanaSessionsProvider>,
  )
  expect(loadPicker).not.toHaveBeenCalled()
  fireEvent.click(screen.getByRole("button", { name: /^Sell asset/ }))
  const sellDialog = await screen.findByRole("dialog")
  fireEvent.click(within(sellDialog).getByRole("option", { name: "Ether (ETH)" }))
  expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  expect(screen.getByRole("button", { name: /^Sell asset/ })).toHaveTextContent("ETH")

  fireEvent.click(screen.getByRole("button", { name: /^Buy asset/ }))
  const buyDialog = await screen.findByRole("dialog")
  fireEvent.click(within(buyDialog).getByRole("option", { name: "USD Coin (USDC)" }))
  expect(screen.queryByRole("dialog")).not.toBeInTheDocument()
  expect(screen.getByRole("button", { name: /^Buy asset/ })).toHaveTextContent("USDC")
  expect(loadPicker).toHaveBeenCalledTimes(1)
})

it("sends a guest to the dashboard onboarding instead of reviewing a swap", () => {
  render(
    <TransactAccessContext.Provider value="guest">
      <AvanaSessionsProvider walletId="demo-wallet" persistLocalState={false}>
        <HomeSwapAction />
      </AvanaSessionsProvider>
    </TransactAccessContext.Provider>,
  )
  const cta = screen.getByTestId("action-footer-primary")
  expect(cta).toHaveTextContent("Get Started")
  expect(cta).toHaveAttribute("href", "/dashboard")
})

it("names each asset picker with its visible text, so voice control can target it", () => {
  render(
    <AvanaSessionsProvider walletId="demo-wallet" persistLocalState={false}>
      <HomeSwapAction />
    </AvanaSessionsProvider>,
  )
  // Sell starts on ETH; Buy starts empty.
  expect(screen.getByRole("button", { name: /^Sell asset/ })).toHaveAccessibleName(/^Sell asset:\s*ETH$/)
  expect(screen.getByRole("button", { name: /^Buy asset/ })).toHaveAccessibleName(/^Buy asset:\s*Select Asset$/)
})
