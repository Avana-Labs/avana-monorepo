"use client"

import { Skeleton } from "@/components/ui/skeleton"

export function AskAIHeaderTitleSkeleton() {
  return <Skeleton data-testid="ask-ai-header-skeleton" className="mx-auto h-5 w-24 rounded-full" />
}

// Message-only fallback used after Ask AI has initialized, such as when the user
// switches threads. Initial page loading uses the complete shell below.
export function AskAIThreadSkeleton() {
  return (
    <div data-testid="ask-ai-thread-skeleton" className="flex w-full flex-col gap-7 pt-10" aria-hidden>
      <Skeleton className="ml-auto h-8 w-[38%] rounded-2xl" />
      <div className="space-y-2.5">
        <Skeleton className="h-3.5 w-[72%] rounded-full" />
        <Skeleton className="h-3.5 w-[58%] rounded-full" />
        <Skeleton className="h-3.5 w-[44%] rounded-full" />
      </div>
      <Skeleton className="ml-auto h-8 w-[30%] rounded-2xl" />
      <div className="space-y-2.5">
        <Skeleton className="h-3.5 w-[64%] rounded-full" />
        <Skeleton className="h-3.5 w-[50%] rounded-full" />
      </div>
    </div>
  )
}

// One shell for every initial Ask AI loading stage. Matches the first-visit empty
// state (centered greeting + composer + suggestion chips) so new users never see a
// chat-bubble skeleton flip into a different layout before the real empty view.
export function AskAILoadingBody() {
  return (
    <main
      data-testid="ask-ai-loading-body"
      aria-label="Loading Ask AI"
      className="flex h-[calc(100dvh-56px)] w-full overflow-hidden lg:h-[calc(100dvh-56px)] [@media(min-height:684px)]:min-h-[620px]"
    >
      <aside aria-hidden className="hidden w-[260px] shrink-0 flex-col bg-muted/20 p-3 lg:flex">
        <div className="flex h-8 items-center gap-2 rounded-md bg-muted px-2.5 text-sm font-normal text-foreground">
          <span aria-hidden className="inline-flex size-4 items-center justify-center text-xl font-light leading-none">
            +
          </span>
          New Thread
        </div>
        <div className="mt-6 min-h-0 flex-1">
          <p className="px-2.5 text-[12px] font-normal leading-4 text-muted-foreground">Today</p>
          <Skeleton className="mt-1 ml-2.5 h-4 w-24 rounded-full" />
        </div>
        <div className="rounded-2xl border border-border/60 p-3.5">
          <div className="flex items-center justify-between gap-3">
            <Skeleton className="h-5 w-24 rounded-full" />
            <Skeleton className="h-4 w-20 rounded-full" />
          </div>
          <Skeleton className="mt-2.5 h-1 w-full rounded-full" />
          <div className="mt-2.5 flex items-center justify-between gap-3">
            <Skeleton className="h-4 w-16 rounded-full" />
            <Skeleton className="h-7 w-20 rounded-full" />
          </div>
        </div>
      </aside>

      <section aria-hidden className="relative flex min-w-0 flex-1 flex-col overflow-hidden bg-background">
        <div className="flex h-16 shrink-0 items-center gap-3 px-5 sm:px-8">
          <Skeleton className="size-8 rounded-md" />
        </div>
        <div className="flex min-h-0 flex-1 flex-col [--thread-max-width:44rem]">
          <div className="relative flex flex-1 flex-col overflow-hidden">
            <div className="mx-auto flex w-full max-w-[44rem] flex-1 flex-col justify-center px-4 pt-4">
              <div data-testid="ask-ai-empty-thread-skeleton" className="mb-6 flex flex-col items-center px-4">
                <Skeleton className="h-[30px] w-56 rounded-full" />
              </div>
              <div className="flex flex-col gap-4 bg-background pb-4 md:pb-6">
                <Skeleton className="h-[106px] w-full rounded-[24px]" />
                <div className="flex w-full flex-wrap items-center justify-center gap-2 px-4">
                  <Skeleton className="h-8 w-[6.25rem] rounded-full" />
                  <Skeleton className="h-8 w-[6.75rem] rounded-full" />
                  <Skeleton className="h-8 w-[5.75rem] rounded-full" />
                  <Skeleton className="h-8 w-[4.75rem] rounded-full" />
                  <Skeleton className="h-8 w-[7.5rem] rounded-full" />
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>
    </main>
  )
}
