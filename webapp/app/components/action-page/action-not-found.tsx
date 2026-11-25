"use client"

import Link from "next/link"
import { ActionPageShell } from "@/app/components/action-page/action-page-shell"
import { useTranslation } from "@/app/lib/i18n/use-translation"

export function ActionNotFound({
  closeHref = "/",
  title = "Action unavailable",
  message = "We couldn't find that action. It may have moved or the link is incomplete.",
}: {
  closeHref?: string
  title?: string
  message?: string
}) {
  const { t } = useTranslation()
  return (
    <ActionPageShell title={title} subtitle={undefined} closeHref={closeHref}>
      <div className="rounded-radius-md border-0 bg-card p-6 text-center" data-testid="action-not-found">
        <h2 className="text-[18px] font-medium text-foreground">{t(title)}</h2>
        <p className="mt-2 text-[14px] text-muted-foreground">{t(message)}</p>
        <Link
          href={closeHref}
          className="mt-5 inline-flex h-11 items-center justify-center rounded-full bg-foreground px-5 text-[15px] font-medium text-background transition-opacity hover:opacity-90"
        >
          {t("Go back")}
        </Link>
      </div>
    </ActionPageShell>
  )
}
