"use client"

import * as React from "react"
import { ArrowLeft, ArrowRight } from "@/app/components/icons"
import { useTranslation } from "@/app/lib/i18n/use-translation"
import { cn } from "@/lib/utils"

const TABLE_PAGE_SIZE = 10

/**
 * Client-side pagination for a fixed list. The page clamps itself when the list
 * shrinks (e.g. a live feed drops rows) so it never points past the end.
 */
export function useTablePagination<T>(items: T[], pageSize: number = TABLE_PAGE_SIZE) {
  const [page, setPage] = React.useState(0)
  const pageCount = Math.max(1, Math.ceil(items.length / pageSize))
  const safePage = Math.min(page, pageCount - 1)
  React.useEffect(() => {
    if (page > pageCount - 1) setPage(pageCount - 1)
  }, [page, pageCount])
  const start = safePage * pageSize
  const pageItems = React.useMemo(() => items.slice(start, start + pageSize), [items, start, pageSize])
  return { page: safePage, pageCount, pageItems, setPage }
}

const BUTTON_CLASS =
  "inline-flex size-9 items-center justify-center rounded-radius-md border border-border bg-muted text-foreground transition-colors hover:bg-hover disabled:pointer-events-none disabled:opacity-40"

/**
 * Prev / current-page / next control. Renders nothing for a single page.
 * `label` is the already-translated accessible name for the <nav>, kept distinct
 * per table so screen-reader users can tell two pagers on one page apart.
 */
export function TablePager({
  page,
  pageCount,
  onPageChange,
  label,
  className,
}: {
  page: number
  pageCount: number
  onPageChange: (page: number) => void
  label: string
  className?: string
}) {
  const { t } = useTranslation()
  if (pageCount <= 1) return null
  return (
    <nav className={cn("mt-4 flex items-center justify-center gap-2", className)} aria-label={label}>
      <button
        type="button"
        aria-label={t("Previous page")}
        disabled={page === 0}
        onClick={() => onPageChange(Math.max(0, page - 1))}
        className={BUTTON_CLASS}
      >
        <ArrowLeft className="h-4 w-4" />
      </button>
      <span
        aria-current="page"
        className="inline-flex h-9 min-w-9 items-center justify-center rounded-radius-md bg-table-header px-3 font-data text-[13px] font-medium tabular-nums text-foreground"
      >
        {page + 1}
      </span>
      <button
        type="button"
        aria-label={t("Next page")}
        disabled={page >= pageCount - 1}
        onClick={() => onPageChange(Math.min(pageCount - 1, page + 1))}
        className={BUTTON_CLASS}
      >
        <ArrowRight className="h-4 w-4" />
      </button>
    </nav>
  )
}
