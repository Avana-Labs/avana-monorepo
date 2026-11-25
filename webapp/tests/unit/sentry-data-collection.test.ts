import { describe, expect, it, vi } from "vitest"

const init = vi.hoisted(() => vi.fn())
vi.mock("@sentry/nextjs", () => ({ init }))

// @sentry/core 10.71 treats ANY `dataCollection` object as "collect everything unless overridden",
// so the server and edge configs must override the fields that carry credentials and user data.
describe("server and edge Sentry data collection", () => {
  it.each(["../../sentry.server.config", "../../sentry.edge.config"])(
    "%s never attaches cookies, request bodies or user info",
    async (config) => {
      init.mockClear()
      vi.resetModules()
      await import(config)
      expect(init).toHaveBeenCalledTimes(1)
      expect(init.mock.calls[0]![0].dataCollection).toMatchObject({ cookies: false, userInfo: false, httpBodies: [] })
    },
  )
})
