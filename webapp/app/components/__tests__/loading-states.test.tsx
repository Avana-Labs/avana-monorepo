import { cleanup, render, screen } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"

vi.mock("@/app/lib/i18n/use-translation", () => ({
  useTranslation: () => ({ t: (key: string) => key, language: "en" }),
}))

import { HomeWorkspaceSkeleton } from "@/app/components/loading-states"

describe("HomeWorkspaceSkeleton placeholder policy", () => {
  afterEach(cleanup)

  it("matches the unloaded swap card's zero-dollar values", () => {
    const { container } = render(<HomeWorkspaceSkeleton />)

    expect(screen.getAllByText("$0.00")).toHaveLength(2)
    expect(container.textContent).not.toContain("—")
  })
})
