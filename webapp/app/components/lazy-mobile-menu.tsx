"use client"

import { useEffect, useState, type ComponentType } from "react"
import { useHydrated } from "@/app/lib/siwe/use-siwe-auth"
import { MenuToggleIcon } from "@/app/components/menu-toggle-icon"
import { useTranslation } from "@/app/lib/i18n/use-translation"

type MobileMenuComponent = ComponentType<{ initialOpen?: boolean }>
let mobileMenuPromise: Promise<MobileMenuComponent> | null = null
const loadMobileMenu = () => {
  mobileMenuPromise ??= import("./mobile-menu").then((mod) => mod.MobileMenu)
  return mobileMenuPromise
}

function MobileMenuTrigger({ onIntent, onOpen }: { onIntent: () => void; onOpen: () => void }) {
  const { t } = useTranslation()
  const hydrated = useHydrated()
  return (
    <button
      type="button"
      aria-label={t("Toggle menu")}
      aria-expanded={false}
      disabled={!hydrated}
      onPointerEnter={onIntent}
      onFocus={onIntent}
      onTouchStart={onIntent}
      onClick={onOpen}
      className="inline-flex h-10 w-10 items-center justify-center text-[#01AACF] transition hover:text-[#01AACF]/80 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand/40 focus-visible:ring-offset-2 focus-visible:ring-offset-background active:scale-95 [-webkit-tap-highlight-color:transparent] xl:hidden"
    >
      <MenuToggleIcon open={false} />
    </button>
  )
}

export function LazyMobileMenu() {
  const [requested, setRequested] = useState(false)
  const [Loaded, setLoaded] = useState<MobileMenuComponent | null>(null)

  useEffect(() => {
    if (!requested) return
    let active = true
    void loadMobileMenu().then((Component) => {
      if (active) setLoaded(() => Component)
    })
    return () => {
      active = false
    }
  }, [requested])

  if (Loaded) return <Loaded initialOpen />
  return <MobileMenuTrigger onIntent={() => void loadMobileMenu()} onOpen={() => setRequested(true)} />
}
