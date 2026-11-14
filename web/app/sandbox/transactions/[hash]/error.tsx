"use client"

import { useEffect } from "react"
import Link from "next/link"
import { primaryCtaClass, secondaryCtaClass } from "@/app/components/action-page/action-cta"
import { useTranslation } from "@/app/lib/i18n/use-translation"

/**
 * Route-level boundary for the JWT-gated synthetic-receipt page. The receipt query can
 * throw UNAUTHENTICATED / WALLET_MISMATCH (no token, or a wallet that doesn't own the
 * receipt); without this it would fall through to the generic framework error page.
 * Render a graceful signed-out / not-found state instead.
 */
export default function SyntheticTransactionError({ error, reset }: { error: Error; reset: () => void }) {
  const { t } = useTranslation()
  useEffect(() => {
    if (process.env.NODE_ENV !== "production") console.error(error)
  }, [error])

  const isAuth = /UNAUTHENTICATED|WALLET_MISMATCH|Not authenticated/i.test(error.message)
  return (
    <main className="mx-auto flex min-h-[70vh] w-full max-w-md flex-col px-5 py-12 md:py-16">
      <header className="mb-6">
        <h1 className="text-[22px] font-medium leading-none tracking-[-0.03em] text-foreground md:text-[24px]">
          {t("Transaction receipt")}
        </h1>
      </header>
      <p className="text-muted-foreground">
        {isAuth
          ? t("Sign in with the wallet that created this transaction to view its receipt.")
          : t("We couldn't load this receipt right now.")}
      </p>
      <div className="mt-8 flex flex-col gap-3 sm:flex-row sm:items-center">
        <button
          className={primaryCtaClass({ size: "compact", className: "w-full sm:flex-1" })}
          onClick={reset}
          type="button"
        >
          {t("Try again")}
        </button>
        <Link href="/dashboard" className={secondaryCtaClass({ size: "compact", className: "w-full sm:flex-1" })}>
          {t("Back to dashboard")}
        </Link>
      </div>
    </main>
  )
}
