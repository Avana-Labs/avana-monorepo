"use client"

import Link from "next/link"
import { useTranslation } from "@/app/lib/i18n/use-translation"

type NewsItem = {
  title: string
  source: string
  time: string
  description?: string
  href?: string
  imageUrl?: string
  imageLabel?: string
}

type Props = {
  items: NewsItem[]
  title?: string
  plain?: boolean
  /** Optional "View all" destination shown next to the heading (e.g. governance). */
  viewAllHref?: string
  /** Fallback link for items without their own href (e.g. governance). */
  itemHrefFallback?: string
}

/**
 * A market's "news" feed — used here to surface risk parameter updates. Each row is
 * a headline + "source · date" with a thumbnail on the right, linking out to the
 * governance thread where the change was made.
 */
export function NewsCard({ items, title = "Risk Parameters", plain = false, viewAllHref, itemHrefFallback }: Props) {
  const { t } = useTranslation()
  return (
    <section
      className={
        plain ? "space-y-2" : "overflow-hidden rounded-radius-lg border border-border bg-surface-raised shadow-elev-1"
      }
    >
      <div
        className={
          plain ? "flex items-center justify-between gap-3" : "flex items-center justify-between gap-3 px-4 py-3"
        }
      >
        <h2 className="truncate text-[22px] font-medium leading-none tracking-[-0.01em] text-foreground md:text-[24px]">
          {t(title)}
        </h2>
        {viewAllHref ? (
          <Link
            href={viewAllHref}
            target="_blank"
            rel="noreferrer"
            className="shrink-0 text-[13px] font-medium text-sky-500 transition-colors hover:text-sky-400"
          >
            {t("View all")}
          </Link>
        ) : null}
      </div>
      <ul className="divide-y divide-border/70">
        {items.map((item, index) => {
          const href = item.href ?? itemHrefFallback
          const content = (
            <div className="group flex items-center gap-4 py-3.5">
              <div className="min-w-0 flex-1">
                <div className="text-[15px] font-medium leading-snug text-text-extra-high text-pretty line-clamp-2 underline-offset-2 group-hover:underline group-focus-visible:underline">
                  {t(item.title)}
                </div>
                <div className="mt-1 text-[13px] text-text-low">
                  {t(item.source)} • {t(item.time)}
                </div>
              </div>
              <div className="size-14 shrink-0 overflow-hidden rounded-radius-md bg-surface-inset ring-1 ring-border">
                {item.imageUrl ? (
                  // eslint-disable-next-line @next/next/no-img-element
                  <img
                    alt=""
                    width="56"
                    height="56"
                    className="h-full w-full object-cover"
                    loading="lazy"
                    decoding="async"
                    src={item.imageUrl}
                  />
                ) : (
                  <div className="flex h-full w-full items-center justify-center text-[10px] font-medium text-text-low">
                    {item.imageLabel ?? item.source.slice(0, 2).toUpperCase()}
                  </div>
                )}
              </div>
            </div>
          )

          return (
            <li key={`${item.source}-${item.time}-${index}`} className="min-w-0">
              {href ? (
                <Link
                  href={href}
                  target="_blank"
                  rel="noreferrer"
                  className="block rounded-radius-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-border-medium"
                >
                  {content}
                </Link>
              ) : (
                content
              )}
            </li>
          )
        })}
      </ul>
    </section>
  )
}
