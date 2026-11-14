"use client"

import { useEffect } from "react"
import { captureException, openBugReportForm } from "@/app/lib/monitoring/sentry-client"

/**
 * Global error boundary — the last line of defence. It replaces the root layout
 * when the layout itself throws, so it must render its own <html>/<body> and
 * cannot rely on providers or fonts from RootLayout. Kept intentionally minimal
 * and self-contained (inline styles + local @font-face) so it renders even when
 * everything else has.
 */
const diatypeFace = `
@font-face {
  font-family: "Diatype";
  src: url("/fonts/diatype/core/ABCDiatypeVariable-Trial.woff2") format("woff2");
  font-weight: 400;
  font-style: normal;
  font-display: swap;
}
`

const GLOBAL_BUG_REPORT_LABELS = {
  formTitle: "Report a bug",
  messageLabel: "What happened?",
  messagePlaceholder: "Tell us what you were doing when this happened.",
  isRequiredLabel: "(required)",
  submitButtonLabel: "Send report",
  cancelButtonLabel: "Cancel",
  successMessageText: "Thanks! Your report was sent.",
}

export default function GlobalError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  useEffect(() => {
    // Always surface the error — production included — so incidents aren't invisible. In a
    // production build Next strips the message from the client error object but preserves
    // `error.digest`, which correlates to the server-side log entry (Vercel / Convex).
    // The root layout (and its i18n provider) is gone here, so the bug-report form is English.
    void captureException(error).then((eventId) => {
      if (eventId) void openBugReportForm(eventId, GLOBAL_BUG_REPORT_LABELS)
    })
    console.error("[global-error]", error, error.digest ? `digest=${error.digest}` : "")
  }, [error])

  return (
    <html lang="en">
      <head>
        <style dangerouslySetInnerHTML={{ __html: diatypeFace }} />
      </head>
      <body
        style={{
          margin: 0,
          minHeight: "100vh",
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          gap: "1.5rem",
          padding: "2rem",
          fontFamily: "Diatype, sans-serif",
          background: "#0b0b0f",
          color: "#f5f5f7",
          textAlign: "center",
        }}
      >
        <h1 style={{ margin: 0, fontSize: "2rem", fontWeight: 400, letterSpacing: "-0.04em" }}>Something went wrong</h1>
        <p style={{ margin: 0, maxWidth: "34rem", opacity: 0.8 }}>
          The app hit an unexpected error. Try again — if it keeps happening, please let us know.
        </p>
        {error.digest ? (
          <p style={{ margin: 0, fontSize: "0.75rem", opacity: 0.5, fontFamily: "Diatype, sans-serif" }}>
            Reference: {error.digest}
          </p>
        ) : null}
        <div style={{ display: "flex", flexWrap: "wrap", gap: "0.75rem", justifyContent: "center" }}>
          <button
            type="button"
            onClick={reset}
            style={{
              cursor: "pointer",
              border: "none",
              borderRadius: "9999px",
              padding: "0.75rem 1.5rem",
              fontSize: "0.875rem",
              fontWeight: 400,
              background: "#f5f5f7",
              color: "#0b0b0f",
            }}
          >
            Try again
          </button>
          <a
            href="/dashboard"
            style={{
              borderRadius: "9999px",
              padding: "0.75rem 1.5rem",
              fontSize: "0.875rem",
              fontWeight: 400,
              background: "rgba(255,255,255,0.1)",
              color: "#f5f5f7",
              textDecoration: "none",
            }}
          >
            Back to dashboard
          </a>
        </div>
      </body>
    </html>
  )
}
