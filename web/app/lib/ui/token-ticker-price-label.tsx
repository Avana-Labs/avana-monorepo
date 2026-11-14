"use client"

import { cn } from "@/lib/utils"
import { useCanonicalPriceFor } from "@/app/lib/prices/token-prices-context"
import { formatTokenPrice } from "@/app/lib/prices/format"
import { formatTokenDisplaySymbol } from "@/app/lib/token-icons"

const FACE =
  "block truncate [grid-area:1/1] transition-[transform,opacity] duration-300 ease-out [backface-visibility:hidden] motion-reduce:transition-none"

/**
 * Secondary line in a table row. Touch / phone: `touch` (defaults to `back`). Desktop
 * (hover-capable, md+): `front`, which flips over to `back` while the row is hovered — the row
 * must carry Tailwind's `group` class. Both faces share one grid cell, so the line is as wide as
 * the longer face.
 */
export function HoverFlip({ front, back, touch = back }: { front: string; back: string; touch?: string }) {
  return (
    <>
      <span className="block truncate [@media(hover:hover)_and_(min-width:768px)]:hidden">{touch}</span>
      <span className="hidden [perspective:240px] [@media(hover:hover)_and_(min-width:768px)]:grid">
        <span
          className={cn(
            FACE,
            "origin-top group-hover:opacity-0 group-hover:[transform:translateY(-50%)_rotateX(90deg)]",
          )}
        >
          {front}
        </span>
        <span
          className={cn(
            FACE,
            "origin-bottom opacity-0 [transform:translateY(50%)_rotateX(-90deg)] group-hover:opacity-100 group-hover:[transform:none]",
          )}
        >
          {back}
        </span>
      </span>
    </>
  )
}

/** Token line: the ticker, flipping to `detail` (a unit price, "$18.5M Supply"); ticker alone without one. */
export function TickerPriceFlip({ symbol, detail }: { symbol: string; detail: string | undefined }) {
  const ticker = formatTokenDisplaySymbol(symbol)
  if (detail === undefined) return <>{ticker}</>
  return <HoverFlip front={ticker} back={detail} />
}

/** `TickerPriceFlip` with the live canonical (DefiLlama) unit price. */
export function TokenTickerPriceLabel({ symbol }: { symbol: string }) {
  const priceFor = useCanonicalPriceFor()
  const price = priceFor(symbol)
  return <TickerPriceFlip symbol={symbol} detail={price === undefined ? undefined : formatTokenPrice(price)} />
}
