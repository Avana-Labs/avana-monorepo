import Link from "next/link"
import { BrandIcon, BrandLogo } from "@/app/components/brand-logo"
import { X } from "@/app/components/icons"
import { AskAIHeaderTitleSkeleton, AskAILoadingBody } from "./components/ask-ai-skeleton"

// Mirror the real /ask chrome (sticky header + full-height body) so the route-level
// loading state doesn't jump to a different layout when the page hydrates.
export default function AskAILoading() {
  return (
    <div className="flex min-h-[100dvh] flex-col bg-background text-foreground">
      <header className="sticky top-0 z-40 flex h-14 items-center border-b border-border bg-background px-4 sm:px-6 lg:h-14 lg:px-5 xl:px-6 2xl:px-8">
        <Link href="/" aria-label="Home" className="inline-flex min-w-0 items-center">
          <BrandIcon className="xl:hidden" />
          <BrandLogo className="hidden xl:inline-flex" />
        </Link>
        <div className="pointer-events-none absolute left-1/2 -translate-x-1/2">
          <AskAIHeaderTitleSkeleton />
        </div>
        <Link
          href="/"
          aria-label="Close"
          className="ml-auto inline-flex size-11 items-center justify-center rounded-full border border-brand/25 bg-brand text-white shadow-elev-1"
        >
          <X className="size-5" />
        </Link>
      </header>
      <AskAILoadingBody />
    </div>
  )
}
