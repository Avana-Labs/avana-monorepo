import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { ThemeProvider, useTheme } from "@/app/components/theme-provider"

const STORAGE_KEY = "theme-provider-test"

function ThemeToggle() {
  const { setTheme } = useTheme()
  return (
    <button type="button" onClick={() => setTheme("light")}>
      Light
    </button>
  )
}

function ThemeProbe() {
  const { theme, resolvedTheme } = useTheme()
  return (
    <div>
      <span data-testid="theme">{theme}</span>
      <span data-testid="resolved">{resolvedTheme}</span>
    </div>
  )
}

function fireThemeStorage(next: string | null, key = STORAGE_KEY) {
  window.dispatchEvent(
    new StorageEvent("storage", {
      key,
      newValue: next,
    }),
  )
}

describe("ThemeProvider", () => {
  beforeEach(() => {
    window.localStorage.clear()
    document.documentElement.classList.remove("dark")
    document.head.querySelectorAll('[data-avana-theme-transition="true"]').forEach((node) => node.remove())
    Object.defineProperty(window, "matchMedia", {
      configurable: true,
      value: vi.fn().mockImplementation((query: string) => ({
        matches: query === "(prefers-color-scheme: dark)",
        media: query,
        addEventListener: vi.fn(),
        removeEventListener: vi.fn(),
      })),
    })
  })

  afterEach(() => {
    cleanup()
    document.documentElement.classList.remove("dark")
  })

  it("removes the global animation guard immediately after applying each theme", async () => {
    render(
      <ThemeProvider defaultTheme="dark" storageKey={STORAGE_KEY}>
        <ThemeToggle />
      </ThemeProvider>,
    )

    await waitFor(() => expect(document.documentElement).toHaveClass("dark"))
    expect(document.head.querySelector('[data-avana-theme-transition="true"]')).toBeNull()

    fireEvent.click(screen.getByRole("button", { name: "Light" }))

    await waitFor(() => expect(document.documentElement).not.toHaveClass("dark"))
    expect(document.head.querySelector('[data-avana-theme-transition="true"]')).toBeNull()
  })

  it("applies a theme change written by another tab", async () => {
    render(
      <ThemeProvider defaultTheme="light" storageKey={STORAGE_KEY}>
        <ThemeProbe />
      </ThemeProvider>,
    )

    await waitFor(() => expect(screen.getByTestId("resolved")).toHaveTextContent("light"))

    window.localStorage.setItem(STORAGE_KEY, "dark")
    fireThemeStorage("dark")

    await waitFor(() => {
      expect(screen.getByTestId("theme")).toHaveTextContent("dark")
      expect(screen.getByTestId("resolved")).toHaveTextContent("dark")
      expect(document.documentElement).toHaveClass("dark")
    })
  })

  it("ignores storage events for unrelated keys and invalid themes", async () => {
    render(
      <ThemeProvider defaultTheme="light" storageKey={STORAGE_KEY}>
        <ThemeProbe />
      </ThemeProvider>,
    )

    await waitFor(() => expect(screen.getByTestId("resolved")).toHaveTextContent("light"))

    fireThemeStorage("dark", "unrelated-key")
    fireThemeStorage("neon")

    expect(screen.getByTestId("theme")).toHaveTextContent("light")
    expect(document.documentElement).not.toHaveClass("dark")
  })
})
