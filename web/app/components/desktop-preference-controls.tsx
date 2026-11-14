"use client"

import Link from "next/link"
import {
  ArrowUpRight,
  BookOpen,
  Check,
  ChevronLeft,
  ChevronRight,
  FileText,
  LifeBuoy,
  Mail,
  MoonStar,
  MoreHorizontal,
  ShieldCheck,
  SunMedium,
} from "@/app/components/icons"
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu"
import { PriceFreshnessNotice } from "./prices/price-freshness-notice"
import { CurrencyFlag } from "./currency-flag"
import { CURRENCY_OPTIONS, LANGUAGE_OPTIONS, useLocaleDisplayPreferences } from "./display-preferences"
import { useTheme } from "./theme-provider"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { useEffect, useState } from "react"

import { AVANA_EXTERNAL_LINKS } from "./external-links"
import { preferencesTriggerClassName } from "./desktop-preference-trigger"

type PreferencesView = "root" | "language" | "currency" | "network"

const NETWORK_OPTIONS = [
  { code: "Local", label: "Local", unavailable: false },
  { code: "Ethereum", label: "Ethereum", unavailable: true },
  { code: "Avalanche", label: "Avalanche", unavailable: true },
  { code: "Base", label: "Base", unavailable: true },
  { code: "Arbitrum", label: "Arbitrum", unavailable: true },
  { code: "Robinhood", label: "Robinhood", unavailable: true },
] as const

const HELP_LINKS = [
  { href: AVANA_EXTERNAL_LINKS.terms, label: "Terms of Service", icon: FileText, external: true },
  { href: AVANA_EXTERNAL_LINKS.privacy, label: "Privacy policy", icon: ShieldCheck, external: true },
  { href: "mailto:support@avana.cc?subject=Avana%20Support", label: "Contact us", icon: Mail, external: true },
  { href: "/support-center", label: "Support center", icon: LifeBuoy, external: false },
  { href: AVANA_EXTERNAL_LINKS.developers, label: "Docs", icon: BookOpen, external: true },
] as const

