"use client"

import { Archive, ArchiveRestore, Check, Pencil, X } from "lucide-react"
import { useEffect, useRef, useState } from "react"
import { useRouter } from "next/navigation"
import { triggerPageLoading } from "@/app/lib/page-loading"
import { QuotaBanner } from "@/components/elements/quota-banner"

type AskAIThreadSummary = {
  threadId: string
  title: string
  updatedAt: number
}

export function AskAIThreadList({
  open,
  activeThreadId,
  threads,
  onClose,
  onNewThread,
  onSelectThread,
  onRenameThread,
  archivedThreads,
  onArchiveThread,
  onUnarchiveThread,
  canLoadMore,
  onLoadMore,
  canLoadMoreArchived,
  onLoadMoreArchived,
  quota,
}: {
  open: boolean
  activeThreadId: string | null
  threads: AskAIThreadSummary[]
  onClose: () => void
  onNewThread: () => void | Promise<void>
  onSelectThread: (threadId: string) => void
  onRenameThread: (threadId: string, title: string) => Promise<void>
  archivedThreads: AskAIThreadSummary[]
  onArchiveThread: (threadId: string) => Promise<void>
  onUnarchiveThread: (threadId: string) => Promise<void>
  canLoadMore: boolean
  onLoadMore: () => void
  canLoadMoreArchived: boolean
  onLoadMoreArchived: () => void
  quota?: { used: number; limit: number; resetsAt: number }
}) {
  const [renamingId, setRenamingId] = useState<string | null>(null)
  const [draftTitle, setDraftTitle] = useState("")
  const [showArchived, setShowArchived] = useState(false)
  const router = useRouter()
  const asideRef = useRef<HTMLElement>(null)
  // When closed, the drawer is only translated/collapsed offscreen but stays in the DOM, so
  // without `inert` its New Thread / rename / archive controls remain focusable and exposed to
  // assistive tech. Toggle it imperatively — React 18 has no typed `inert` prop.
  useEffect(() => {
    const node = asideRef.current
    if (!node) return
    if (open) node.removeAttribute("inert")
    else node.setAttribute("inert", "")
  }, [open])
  return (
    <>
      {open ? (
        <button
          type="button"
          aria-label="Close thread history"
          className="fixed inset-x-0 bottom-0 top-16 z-40 bg-black/20 lg:hidden"
          onClick={onClose}
        />
      ) : null}
      <aside
        ref={asideRef}
        aria-label="Ask AI thread history"
        className={`fixed bottom-0 left-0 top-16 z-50 flex w-[min(86vw,300px)] flex-col overflow-hidden border-r border-border/40 bg-background text-foreground transition-transform lg:static lg:z-auto lg:shrink-0 lg:border-r-0 lg:bg-muted/20 lg:transition-[width,padding] ${
          open ? "translate-x-0 p-3 lg:w-[260px]" : "-translate-x-full p-3 lg:w-0 lg:translate-x-0 lg:p-0"
        }`}
      >
        <div className="flex shrink-0 items-center gap-2">
          <button
            type="button"
            onClick={() => void onNewThread()}
            className="flex h-11 lg:h-8 min-w-0 flex-1 items-center gap-2 rounded-md bg-muted px-2.5 text-left text-sm font-normal transition-colors hover:bg-muted/80"
          >
            <span
              aria-hidden
              className="inline-flex size-4 items-center justify-center text-xl font-light leading-none"
            >
              +
            </span>
            New Thread
          </button>
          <button
            type="button"
            aria-label="Close sidebar"
            onClick={onClose}
            className="inline-flex size-11 shrink-0 items-center justify-center rounded-md text-muted-foreground hover:bg-muted hover:text-foreground lg:hidden"
          >
            <X className="size-4" />
          </button>
        </div>

        <div className="mt-6 min-h-0 flex-1 overflow-y-auto">
          <p className="px-2.5 text-[12px] font-normal leading-4 text-muted-foreground">Today</p>
          {threads.length === 0 ? (
            <p className="mt-1 px-2.5 text-sm text-muted-foreground">No threads yet</p>
          ) : (
            <div className="mt-1 flex flex-col gap-0.5">
              {threads.map((thread) =>
                renamingId === thread.threadId ? (
                  <form
                    key={thread.threadId}
                    className="flex h-11 lg:h-8 items-center gap-1"
                    onSubmit={(event) => {
                      event.preventDefault()
                      void onRenameThread(thread.threadId, draftTitle).then(() => setRenamingId(null))
                    }}
                  >
                    <input
                      autoFocus
                      aria-label={`Rename ${thread.title}`}
                      value={draftTitle}
                      maxLength={80}
                      onChange={(event) => setDraftTitle(event.target.value)}
                      className="h-11 lg:h-8 min-w-0 flex-1 rounded-md border border-border bg-background px-2 text-sm outline-none focus:ring-2 focus:ring-ring"
                    />
                    <button
                      type="submit"
                      aria-label="Save thread name"
                      className="inline-flex size-11 items-center justify-center lg:size-7"
                    >
                      <Check className="size-3.5" />
                    </button>
                    <button
                      type="button"
                      aria-label="Cancel thread rename"
                      onClick={() => setRenamingId(null)}
                      className="inline-flex size-11 items-center justify-center lg:size-7"
                    >
                      <X className="size-3.5" />
                    </button>
                  </form>
                ) : (
                  <div
                    key={thread.threadId}
                    className={`group flex h-11 lg:h-8 items-center rounded-md hover:bg-muted ${
                      activeThreadId === thread.threadId ? "bg-muted" : ""
                    }`}
                  >
                    <button
                      type="button"
                      onClick={() => {
                        onSelectThread(thread.threadId)
                        // Only collapse the sidebar on mobile, where it's an overlay; on desktop it
                        // is a static column and should stay open when switching threads.
                        if (typeof window !== "undefined" && window.matchMedia("(max-width: 1023px)").matches) onClose()
                      }}
                      className="h-11 lg:h-8 min-w-0 flex-1 truncate px-2.5 text-left text-sm"
                    >
                      {thread.title}
                    </button>
                    <button
                      type="button"
                      aria-label={`Rename ${thread.title}`}
                      onClick={() => {
                        setDraftTitle(thread.title)
                        setRenamingId(thread.threadId)
                      }}
                      className="mr-1 inline-flex size-11 items-center justify-center rounded-md text-muted-foreground opacity-100 hover:text-foreground lg:size-7 lg:opacity-0 lg:focus:opacity-100 lg:group-hover:opacity-100"
                    >
                      <Pencil className="size-3.5" />
                    </button>
                    <button
                      type="button"
                      aria-label={`Archive ${thread.title}`}
                      onClick={() => void onArchiveThread(thread.threadId)}
                      className="mr-1 inline-flex size-11 items-center justify-center rounded-md text-muted-foreground opacity-100 hover:text-foreground lg:size-7 lg:opacity-0 lg:focus:opacity-100 lg:group-hover:opacity-100"
                    >
                      <Archive className="size-3.5" />
                    </button>
                  </div>
                ),
              )}
            </div>
          )}
          {canLoadMore ? (
            <button
              type="button"
              onClick={onLoadMore}
              className="mt-2 px-2.5 text-xs text-muted-foreground hover:text-foreground"
            >
              Load older threads
            </button>
          ) : null}
          {archivedThreads.length > 0 ? (
            <div className="mt-5 border-t border-border/50 pt-3">
              <button
                type="button"
                aria-expanded={showArchived}
                onClick={() => setShowArchived((current) => !current)}
                className="px-2.5 text-[12px] font-normal leading-4 text-muted-foreground hover:text-foreground"
              >
                Archived ({archivedThreads.length})
              </button>
              {showArchived ? (
                <div className="mt-1 flex flex-col gap-0.5">
                  {archivedThreads.map((thread) => (
                    <div
                      key={thread.threadId}
                      className="group flex h-11 lg:h-8 items-center rounded-md hover:bg-muted"
                    >
                      <span className="min-w-0 flex-1 truncate px-2.5 text-sm text-muted-foreground">
                        {thread.title}
                      </span>
                      <button
                        type="button"
                        aria-label={`Restore ${thread.title}`}
                        onClick={() => void onUnarchiveThread(thread.threadId)}
                        className="mr-1 inline-flex size-11 items-center justify-center rounded-md text-muted-foreground hover:text-foreground lg:size-7"
                      >
                        <ArchiveRestore className="size-3.5" />
                      </button>
                    </div>
                  ))}
                  {canLoadMoreArchived ? (
                    <button
                      type="button"
                      onClick={onLoadMoreArchived}
                      className="px-2.5 py-1 text-left text-xs text-muted-foreground hover:text-foreground"
                    >
                      Load older archived threads
                    </button>
                  ) : null}
                </div>
              ) : null}
            </div>
          ) : null}
        </div>
        {quota ? (
          <QuotaBanner
            used={quota.used}
            limit={quota.limit}
            unit="messages"
            resetsIn={new Date(quota.resetsAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}
            upgradeLabel="Need Help?"
            onUpgrade={() => {
              triggerPageLoading()
              router.push("/support-center")
            }}
            className="max-w-none"
          />
        ) : null}
      </aside>
    </>
  )
}
