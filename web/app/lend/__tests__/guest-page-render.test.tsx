import { describe, expect, it, vi } from "vitest"

const { fetchLendPage } = vi.hoisted(() => ({ fetchLendPage: vi.fn(async () => ({})) }))

vi.mock("server-only", () => ({}))
vi.mock("next/headers", () => ({
  cookies: async () => ({ get: () => undefined }),
  headers: async () => new Headers(),
}))
vi.mock("@/app/lib/data/providers/lend", () => ({ fetchLendPage }))
vi.mock("@/app/lend/lend-client", () => ({ LendClient: () => null }))

import LendPage from "@/app/lend/page"

describe("lend page SSR for guests", () => {
  it("fetches and renders the real page without a session", async () => {
    await LendPage()
    expect(fetchLendPage).toHaveBeenCalledTimes(1)
  })
})
