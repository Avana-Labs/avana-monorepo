import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

vi.mock("@/app/lib/i18n/use-translation", () => ({ useTranslation: () => ({ t: (s: string) => s, language: "en" }) }))
vi.mock("next/navigation", () => ({ useRouter: () => ({ push: vi.fn() }), usePathname: () => "/", useSearchParams: () => new URLSearchParams() }))

import { SearchTrigger } from "../search-trigger"

describe("header search field", () => {
  afterEach(() => cleanup())

  it("nests the Ask AI chip inside the search pill, as the reference header does", () => {
    render(<SearchTrigger />)
    const search = screen.getByRole("button", { name: "Search Avana" })
    const ask = screen.getByRole("button", { name: "Ask AI" })
    expect(search.parentElement).toBe(ask.closest("div.rounded-full"))
  })

  it("keeps the icon-only search free of the chip", () => {
    render(<SearchTrigger iconOnly />)
    expect(screen.queryByRole("button", { name: "Ask AI" })).toBeNull()
  })
})
