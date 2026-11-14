import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it } from "vitest"
import { DisplayPreferencesProvider } from "@/app/components/display-preferences"
import { AvanaSessionsProvider } from "@/app/lib/avana-session/avana-sessions-provider"
import {
  UmbrellaMobileSidebarSheet,
  type UmbrellaMobileSheetTrigger,
} from "@/app/umbrella/_detail/UmbrellaMobileSidebarSheet"

// Regression: mobile CTAs pass initialTab (Stake / Unstake) into the sheet so
// the matching tab is selected on open rather than always landing on Stake.
function renderSheet(initialTab?: UmbrellaMobileSheetTrigger) {
  return render(
    <DisplayPreferencesProvider>
      <AvanaSessionsProvider walletId="umbrella-sheet-test" persistLocalState={false}>
        <UmbrellaMobileSidebarSheet open onOpenChange={() => {}} moduleId="usdc" initialTab={initialTab} />
      </AvanaSessionsProvider>
    </DisplayPreferencesProvider>,
  )
}

function tab(name: string) {
  return screen.getByRole("tab", { name })
}

afterEach(() => {
  cleanup()
})

describe("UmbrellaMobileSidebarSheet", () => {
  it("opens on Stake by default when no initialTab is passed", () => {
    renderSheet()
    expect(tab("Stake")).toHaveAttribute("aria-selected", "true")
  })

  it("opens on Cooldown when initialTab is cooldown", () => {
    renderSheet("cooldown")
    expect(tab("Cooldown")).toHaveAttribute("aria-selected", "true")
    expect(tab("Stake")).toHaveAttribute("aria-selected", "false")
  })

  it("opens on Unstake when initialTab is unstake", () => {
    renderSheet("unstake")
    expect(tab("Unstake")).toHaveAttribute("aria-selected", "true")
    expect(tab("Stake")).toHaveAttribute("aria-selected", "false")
  })

  it("opens on Claim when initialTab is claim", () => {
    renderSheet("claim")
    expect(tab("Claim")).toHaveAttribute("aria-selected", "true")
    expect(tab("Stake")).toHaveAttribute("aria-selected", "false")
  })
})