export function DesktopPreferenceMenu({ initialOpen = false }: { initialOpen?: boolean }) {
  const { currency, language, setCurrency, setLanguage } = useLocaleDisplayPreferences()
  const { resolvedTheme, setTheme } = useTheme()
  const { t } = useTranslation()
  const [mounted, setMounted] = useState(false)
  const [open, setOpen] = useState(initialOpen)
  const [view, setView] = useState<PreferencesView>("root")

  useEffect(() => {
    setMounted(true)
  }, [])

  const currentLanguage = LANGUAGE_OPTIONS.find((option) => option.code === language) ?? LANGUAGE_OPTIONS[0]
  const currentCurrency = CURRENCY_OPTIONS.find((option) => option.code === currency) ?? CURRENCY_OPTIONS[0]
  const currentNetwork = NETWORK_OPTIONS[0]

  return (
    <DropdownMenu
      modal={false}
      open={open}
      onOpenChange={(nextOpen) => {
        setOpen(nextOpen)
        if (!nextOpen) setView("root")
      }}
    >
      <DropdownMenuTrigger asChild>
        <button
          type="button"
          aria-label={t("Open preferences")}
          title={t("Preferences")}
          className={preferencesTriggerClassName}
        >
          <MoreHorizontal className="size-5" strokeWidth={2.35} />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent
        align="end"
        sideOffset={10}
        className="w-[296px] rounded-[22px] border border-border bg-background/98 p-2 text-foreground shadow-2xl backdrop-blur dark:border-white/10 dark:bg-[#121212]/98 dark:text-white"
      >
        {view === "root" ? (
          <>
            <DropdownMenuLabel className="px-3 py-2.5 text-[16px] font-medium normal-case tracking-normal text-foreground dark:text-white">
              {t("Global preferences")}
            </DropdownMenuLabel>
            <PriceFreshnessNotice className="px-3 pb-1" />
            <div className="space-y-2 px-3 pb-1">
              <div className="flex items-center justify-between gap-3">
                <span className="text-[14px] text-muted-foreground dark:text-white/64">{t("Theme")}</span>
                <div className="flex items-center overflow-hidden rounded-full border border-border bg-surface p-1 dark:border-white/12 dark:bg-[#1a1a1a]">
                  <button
                    type="button"
                    onClick={() => setTheme("light")}
                    className={`rounded-full px-2.5 py-1.5 text-[13px] font-medium ${
                      mounted && resolvedTheme === "light"
                        ? "bg-foreground text-background dark:bg-[#2a2a2a] dark:text-white"
                        : "text-muted-foreground dark:text-white/64"
                    }`}
                  >
                    <SunMedium className="h-4 w-4" />
                  </button>
                  <button
                    type="button"
                    onClick={() => setTheme("dark")}
                    className={`rounded-full px-2.5 py-1.5 text-[13px] font-medium ${
                      mounted && resolvedTheme === "dark"
                        ? "bg-foreground text-background dark:bg-[#2a2a2a] dark:text-white"
                        : "text-muted-foreground dark:text-white/64"
                    }`}
                  >
                    <MoonStar className="h-4 w-4" />
                  </button>
                </div>
              </div>
            </div>
            <DropdownMenuItem
              className="flex cursor-pointer items-center justify-between rounded-[16px] px-3 py-3 text-[14px] text-foreground outline-none hover:bg-hover focus:bg-hover dark:text-white"
              onSelect={(event) => {
                event.preventDefault()
                setView("language")
              }}
            >
              <span className="text-muted-foreground dark:text-white/64">{t("Language")}</span>
              <span className="flex items-center gap-2 font-medium text-foreground dark:text-white">
                {currentLanguage.label}
                <ChevronRight className="h-4 w-4 text-muted-foreground dark:text-white/52" />
              </span>
            </DropdownMenuItem>
            <DropdownMenuItem
              className="flex cursor-pointer items-center justify-between rounded-[16px] px-3 py-3 text-[14px] text-foreground outline-none hover:bg-hover focus:bg-hover dark:text-white"
              onSelect={(event) => {
                event.preventDefault()
                setView("currency")
              }}
            >
              <span className="text-muted-foreground dark:text-white/64">{t("Currency")}</span>
              <span className="flex items-center gap-2 font-medium text-foreground dark:text-white">
                {currentCurrency.code}
                <ChevronRight className="h-4 w-4 text-muted-foreground dark:text-white/52" />
              </span>
            </DropdownMenuItem>
            <DropdownMenuItem
              className="flex cursor-pointer items-center justify-between rounded-[16px] px-3 py-3 text-[14px] text-foreground outline-none hover:bg-hover focus:bg-hover dark:text-white"
              onSelect={(event) => {
                event.preventDefault()
                setView("network")
              }}
            >
              <span className="text-muted-foreground dark:text-white/64">{t("Network")}</span>
              <span className="flex items-center gap-2 font-medium text-foreground dark:text-white">
                <span>{currentNetwork.label}</span>
                <ChevronRight className="h-4 w-4 text-muted-foreground dark:text-white/52" />
              </span>
            </DropdownMenuItem>

            <DropdownMenuSeparator className="mx-1 my-1.5 bg-border dark:bg-white/10" />
            {HELP_LINKS.map(({ href, label, icon: Icon, external }) =>
              external ? (
                <DropdownMenuItem
                  key={label}
                  asChild
                  className="cursor-pointer rounded-[16px] px-3 py-2.5 text-[14px] text-foreground outline-none hover:bg-hover focus:bg-hover dark:text-white"
                >
                  <a href={href} target="_blank" rel="noreferrer" className="flex items-center justify-between gap-3">
                    <span className="flex items-center gap-2.5">
                      <Icon className="h-4 w-4 text-muted-foreground dark:text-white/64" strokeWidth={1.8} />
                      <span>{t(label)}</span>
                    </span>
                    <ArrowUpRight className="h-3.5 w-3.5 text-muted-foreground/70" aria-hidden />
                  </a>
                </DropdownMenuItem>
              ) : (
                <DropdownMenuItem
                  key={label}
                  asChild
                  className="cursor-pointer rounded-[16px] px-3 py-2.5 text-[14px] text-foreground outline-none hover:bg-hover focus:bg-hover dark:text-white"
                >
                  <Link href={href} className="flex items-center gap-2.5">
                    <Icon className="h-4 w-4 text-muted-foreground dark:text-white/64" strokeWidth={1.8} />
                    <span>{t(label)}</span>
                  </Link>
                </DropdownMenuItem>
              ),
            )}
          </>
        ) : null}

        {view === "language" ? (
          <>
            <DropdownMenuLabel className="flex items-center gap-1 px-1 py-1.5 text-[14px] font-medium normal-case tracking-normal text-foreground dark:text-white">
              <button
                type="button"
                onClick={() => setView("root")}
                className="inline-flex h-8 w-8 items-center justify-center rounded-full text-foreground transition hover:bg-hover dark:text-white"
              >
                <ChevronLeft className="h-4 w-4" />
              </button>
              <span>{t("Language")}</span>
            </DropdownMenuLabel>
            <div className="max-h-[min(420px,60dvh)] overflow-y-auto">
              {LANGUAGE_OPTIONS.map((option) => (
                <DropdownMenuItem
                  key={option.code}
                  className="flex cursor-pointer items-center justify-between rounded-[16px] px-3 py-2.5 text-[14px] text-foreground outline-none hover:bg-hover focus:bg-hover dark:text-white"
                  onSelect={(event) => {
                    event.preventDefault()
                    setLanguage(option.code)
                    setView("root")
                  }}
                >
                  <span>{option.label}</span>
                  {option.code === language ? <Check className="h-4 w-4 text-brand" /> : null}
                </DropdownMenuItem>
              ))}
            </div>
          </>
        ) : null}

        {view === "currency" ? (
          <>
            <DropdownMenuLabel className="flex items-center gap-1 px-1 py-1.5 text-[14px] font-medium normal-case tracking-normal text-foreground dark:text-white">
              <button
                type="button"
                onClick={() => setView("root")}
                className="inline-flex h-8 w-8 items-center justify-center rounded-full text-foreground transition hover:bg-hover dark:text-white"
              >
                <ChevronLeft className="h-4 w-4" />
              </button>
              <span>{t("Currency")}</span>
            </DropdownMenuLabel>
            <div className="max-h-[min(420px,60dvh)] overflow-y-auto">
              {CURRENCY_OPTIONS.map((option) => (
                <DropdownMenuItem
                  key={option.code}
                  className="flex cursor-pointer items-center justify-between rounded-[16px] px-3 py-2.5 text-[14px] text-foreground outline-none hover:bg-hover focus:bg-hover dark:text-white"
                  onSelect={(event) => {
                    event.preventDefault()
                    setCurrency(option.code)
                    setView("root")
                  }}
                >
                  <span className="flex items-center gap-2">
                    <CurrencyFlag code={option.code} className="size-5" />
                    {option.label}
                  </span>
                  {option.code === currency ? <Check className="h-4 w-4 text-brand" /> : null}
                </DropdownMenuItem>
              ))}
            </div>
          </>
        ) : null}

        {view === "network" ? (
          <>
            <DropdownMenuLabel className="flex items-center gap-1 px-1 py-1.5 text-[14px] font-medium normal-case tracking-normal text-foreground dark:text-white">
              <button
                type="button"
                onClick={() => setView("root")}
                className="inline-flex h-8 w-8 items-center justify-center rounded-full text-foreground transition hover:bg-hover dark:text-white"
              >
                <ChevronLeft className="h-4 w-4" />
              </button>
              <span>{t("Network")}</span>
            </DropdownMenuLabel>
            <div className="max-h-[min(420px,60dvh)] overflow-y-auto">
              {NETWORK_OPTIONS.map((option) => (
                <DropdownMenuItem
                  key={option.code}
                  className="flex cursor-pointer items-center justify-between rounded-[16px] px-3 py-2.5 text-[14px] text-foreground outline-none hover:bg-hover focus:bg-hover dark:text-white"
                  onSelect={(event) => {
                    event.preventDefault()
                    if (option.unavailable) return
                    setView("root")
                  }}
                  disabled={option.unavailable}
                >
                  <span>{option.label}</span>
                  <span className="flex items-center gap-2">
                    {option.code === currentNetwork.code ? <Check className="h-4 w-4 text-brand" /> : null}
                    {option.unavailable ? (
                      <span className="text-[12px] text-muted-foreground/80 dark:text-white/48">
                        {t("Unavailable")}
                      </span>
                    ) : null}
                  </span>
                </DropdownMenuItem>
              ))}
            </div>
          </>
        ) : null}
      </DropdownMenuContent>
    </DropdownMenu>
  )
}
