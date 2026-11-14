import { cleanup, render, screen, waitFor, act } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { useEffect, useState, type ReactNode } from "react"
import { DisplayPreferencesProvider, useLocaleDisplayPreferences } from "@/app/components/display-preferences"
import { ThemeProvider, useTheme } from "@/app/components/theme-provider"

vi.mock("@/app/lib/currency/exchange-rates", () => ({
  applyCachedLiveRates: vi.fn(),
  fetchLiveRates: vi.fn(async () => false),
}))

const profileState: { current: { preferences?: Record<string, unknown> } | null | undefined } = {
  current: undefined,
}
const savePreferences = vi.fn(async () => "updated" as const)

vi.mock("convex/react", () => ({
  useConvexAuth: () => ({ isAuthenticated: true }),
  useQuery: () => profileState.current,
  useMutation: () => savePreferences,
}))

vi.mock("@/convex/_generated/api", () => ({
  api: { wallet: { profiles: { getMine: "getMine", savePreferences: "savePreferences" } } },
}))

import { PreferencesProfileSyncConnected } from "@/app/components/preferences-profile-sync-connected"

function Probes() {
  const { theme } = useTheme()
  const { language, currency } = useLocaleDisplayPreferences()
  return (
    <div>
      <span data-testid="theme">{theme}</span>
      <span data-testid="language">{language}</span>
      <span data-testid="currency">{currency}</span>
    </div>
  )
}

/** Keeps providers + sync mounted; bump() re-renders so useQuery sees profileState updates. */
function SyncHarness({ wallet, children }: { wallet: string; children?: ReactNode }) {
  const [, setTick] = useState(0)
  useEffect(() => {
    const bump = () => setTick((tick) => tick + 1)
    ;(window as unknown as { __bumpPrefsSync?: () => void }).__bumpPrefsSync = bump
    return () => {
      delete (window as unknown as { __bumpPrefsSync?: () => void }).__bumpPrefsSync
    }
  }, [])
  return (
    <>
      <PreferencesProfileSyncConnected wallet={wallet} />
      <Probes />
      {children}
    </>
  )
}

function bumpSync() {
  act(() => {
    ;(window as unknown as { __bumpPrefsSync?: () => void }).__bumpPrefsSync?.()
  })
}

function renderSync(wallet = "0xabc") {
  return render(
    <ThemeProvider defaultTheme="light" storageKey="prefs-sync-live-test">
      <DisplayPreferencesProvider>
        <SyncHarness wallet={wallet} />
      </DisplayPreferencesProvider>
    </ThemeProvider>,
  )
}

describe("PreferencesProfileSyncConnected live multi-device sync", () => {
  beforeEach(() => {
    window.localStorage.clear()
    profileState.current = undefined
    savePreferences.mockClear()
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: vi.fn().mockImplementation((query: string) => ({
        matches: false,
        media: query,
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
      })),
    })
  })

  afterEach(() => {
    cleanup()
    vi.useRealTimers()
  })

  it("bootstraps local UI from remote preferences on first profile load", async () => {
    // Match production timing: ThemeProvider hydrates before prefs sync mounts/applies.
    profileState.current = undefined
    renderSync()
    await waitFor(() => expect(screen.getByTestId("theme")).toHaveTextContent("light"))

    profileState.current = {
      preferences: { theme: "dark", language: "ES", currency: "EUR", showDollarAmounts: false },
    }
    bumpSync()

    await waitFor(() => {
      expect(screen.getByTestId("theme")).toHaveTextContent("dark")
      expect(screen.getByTestId("language")).toHaveTextContent("ES")
      expect(screen.getByTestId("currency")).toHaveTextContent("EUR")
    })
    expect(savePreferences).not.toHaveBeenCalled()
  })

  it("seeds Convex from local preferences when the profile has none", async () => {
    profileState.current = undefined
    renderSync()
    await waitFor(() => expect(screen.getByTestId("theme")).toHaveTextContent("light"))

    profileState.current = { preferences: undefined }
    bumpSync()

    await waitFor(() => expect(savePreferences).toHaveBeenCalledTimes(1))
    expect(savePreferences).toHaveBeenCalledWith({
      preferences: {
        theme: "light",
        language: "EN",
        currency: "USD",
        showDollarAmounts: true,
      },
    })
  })

  it("applies live remote preference updates after bootstrap without remounting", async () => {
    profileState.current = undefined
    renderSync()
    await waitFor(() => expect(screen.getByTestId("theme")).toHaveTextContent("light"))

    profileState.current = {
      preferences: { theme: "light", language: "EN", currency: "USD", showDollarAmounts: true },
    }
    bumpSync()
    await waitFor(() => expect(screen.getByTestId("currency")).toHaveTextContent("USD"))
    savePreferences.mockClear()

    profileState.current = {
      preferences: { theme: "dark", language: "FR", currency: "GBP", showDollarAmounts: true },
    }
    bumpSync()

    await waitFor(() => {
      expect(screen.getByTestId("theme")).toHaveTextContent("dark")
      expect(screen.getByTestId("language")).toHaveTextContent("FR")
      expect(screen.getByTestId("currency")).toHaveTextContent("GBP")
    })
    expect(savePreferences).not.toHaveBeenCalled()
  })

  it("does not re-save when a remote echo matches the last applied key", async () => {
    vi.useFakeTimers()
    profileState.current = undefined
    renderSync()

    await act(async () => {
      await vi.runAllTimersAsync()
    })

    profileState.current = {
      preferences: { theme: "dark", language: "EN", currency: "USD", showDollarAmounts: true },
    }
    bumpSync()

    await act(async () => {
      await vi.runAllTimersAsync()
    })
    savePreferences.mockClear()

    profileState.current = {
      preferences: { theme: "dark", language: "EN", currency: "USD", showDollarAmounts: true },
    }
    bumpSync()

    await act(async () => {
      await vi.advanceTimersByTimeAsync(500)
    })
    expect(savePreferences).not.toHaveBeenCalled()
  })

  it("re-bootstraps when the wallet changes", async () => {
    profileState.current = undefined
    const { rerender } = render(
      <ThemeProvider defaultTheme="light" storageKey="prefs-sync-live-test">
        <DisplayPreferencesProvider>
          <SyncHarness wallet="0xaaa" />
        </DisplayPreferencesProvider>
      </ThemeProvider>,
    )
    await waitFor(() => expect(screen.getByTestId("theme")).toHaveTextContent("light"))

    profileState.current = {
      preferences: { theme: "dark", language: "ES", currency: "EUR", showDollarAmounts: false },
    }
    bumpSync()
    await waitFor(() => expect(screen.getByTestId("language")).toHaveTextContent("ES"))

    profileState.current = {
      preferences: { theme: "light", language: "JA", currency: "JPY", showDollarAmounts: true },
    }
    rerender(
      <ThemeProvider defaultTheme="light" storageKey="prefs-sync-live-test">
        <DisplayPreferencesProvider>
          <SyncHarness wallet="0xbbb" />
        </DisplayPreferencesProvider>
      </ThemeProvider>,
    )

    await waitFor(() => {
      expect(screen.getByTestId("language")).toHaveTextContent("JA")
      expect(screen.getByTestId("currency")).toHaveTextContent("JPY")
      expect(screen.getByTestId("theme")).toHaveTextContent("light")
    })
  })
})
