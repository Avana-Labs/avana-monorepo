"use client"

import dynamic from "next/dynamic"
import { useState } from "react"
import { MoreHorizontal } from "@/app/components/icons"
import { useTranslation } from "@/app/lib/i18n/use-translation"

export const preferencesTriggerClassName =
  "inline-flex size-10 items-center justify-center rounded-full border border-border bg-background text-muted-foreground outline-none transition-colors hover:bg-hover hover:text-foreground focus:outline-none focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 focus-visible:ring-offset-2 focus-visible:ring-offset-background dark:bg-[#181818] dark:text-white/72 dark:hover:bg-surface-hover dark:hover:text-white [-webkit-tap-highlight-color:transparent]"

const loadMenu = () => import("./desktop-preference-controls").then((mod) => mod.DesktopPreferenceMenu)
const DesktopPreferenceMenu = dynamic(loadMenu, {
  ssr: false,
  loading: () => (
    <button type="button" aria-hidden tabIndex={-1} className={preferencesTriggerClassName}>
      <MoreHorizontal className="size-5" strokeWidth={2.35} />
    </button>
  ),
})

/**
 * Header preferences button. The Radix dropdown (menu + dismissable layer + floating-ui, ~40KB
 * gzipped) is only downloaded when the user shows intent (hover/focus) and mounted on click;
 * until then this is a plain button with the exact same box, so nothing shifts.
 */
export function DesktopPreferenceControls() {
  const { t } = useTranslation()
  const [requested, setRequested] = useState(false)

  if (requested) return <DesktopPreferenceMenu initialOpen />

  return (
    <button
      type="button"
      aria-label={t("Open preferences")}
      title={t("Preferences")}
      aria-haspopup="menu"
      aria-expanded="false"
      className={preferencesTriggerClassName}
      onPointerEnter={() => void loadMenu()}
      onFocus={() => void loadMenu()}
      onClick={() => setRequested(true)}
    >
      <MoreHorizontal className="size-5" strokeWidth={2.35} />
    </button>
  )
}
