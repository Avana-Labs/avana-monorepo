import { formatChartValue, type ChartFeed, type ChartPoint, type ChartRangeData } from "@/app/components/charts"

type WalletPositionEvent = {
  timestamp: number
  deltaUsd: number
}

function ranges(points: ChartPoint[]): ChartRangeData {
  return { "1D": points, "1W": points, "1M": points, "3M": points, "1Y": points, All: points }
}

export function buildWalletPositionFeed(currentValueUsd: number, events: WalletPositionEvent[]): ChartFeed {
  const ordered = [...events]
    .filter((event) => Number.isFinite(event.deltaUsd))
    .sort((a, b) => a.timestamp - b.timestamp)
  const totalDelta = ordered.reduce((sum, event) => sum + event.deltaUsd, 0)
  let value = Math.max(0, currentValueUsd - totalDelta)
  const points: ChartPoint[] = [
    { time: ordered[0]?.timestamp ? ordered[0].timestamp - 1 : Date.now() - 1, value, label: "Start" },
  ]
  for (const event of ordered) {
    value = Math.max(0, value + event.deltaUsd)
    points.push({
      time: event.timestamp,
      value,
      label: new Date(event.timestamp).toLocaleString([], { month: "short", day: "numeric", hour: "numeric" }),
    })
  }
  if (points.length === 1 || Math.abs(points[points.length - 1]!.value - currentValueUsd) > 0.01) {
    points.push({ time: Date.now(), value: Math.max(0, currentValueUsd), label: "Now" })
  }
  const first = points[0]?.value ?? currentValueUsd
  const change = currentValueUsd - first
  return {
    headlineValue: formatChartValue("usdCompact", currentValueUsd),
    headlineDelta: `${Math.abs(first ? (change / first) * 100 : 0).toFixed(2)}%`,
    deltaTone: change < 0 ? "negative" : "positive",
    rangeData: ranges(points),
    valueFormat: "usdCompact",
  }
}
