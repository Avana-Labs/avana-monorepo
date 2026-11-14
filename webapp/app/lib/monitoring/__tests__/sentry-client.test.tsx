import { expect, it, vi } from "vitest"

const sentry = vi.hoisted(() => ({
  init: vi.fn(),
  captureEvent: vi.fn(),
  captureException: vi.fn(),
  captureRouterTransitionStart: vi.fn(),
}))
vi.mock("@sentry/nextjs", () => sentry)
vi.mock("@/app/lib/web3/schedule-idle", () => ({ scheduleIdle: vi.fn() }))
vi.mock("@/app/lib/monitoring/sentry-enabled", () => ({ isSentryEnabled: () => true }))

it("reports CSP source diagnostics with bounded duplicates while keeping both exceptions visible", async () => {
  const { scheduleSentryLoad } = await import("../sentry-client")
  scheduleSentryLoad()
  const dispatch = (lineNumber: number) => {
    const event = new Event("securitypolicyviolation")
    Object.assign(event, {
      disposition: "enforce",
      blockedURI: "eval",
      effectiveDirective: "script-src",
      sourceFile: "https://app.avana.cc/wallet.js?private=value",
      lineNumber,
      columnNumber: 30,
    })
    window.dispatchEvent(event)
  }
  dispatch(234)
  dispatch(234)
  await vi.waitFor(() => expect(sentry.captureEvent).toHaveBeenCalledTimes(1))
  expect(sentry.captureEvent).toHaveBeenCalledWith(
    expect.objectContaining({
      contexts: {
        csp: {
          source_file: "https://app.avana.cc/wallet.js",
          line_number: 234,
          column_number: 30,
          directive: "script-src",
        },
      },
    }),
  )
  for (let line = 1; line <= 10; line++) dispatch(line)
  await vi.waitFor(() => expect(sentry.captureEvent).toHaveBeenCalledTimes(5))

  const options = sentry.init.mock.calls[0][0]
  // Neither error is silenced by a blunt ignoreErrors substring match.
  for (const message of [
    "Proposal expired",
    "Refused to evaluate a string as JavaScript because 'unsafe-eval' is not an allowed source",
  ]) {
    expect(options.ignoreErrors.some((pattern: RegExp) => pattern.test(message))).toBe(false)
  }
  // "Proposal expired" is a real (now-fixed) wallet timeout, so it stays visible.
  const proposalExpired = { exception: { values: [{ type: "Error", value: "Proposal expired" }] } }
  expect(options.beforeSend(proposalExpired)).toBe(proposalExpired)
  // The extension-injected CSP EvalError is unactionable, so beforeSend drops it before it ships.
  const blockedEval = {
    exception: {
      values: [
        {
          type: "EvalError",
          value:
            "Refused to evaluate a string as JavaScript because 'unsafe-eval' is not an allowed source of script...",
        },
      ],
    },
  }
  expect(options.beforeSend(blockedEval)).toBeNull()
})
