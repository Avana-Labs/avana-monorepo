import { describe, expect, it, vi } from "vitest"
import {
  applyRemotePreferences,
  normalizePreferences,
  serializePreferences,
  snapshotLocalPreferences,
  type LocalPreferenceState,
  type PreferenceSetters,
} from "@/app/components/preferences-sync"

const local: LocalPreferenceState = {
  theme: "light",
  language: "EN",
  currency: "USD",
  showDollarAmounts: true,
}

function mockSetters(): PreferenceSetters & {
  setTheme: ReturnType<typeof vi.fn>
  setLanguage: ReturnType<typeof vi.fn>
  setCurrency: ReturnType<typeof vi.fn>
  setShowDollarAmounts: ReturnType<typeof vi.fn>
} {
  return {
    setTheme: vi.fn(),
    setLanguage: vi.fn(),
    setCurrency: vi.fn(),
    setShowDollarAmounts: vi.fn(),
  }
}

describe("preferences-sync helpers", () => {
  it("normalizePreferences keeps valid fields and drops junk", () => {
    expect(
      normalizePreferences({
        theme: "dark",
        language: "ZZ" as never,
        currency: "EUR",
        showDollarAmounts: false,
      }),
    ).toEqual({ theme: "dark", currency: "EUR", showDollarAmounts: false })

    expect(normalizePreferences({ theme: "neon" as never })).toBeNull()
    expect(normalizePreferences(null)).toBeNull()
    expect(normalizePreferences(undefined)).toBeNull()
  })

  it("serializePreferences is stable for echo detection", () => {
    const a = serializePreferences({ theme: "dark", language: "ES", currency: "EUR", showDollarAmounts: false })
    const b = serializePreferences({ theme: "dark", language: "ES", currency: "EUR", showDollarAmounts: false })
    expect(a).toBe(b)
  })

  it("snapshotLocalPreferences copies the full local UI state", () => {
    expect(snapshotLocalPreferences(local)).toEqual({
      theme: "light",
      language: "EN",
      currency: "USD",
      showDollarAmounts: true,
    })
  })

  it("applyRemotePreferences only updates fields that differ", () => {
    const setters = mockSetters()
    const changed = applyRemotePreferences(
      { theme: "dark", language: "EN", currency: "EUR", showDollarAmounts: true },
      local,
      setters,
    )

    expect(changed).toBe(true)
    expect(setters.setTheme).toHaveBeenCalledWith("dark")
    expect(setters.setLanguage).not.toHaveBeenCalled()
    expect(setters.setCurrency).toHaveBeenCalledWith("EUR")
    expect(setters.setShowDollarAmounts).not.toHaveBeenCalled()
  })

  it("applyRemotePreferences is a no-op when remote matches local", () => {
    const setters = mockSetters()
    expect(applyRemotePreferences(snapshotLocalPreferences(local), local, setters)).toBe(false)
    expect(setters.setTheme).not.toHaveBeenCalled()
    expect(setters.setLanguage).not.toHaveBeenCalled()
    expect(setters.setCurrency).not.toHaveBeenCalled()
    expect(setters.setShowDollarAmounts).not.toHaveBeenCalled()
  })
})
