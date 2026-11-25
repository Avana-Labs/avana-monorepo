import { expect, it, vi } from "vitest"

const form = vi.hoisted(() => ({ appendToDom: vi.fn(), open: vi.fn(), removeFromDom: vi.fn() }))
const feedback = vi.hoisted(() => ({ createForm: vi.fn(async () => form) }))
const client = vi.hoisted(() => ({ addIntegration: vi.fn() }))
const sentry = vi.hoisted(() => ({
  init: vi.fn(),
  captureEvent: vi.fn(),
  captureException: vi.fn(() => "event-123"),
  captureRouterTransitionStart: vi.fn(),
  feedbackIntegration: vi.fn(() => feedback),
  getClient: vi.fn(() => client),
}))
vi.mock("@sentry/nextjs", () => sentry)
vi.mock("@/app/lib/web3/schedule-idle", () => ({ scheduleIdle: vi.fn() }))
vi.mock("@/app/lib/monitoring/sentry-enabled", () => ({ isSentryEnabled: () => true }))

const labels = {
  formTitle: "Report a bug",
  messageLabel: "What happened?",
  messagePlaceholder: "Tell us",
  isRequiredLabel: "(required)",
  submitButtonLabel: "Send report",
  cancelButtonLabel: "Cancel",
  successMessageText: "Thanks!",
}

it("returns the event id and opens a bug-report form tagged with it, registering the form once", async () => {
  const { captureException, openBugReportForm } = await import("../sentry-client")

  await expect(captureException(new Error("boom"))).resolves.toBe("event-123")

  await expect(openBugReportForm("event-123", labels)).resolves.toBe(true)
  expect(sentry.feedbackIntegration).toHaveBeenCalledWith(
    expect.objectContaining({ autoInject: false, enableScreenshot: false, showEmail: false }),
  )
  expect(client.addIntegration).toHaveBeenCalledWith(feedback)
  expect(feedback.createForm).toHaveBeenCalledWith(
    expect.objectContaining({ ...labels, tags: { error_event_id: "event-123" } }),
  )
  expect(form.appendToDom).toHaveBeenCalled()
  expect(form.open).toHaveBeenCalled()

  // Closing or finishing a submit removes the form from the page.
  const overrides = feedback.createForm.mock.calls[0][0] as { onFormClose: () => void; onFormSubmitted: () => void }
  overrides.onFormClose()
  overrides.onFormSubmitted()
  expect(form.removeFromDom).toHaveBeenCalledTimes(2)

  // Reopening reuses the registered integration.
  await openBugReportForm("event-123", labels)
  expect(sentry.feedbackIntegration).toHaveBeenCalledTimes(1)
  expect(client.addIntegration).toHaveBeenCalledTimes(1)
})
