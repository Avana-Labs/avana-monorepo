"use client"

import { useState } from "react"
import { Check } from "@/app/components/icons"
import { WalletControl } from "@/app/components/wallet-control"
import { AVANA_EXTERNAL_LINKS } from "@/app/components/external-links"
import { useTranslation } from "@/app/lib/i18n/use-translation"

const PRIMARY =
  "inline-flex min-h-12 items-center justify-center rounded-full bg-brand px-7 text-[15px] font-semibold text-brand-foreground shadow-elev-1 transition-colors hover:bg-brand/90 disabled:cursor-not-allowed disabled:opacity-50"

export function GuestOnboardingFlow() {
  const [hasStarted, setHasStarted] = useState(false)
  const { t } = useTranslation()

  return (
    <div
      className="mx-auto w-full max-w-[938px] py-4 sm:py-8"
      data-onboarding-step="connect"
      data-testid="onboarding-canvas"
    >
      <div className="mb-9 sm:mb-11">
        <div className="h-1 w-full overflow-hidden rounded-full bg-muted">
          <div
            className="h-full rounded-full bg-brand transition-[width] duration-700 ease-out"
            style={{ width: hasStarted ? "25%" : "10%" }}
          />
        </div>
      </div>
      <div data-onboarding-phase={hasStarted ? "connect" : "intro"}>
        {!hasStarted ? (
          <>
            <h1 className="max-w-[600px] text-balance text-[clamp(1.85rem,3.2vw,2.4rem)] font-medium leading-[1.14] tracking-[-0.03em]">
              {t("Welcome to the Avana Sandbox")}
            </h1>
            <p className="mt-6 max-w-[520px] text-[15px] leading-6 text-muted-foreground">
              {t(
                "This risk-free Avana Sandbox lets you borrow against practice LP positions, lend, and loop strategies using sandbox funds. No real assets. No wallet signatures. Just a fast way to understand how Avana works before switching to the live app.",
              )}
            </p>
            <ul className="mt-7 space-y-2.5">
              {["Unlimited practice funds", "No transactions to sign", "No real assets involved"].map((perk) => (
                <li className="flex items-center gap-2.5 text-[15px] font-medium" key={perk}>
                  <Check className="size-4 shrink-0 text-emerald-500" strokeWidth={2.75} />
                  {t(perk)}
                </li>
              ))}
            </ul>
            <button className={`${PRIMARY} mt-9`} onClick={() => setHasStarted(true)} type="button">
              {t("Get started")}
            </button>
          </>
        ) : (
          <>
            <h1 className="max-w-[560px] text-balance text-[clamp(1.4rem,2.3vw,1.75rem)] font-medium leading-[1.16] tracking-[-0.03em]">
              <span className="text-muted-foreground">{t("Connect an EVM wallet.")}</span>
              <br />
              <span className="text-foreground">{t("We'll set up your sandbox and scope it to your address.")}</span>
            </h1>
            <div className="mt-9 flex flex-col gap-3 sm:flex-row">
              <WalletControl size="desktop" />
            </div>
            <p className="mt-8 max-w-[430px] text-[13px] leading-5 text-muted-foreground">
              {t("By connecting your wallet, you agree to the")}{" "}
              <a
                className="text-foreground underline underline-offset-2 hover:text-brand"
                href={AVANA_EXTERNAL_LINKS.terms}
                target="_blank"
                rel="noreferrer"
              >
                {t("Terms & Conditions")}
              </a>{" "}
              {t("and")}{" "}
              <a
                className="text-foreground underline underline-offset-2 hover:text-brand"
                href={AVANA_EXTERNAL_LINKS.privacy}
                target="_blank"
                rel="noreferrer"
              >
                {t("Privacy Policy")}
              </a>
              .
            </p>
          </>
        )}
      </div>
    </div>
  )
}
