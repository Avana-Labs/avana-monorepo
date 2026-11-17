import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  RewardsEducationDialog,
  RewardsPinMarketDialog,
  RewardsRedeemDialog,
  RewardsReferralDialog,
} from "@/app/dashboard/_rewards-components/rewards-task-dialogs"

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (value: string) => value, language: "EN" }),
}))

afterEach(cleanup)

describe("rewards task dialogs", () => {
  it("records the risk primer when it is finished, and closes", async () => {
    const onComplete = vi.fn(async () => {})
    const onOpenChange = vi.fn()
    render(<RewardsEducationDialog open onOpenChange={onOpenChange} onComplete={onComplete} />)
    expect(screen.getByText("Risk primer")).toBeTruthy()
    fireEvent.click(screen.getByText("I read it"))
    await waitFor(() => expect(onOpenChange).toHaveBeenCalledWith(false))
    expect(onComplete).toHaveBeenCalledTimes(1)
  })

  it("pins the market that is picked, and closes", async () => {
    const onPin = vi.fn(async () => {})
    const onOpenChange = vi.fn()
    render(
      <RewardsPinMarketDialog
        open
        onOpenChange={onOpenChange}
        markets={[
          { id: "usdc-usdt", label: "USDC / USDT" },
          { id: "weth-usdc", label: "WETH / USDC" },
        ]}
        onPin={onPin}
      />,
    )
    fireEvent.click(screen.getByText("WETH / USDC"))
    await waitFor(() => expect(onOpenChange).toHaveBeenCalledWith(false))
    expect(onPin).toHaveBeenCalledWith("weth-usdc")
  })

  it("says so when there is no market to pin", () => {
    render(<RewardsPinMarketDialog open onOpenChange={() => {}} markets={[]} onPin={async () => {}} />)
    expect(screen.getByText("No markets to pin yet.")).toBeTruthy()
  })

  it("shows the invite link and the counts, and records the copy", async () => {
    const writeText = vi.fn(async () => {})
    Object.defineProperty(navigator, "clipboard", { value: { writeText }, configurable: true })
    const onCopy = vi.fn(async () => {})
    render(
      <RewardsReferralDialog
        open
        onOpenChange={() => {}}
        link="https://app.example.com/?ref=abcd2345"
        invited={3}
        active={1}
        onCopy={onCopy}
      />,
    )
    expect(screen.getByText("https://app.example.com/?ref=abcd2345")).toBeTruthy()
    expect(screen.getByText("3 invited · 1 active")).toBeTruthy()
    fireEvent.click(screen.getByText("Copy link"))
    await waitFor(() => expect(screen.getByText("Copied")).toBeTruthy())
    expect(writeText).toHaveBeenCalledWith("https://app.example.com/?ref=abcd2345")
    expect(onCopy).toHaveBeenCalledTimes(1)
  })

  it("cannot copy before the link is ready", () => {
    render(
      <RewardsReferralDialog open onOpenChange={() => {}} link={null} invited={0} active={0} onCopy={async () => {}} />,
    )
    expect(screen.getByText("Getting your link…")).toBeTruthy()
    expect((screen.getByText("Copy link") as HTMLButtonElement).disabled).toBe(true)
  })

  describe("redeeming points", () => {
    const rules = { pointsPerStep: 1000, bpsPerStep: 2, days: 30, maxBps: 4 }
    const open = (over: Partial<Parameters<typeof RewardsRedeemDialog>[0]> = {}) =>
      render(
        <RewardsRedeemDialog
          open
          onOpenChange={() => {}}
          available={2500}
          rules={rules}
          held={[]}
          onRedeem={async () => true}
          {...over}
        />,
      )

    it("offers the steps the points and the cap allow, and spends the chosen one", async () => {
      const onRedeem = vi.fn(async () => true)
      const onOpenChange = vi.fn()
      open({ onRedeem, onOpenChange })
      expect(screen.getByText("2500 points available")).toBeTruthy()
      expect(screen.getByText("1000 pts → 2 bps off")).toBeTruthy()
      expect(screen.getByText("2000 pts → 4 bps off")).toBeTruthy()
      expect(screen.queryByText("3000 pts → 6 bps off")).toBeNull()
      fireEvent.click(screen.getByText("2000 pts → 4 bps off"))
      fireEvent.click(screen.getByText("Redeem"))
      await waitFor(() => expect(onOpenChange).toHaveBeenCalledWith(false))
      expect(onRedeem).toHaveBeenCalledWith(2)
    })

    it("keeps the dialog open and says so when the redemption did not happen", async () => {
      const onOpenChange = vi.fn()
      open({ onRedeem: async () => false, onOpenChange })
      fireEvent.click(screen.getByText("Redeem"))
      await waitFor(() => expect(screen.getByText("Could not redeem. Try again.")).toBeTruthy())
      expect(onOpenChange).not.toHaveBeenCalledWith(false)
    })

    it("says what is missing when nothing can be redeemed", () => {
      open({ available: 400 })
      expect(screen.getByText("Not enough points yet: 1000 are needed.")).toBeTruthy()
      expect((screen.getByText("Redeem") as HTMLButtonElement).disabled).toBe(true)
    })

    it("says so at the cap, and lists the discounts held", () => {
      open({ available: 9000, held: [{ bps: 4, endsAt: 1_900_000_000_000 }] })
      expect(screen.getByText("You already hold the largest discount allowed.")).toBeTruthy()
      expect(screen.getByText("Active discounts")).toBeTruthy()
      expect(screen.getByText(/^4 bps off until /)).toBeTruthy()
    })
  })

  it("names the old demo environment nowhere", () => {
    const { baseElement } = render(
      <>
        <RewardsEducationDialog open onOpenChange={() => {}} onComplete={async () => {}} />
        <RewardsPinMarketDialog open onOpenChange={() => {}} markets={[]} onPin={async () => {}} />
      </>,
    )
    expect(baseElement.textContent ?? "").not.toMatch(/sand\s?box/i)
  })
})
