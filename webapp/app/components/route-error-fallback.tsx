"use client"

import Link from "next/link"
import { useEffect, useRef, useState } from "react"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { captureException, openBugReportForm, type BugReportLabels } from "@/app/lib/monitoring/sentry-client"

/**
 * Branded recovery UI shared by route-level error boundaries. Rendered when a
 * segment throws during render; `onRetry` re-attempts the segment and the link
 * offers a safe way back. Auth-shaped errors get a wallet-reconnect message.
 *
 * A real bug (not an auth refresh) is reported to Sentry and Sentry's bug-report form opens
 * once so the user can describe what happened; "Report this bug" reopens it. Both only appear
 * where Sentry reporting is on (Vercel deployments).
 */
export function RouteErrorFallback({
  onRetry,
  homeHref = "/dashboard",
  homeLabel = "Back to dashboard",
  title = "Something went wrong",
  message,
  error,
}: {
  onRetry: () => void
  homeHref?: string
  homeLabel?: string
  title?: string
  message?: string
  error?: Error
}) {
  const { t } = useTranslation()
  const isAuth = error ? /UNAUTHENTICATED|WALLET_MISMATCH|Not authenticated/i.test(error.message) : false
  const resolvedTitle = isAuth ? t("Your session needs a refresh") : t(title)
  const resolvedMessage =
    message ??
    (isAuth
      ? t("Reconnect your wallet to continue. Authenticated sessions stay locked until access is confirmed.")
      : t("This is on our side, not your wallet. Try again, and let us know if it keeps happening."))
  const [eventId, setEventId] = useState<string | null>(null)
  // Read through a ref so the effect below reports once per error, while the form still gets
  // the labels of the locale that has loaded by the time it opens.
  const tRef = useRef(t)
  useEffect(() => {
    tRef.current = t
  }, [t])

  useEffect(() => {
    if (!error || isAuth) return
    let cancelled = false
    void captureException(error).then((id) => {
      if (cancelled || !id) return
      void openBugReportForm(id, bugReportLabels(tRef.current)).then((opened) => {
        if (!cancelled && opened) setEventId(id)
      })
    })
    return () => {
      cancelled = true
    }
  }, [error, isAuth])

  return (
    <main className="mx-auto flex min-h-[70vh] w-full max-w-2xl flex-col items-start justify-center px-5 py-16">
      <h1 className="text-4xl font-medium tracking-[-0.04em]">{resolvedTitle}</h1>
      <p className="mt-6 max-w-prose text-muted-foreground">{resolvedMessage}</p>
      <div className="mt-8 flex flex-wrap gap-3">
        <button
          type="button"
          onClick={onRetry}
          className="inline-flex rounded-full bg-foreground px-6 py-3 text-sm font-semibold text-background transition hover:opacity-90"
        >
          {t("Try again")}
        </button>
        <Link
          href={homeHref}
          className="inline-flex rounded-full bg-muted px-6 py-3 text-sm font-semibold text-foreground transition hover:opacity-90"
        >
          {t(homeLabel)}
        </Link>
        {eventId ? (
          <button
            type="button"
            onClick={() => void openBugReportForm(eventId, bugReportLabels(t))}
            className="inline-flex rounded-full px-6 py-3 text-sm font-semibold text-muted-foreground transition hover:text-foreground"
          >
            {t("Report this bug")}
          </button>
        ) : null}
      </div>
    </main>
  )
}

function bugReportLabels(t: (key: string) => string): BugReportLabels {
  return {
    formTitle: t("Report a bug"),
    messageLabel: t("What happened?"),
    messagePlaceholder: t("Tell us what you were doing when this happened."),
    isRequiredLabel: t("(required)"),
    submitButtonLabel: t("Send report"),
    cancelButtonLabel: t("Cancel"),
    successMessageText: t("Thanks! Your report was sent."),
  }
}
