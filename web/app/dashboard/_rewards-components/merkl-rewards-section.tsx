"use client"

import { LockKeyhole } from "@/app/components/icons"
import { Card } from "@/components/ui/card"
import { useTranslation } from "@/app/lib/i18n/use-translation"

/**
 * Merkl reward campaigns aren't live yet and there's no real Merkl data source wired up,
 * so this shows an honest "coming soon" state rather than fabricated AVA reward amounts.
 */
export function MerklRewardsSection() {
  const { t } = useTranslation()

  return (
    <section aria-label={t("Merkl Rewards")} className="space-y-4">
      <h2 className="text-[16px] font-normal tracking-tight text-foreground md:text-[18px]">{t("Merkl Rewards")}</h2>
      <Card className="flex flex-col items-center rounded-radius-md border border-border/60 bg-card px-6 py-10 text-center shadow-none">
        <div className="flex size-12 items-center justify-center rounded-full bg-muted/60 text-muted-foreground [&_svg]:size-6">
          <LockKeyhole />
        </div>
        <p className="mt-4 text-[15px] font-normal text-foreground">{t("Coming soon")}</p>
        <p className="mt-1.5 max-w-sm text-[13px] text-muted-foreground">
          {t("Merkl reward campaigns will appear here once they launch.")}
        </p>
      </Card>
    </section>
  )
}
