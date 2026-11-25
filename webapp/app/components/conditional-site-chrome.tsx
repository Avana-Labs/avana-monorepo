"use client"

import { usePathname } from "next/navigation"
import type { ReactNode } from "react"
import { Header } from "@/app/components/header"
import { WrongNetworkBanner } from "@/app/components/wrong-network-banner"

function ConditionalSiteHeader() {
  return <Header />
}

export function ConditionalSiteChrome({ children }: { children: ReactNode }) {
  const pathname = usePathname()
  // Focused, full-screen routes render their own chrome and suppress the site header.
  const isActionRoute = pathname.startsWith("/actions/") || pathname === "/swap" || pathname === "/ask"

  return (
    <div className={isActionRoute ? "min-h-[100dvh] bg-background" : "flex min-h-screen flex-col"}>
      {!isActionRoute ? <ConditionalSiteHeader /> : null}
      <WrongNetworkBanner />
      <div className={isActionRoute ? "min-h-[100dvh]" : "flex-1"}>{children}</div>
    </div>
  )
}
