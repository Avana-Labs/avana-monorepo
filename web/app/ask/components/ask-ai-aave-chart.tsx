"use client"

import { Chart } from "@/components/elements/chart"
import type { AaveApyVisual } from "@/app/lib/ask-ai/aave-mcp"

export function AskAIAaveChart({ visual }: { visual: AaveApyVisual }) {
  const dates = visual.timestamps
  const date = (at: number) =>
    new Date(at).toLocaleDateString("en-US", { month: "short", day: "numeric", timeZone: "UTC" })
  return (
    <figure className="flex w-full max-w-md flex-col gap-2" aria-label={visual.label}>
      <Chart
        label={visual.label}
        value={visual.value}
        delta={visual.delta}
        points={visual.points}
        visibleCount={visual.points.length}
        variant="line"
        className="max-w-none"
      />
      <figcaption className="flex flex-wrap justify-between gap-2 px-1 text-xs text-muted-foreground">
        <span>
          {date(dates[0])} – {date(dates.at(-1)!)} (UTC)
        </span>
        <span>Aave (live) · {visual.window} · APY %</span>
      </figcaption>
    </figure>
  )
}
