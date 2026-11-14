"use client"

import { useEffect, useMemo, useRef, useState, type PointerEvent } from "react"
import { CHART_RANGE_LABELS, getChartTickIndexes } from "./chart-data"
import { interpolateScrubSample, scrubRatioFromPointer, type HeroScrubSample } from "./hero-scrub"
import type { ChartPoint, ChartRangeOption } from "./types"

const TONE_COLORS = {
  positive: {
    stroke: "#01AACF",
    fill: "#01AACF",
    cursor: "rgba(1, 170, 207, 0.35)",
  },
  negative: {
    stroke: "#F0444C",
    fill: "#F0444C",
    cursor: "rgba(240, 68, 76, 0.35)",
  },
  neutral: {
    stroke: "hsl(var(--foreground))",
    fill: "hsl(var(--foreground))",
    cursor: "hsl(var(--foreground) / 0.28)",
  },
} as const

type HeroAreaChartProps = {
  data: ChartPoint[]
  activeRange: ChartRangeOption
  height?: number
  formatValue?: (value: number) => string
  formatYAxis?: (value: number) => string
  gradientId?: string
  className?: string
  tone?: "positive" | "negative" | "neutral"
  /** Continuous scrub sample (interpolated along the path). Prefer over index snap. */
  onScrubChange?: (sample: HeroScrubSample | null) => void
  /**
   * @deprecated Prefer `onScrubChange`. Still fired with the nearest index for
   * older callers; floor index while scrubbing.
   */
  onActiveIndexChange?: (index: number | null) => void
  /** Horizontal threshold lines (e.g. health-factor = 1). Drawn over the series. */
  referenceLines?: Array<{ value: number; label?: string; color?: string }>
  /** Explicit y-axis domain. Overrides the default padded auto-domain per bound. */
  domainMin?: number
  domainMax?: number
  /**
   * Floating value bubble near the cursor. Off by default — Uniswap-style heroes
   * put the live value in the headline + Y-axis pill instead.
   */
  showTooltip?: boolean
  /** Y-axis scrub price pill (Uniswap-style). Defaults on. */
  showYAxisPill?: boolean
  /** Fade the series to the right of the scrub cursor. Defaults on. */
  fadeAfterScrub?: boolean
}

type PlotPoint = ChartPoint & { x: number; y: number }
type AxisTick = { value: number; y: number; label: string }
type XAxisTick = { x: number; label: string; anchor: "start" | "middle" | "end" }

function monotoneLinePath(points: PlotPoint[]) {
  if (points.length === 0) return ""
  if (points.length === 1) return `M ${points[0].x} ${points[0].y}`

  const slopes = points.slice(0, -1).map((point, index) => {
    const next = points[index + 1]
    return (next.y - point.y) / Math.max(1, next.x - point.x)
  })
  const tangents = points.map((_, index) => {
    if (index === 0) return slopes[0]
    if (index === points.length - 1) return slopes[slopes.length - 1]
    const previous = slopes[index - 1]
    const next = slopes[index]
    if (previous === 0 || next === 0 || Math.sign(previous) !== Math.sign(next)) return 0
    return (2 * previous * next) / (previous + next)
  })

  let path = `M ${points[0].x} ${points[0].y}`
  for (let index = 0; index < points.length - 1; index += 1) {
    const point = points[index]
    const next = points[index + 1]
    const third = (next.x - point.x) / 3
    path += ` C ${point.x + third} ${point.y + tangents[index] * third}, ${next.x - third} ${next.y - tangents[index + 1] * third}, ${next.x} ${next.y}`
  }
  return path
}

export function buildHeroAreaGeometry(
  data: ChartPoint[],
  width: number,
  height: number,
  activeRange: ChartRangeOption = "1D",
  formatYAxis: (value: number) => string = (value) => String(Math.round(value)),
  domainMin?: number,
  domainMax?: number,
) {
  if (data.length === 0) {
    return {
      points: [] as PlotPoint[],
      linePath: "",
      areaPath: "",
      axisTicks: [] as AxisTick[],
      xAxisTicks: [] as XAxisTick[],
      left: 0,
      right: 0,
      top: 0,
      bottom: 0,
      min: 0,
      max: 0,
    }
  }
  // Match lend/market detail chart padding. Unique series labels keep custom
  // day axes (portfolio) from duplicating ticks when the range label count differs.
  const top = 58
  const bottom = 34
  const left = 0
  const right = width < 640 ? 40 : 58
  const values = data.map((point) => point.value)
  const rawMin = Math.min(...values)
  const rawMax = Math.max(...values)
  const valueSpan = Math.max(1, rawMax - rawMin)
  // Explicit domain overrides let small-magnitude series (health factor, APY %)
  // opt out of the dollar-oriented ±4 padding floor that would otherwise show
  // nonsensical (e.g. negative) axis ticks. For a non-negative series with no override,
  // clamp the auto floor at 0 so money charts never render negative gridline ticks.
  const auto = rawMin - Math.max(4, valueSpan * 0.08)
  const min = domainMin ?? (rawMin >= 0 ? Math.max(0, auto) : auto)
  const max = domainMax ?? rawMax + Math.max(4, valueSpan * 0.28)
  const range = Math.max(1, max - min)
  const plotHeight = Math.max(1, height - top - bottom)
  const plotWidth = Math.max(1, width - left - right)
  const yTickCount = width < 640 ? 5 : 6
  const tickValues = Array.from({ length: yTickCount }, (_, index) => max - (range * index) / (yTickCount - 1))
  const axisTicks = tickValues.map((value) => ({
    value,
    y: top + ((max - value) / range) * plotHeight,
    label: formatYAxis(value),
  }))
  // Position points by timestamp so a gap in the data (e.g. a stale tail) shows as real
  // spacing rather than being evenly compressed by index. Falls back to index spacing when
  // every point shares a timestamp (zero span) or there is only a single point.
  const times = data.map((point) => point.time)
  const minTime = Math.min(...times)
  const maxTime = Math.max(...times)
  const timeSpan = maxTime - minTime
  const points = data.map((point, index) => ({
    ...point,
    x:
      data.length === 1
        ? left + plotWidth / 2
        : timeSpan > 0
          ? left + ((point.time - minTime) / timeSpan) * plotWidth
          : left + (index / (data.length - 1)) * plotWidth,
    y: top + ((max - point.value) / range) * plotHeight,
  }))
  const uniqueLabelIndexes: number[] = []
  let previousLabel: string | undefined
  for (let index = 0; index < data.length; index += 1) {
    if (data[index].label !== previousLabel) {
      uniqueLabelIndexes.push(index)
      previousLabel = data[index].label
    }
  }
  // Sparse pre-bucketed labels (demo feeds / portfolio) can be used as-is.
  // Dense day/hour series (detail pages) must be subsampled or labels collide.
  const preferredTickCount = CHART_RANGE_LABELS[activeRange]?.length ?? 6
  const rawTickIndexes =
    uniqueLabelIndexes.length >= 2 && uniqueLabelIndexes.length <= preferredTickCount + 1
      ? uniqueLabelIndexes
      : Array.from(new Set(getChartTickIndexes(activeRange, data.length)))
  const tickIndexes = width < 640 ? rawTickIndexes.filter((_, index) => index % 2 === 0) : rawTickIndexes
  const xAxisTicks = tickIndexes.map((index, tickPosition) => {
    const point = points[Math.min(points.length - 1, Math.max(0, index))]
    return {
      x: point.x,
      label: point.label,
      anchor:
        tickPosition === 0
          ? ("start" as const)
          : tickPosition === tickIndexes.length - 1
            ? ("end" as const)
            : ("middle" as const),
    }
  })
  // Drop empty labels so a sparse/malformed feed still keeps readable ticks.
  const labeledXAxisTicks = xAxisTicks.filter((tick) => tick.label.trim().length > 0)
  const linePath = monotoneLinePath(points)
  const areaPath = `${linePath} L ${points[points.length - 1].x} ${height - bottom} L ${points[0].x} ${height - bottom} Z`
  return { points, linePath, areaPath, axisTicks, xAxisTicks: labeledXAxisTicks, left, right, top, bottom, min, max }
}

export function HeroAreaChart({
  data,
  activeRange,
  height = 240,
  formatValue = (value) =>
    `$${value.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`,
  formatYAxis = (value) => `$${Math.round(value).toLocaleString()}`,
  gradientId = "heroAreaChartFill",
  className,
  tone,
  onScrubChange,
  onActiveIndexChange,
  referenceLines,
  domainMin,
  domainMax,
  showTooltip = false,
  showYAxisPill = true,
  fadeAfterScrub = true,
}: HeroAreaChartProps) {
  const shellRef = useRef<HTMLDivElement | null>(null)
  const [dimensions, setDimensions] = useState({ width: 1_000, height })
  const [scrub, setScrub] = useState<HeroScrubSample | null>(null)
  const [isVisible, setIsVisible] = useState(true)

  useEffect(() => {
    const shell = shellRef.current
    if (!shell || typeof ResizeObserver === "undefined") return
    const observer = new ResizeObserver(([entry]) => {
      if (!entry) return
      const width = Math.max(1, Math.round(entry.contentRect.width))
      const nextHeight = Math.max(1, Math.round(entry.contentRect.height))
      setDimensions((current) =>
        current.width === width && current.height === nextHeight ? current : { width, height: nextHeight },
      )
    })
    observer.observe(shell)
    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    const shell = shellRef.current
    if (!shell || typeof IntersectionObserver === "undefined") return
    const observer = new IntersectionObserver(([entry]) => setIsVisible(Boolean(entry?.isIntersecting)))
    observer.observe(shell)
    return () => observer.disconnect()
  }, [])

  const resolvedTone: "positive" | "negative" | "neutral" =
    tone ?? (data.length >= 2 && data[data.length - 1].value < data[0].value ? "negative" : "positive")
  const color = TONE_COLORS[resolvedTone]
  const geometry = useMemo(
    () =>
      buildHeroAreaGeometry(data, dimensions.width, dimensions.height, activeRange, formatYAxis, domainMin, domainMax),
    [activeRange, data, dimensions, formatYAxis, domainMin, domainMax],
  )
  const cursorBottom = geometry.bottom || 34
  const lastPoint = geometry.points[geometry.points.length - 1]
  const chartShellClassName =
    className ??
    [
      "relative before:pointer-events-none before:absolute before:inset-0 before:bg-[radial-gradient(circle_at_1px_1px,rgba(0,0,0,0.12)_1px,transparent_0)] before:[background-size:18px_18px] before:[mask-image:radial-gradient(ellipse_at_center,black_58%,transparent_100%)] before:content-[''] dark:before:bg-[radial-gradient(circle_at_1px_1px,rgba(255,255,255,0.12)_1px,transparent_0)]",
      height === 240 ? "h-[210px] sm:h-[240px]" : "",
    ]
      .filter(Boolean)
      .join(" ")

  const publishScrub = (sample: HeroScrubSample | null) => {
    setScrub(sample)
    onScrubChange?.(sample)
    onActiveIndexChange?.(sample == null ? null : sample.indexFloor)
  }

  const setPointerScrub = (event: PointerEvent<HTMLDivElement>) => {
    if (data.length === 0 || geometry.points.length === 0) return
    const rect = event.currentTarget.getBoundingClientRect()
    // Map CSS pixels → SVG viewBox X so scrub stays aligned when the initial
    // ResizeObserver width differs from the laid-out shell (tests + first paint).
    const scaleX = dimensions.width / Math.max(1, rect.width)
    const svgX = (event.clientX - rect.left) * scaleX
    const plotWidth = Math.max(1, dimensions.width - geometry.left - geometry.right)
    const ratio = scrubRatioFromPointer(svgX, 0, geometry.left, plotWidth)
    const sample = interpolateScrubSample(geometry.points, ratio)
    if (!sample) return
    publishScrub(sample)
  }

  const clearPointer = () => {
    publishScrub(null)
  }

  const scrubMaskId = `${gradientId}-scrubMask`
  const leftFadeMaskId = `${gradientId}-leftMask`
  const plotRight = dimensions.width - geometry.right
  const scrubX = scrub?.x ?? plotRight

  return (
    <div
      ref={shellRef}
      className={chartShellClassName}
      style={{ height }}
      onPointerMove={setPointerScrub}
      onPointerLeave={clearPointer}
      data-testid="hero-area-chart"
    >
      <svg
        aria-label="Market value trend"
        role="img"
        className="size-full overflow-visible"
        viewBox={`0 0 ${dimensions.width} ${dimensions.height}`}
      >
        <defs>
          <linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stopColor={color.fill} stopOpacity="0.32" />
            <stop offset="100%" stopColor={color.fill} stopOpacity="0.03" />
          </linearGradient>
          <linearGradient id={`${gradientId}-leftFade`} x1="0" y1="0" x2="1" y2="0">
            <stop offset="0%" stopColor="#fff" stopOpacity="0" />
            <stop offset="10%" stopColor="#fff" stopOpacity="1" />
          </linearGradient>
          <mask
            id={leftFadeMaskId}
            maskUnits="userSpaceOnUse"
            x="0"
            y="0"
            width={dimensions.width}
            height={dimensions.height}
          >
            <rect width={dimensions.width} height={dimensions.height} fill={`url(#${gradientId}-leftFade)`} />
          </mask>
          {fadeAfterScrub ? (
            <mask
              id={scrubMaskId}
              maskUnits="userSpaceOnUse"
              x="0"
              y="0"
              width={dimensions.width}
              height={dimensions.height}
            >
              <rect width={dimensions.width} height={dimensions.height} fill="white" fillOpacity="0.28" />
              <rect x="0" y="0" width={Math.max(0, scrubX)} height={dimensions.height} fill="white" />
            </mask>
          ) : null}
        </defs>
        {geometry.axisTicks.length > 0 ? (
          <g aria-hidden="true">
            {geometry.axisTicks.map((tick) => (
              <line
                key={`${tick.value}-${tick.y}-grid`}
                x1={0}
                x2={dimensions.width}
                y1={tick.y}
                y2={tick.y}
                stroke="hsl(var(--border))"
                strokeOpacity="0.45"
                strokeDasharray="2 6"
                vectorEffect="non-scaling-stroke"
              />
            ))}
          </g>
        ) : null}
        <g mask={`url(#${leftFadeMaskId})`}>
          <g mask={fadeAfterScrub && scrub ? `url(#${scrubMaskId})` : undefined}>
            {geometry.areaPath ? <path d={geometry.areaPath} fill={`url(#${gradientId})`} /> : null}
            {geometry.linePath ? (
              <path
                d={geometry.linePath}
                fill="none"
                stroke={color.stroke}
                strokeWidth="2.5"
                vectorEffect="non-scaling-stroke"
              />
            ) : null}
          </g>
          {scrub ? (
            <>
              <line
                x1={scrub.x}
                x2={scrub.x}
                y1={4}
                y2={dimensions.height - cursorBottom}
                stroke={color.cursor}
                strokeWidth="1.25"
                strokeDasharray="3.5 4"
                vectorEffect="non-scaling-stroke"
              />
              <line
                x1={scrub.x}
                x2={dimensions.width - 2}
                y1={scrub.y}
                y2={scrub.y}
                stroke="hsl(var(--muted-foreground))"
                strokeOpacity="0.35"
                strokeWidth="1"
                strokeDasharray="2 5"
                vectorEffect="non-scaling-stroke"
              />
              <circle
                cx={scrub.x}
                cy={scrub.y}
                r="5"
                fill={color.stroke}
                stroke="hsl(var(--background))"
                strokeWidth="2.5"
              />
            </>
          ) : lastPoint ? (
            <>
              {isVisible ? (
                <circle cx={lastPoint.x} cy={lastPoint.y} fill={color.stroke} opacity="0.45">
                  <animate attributeName="r" values="5;18" dur="1.6s" repeatCount="indefinite" />
                  <animate attributeName="opacity" values="0.5;0" dur="1.6s" repeatCount="indefinite" />
                </circle>
              ) : null}
              <circle
                cx={lastPoint.x}
                cy={lastPoint.y}
                r="5.5"
                fill={color.stroke}
                stroke="hsl(var(--background))"
                strokeWidth="2.5"
              />
            </>
          ) : null}
        </g>
        {referenceLines && referenceLines.length > 0 && geometry.max > geometry.min ? (
          <g aria-hidden="true">
            {referenceLines.map((line) => {
              const range = geometry.max - geometry.min
              const plotHeight = Math.max(1, dimensions.height - geometry.top - geometry.bottom)
              const rawY = geometry.top + ((geometry.max - line.value) / range) * plotHeight
              const y = Math.min(dimensions.height - geometry.bottom, Math.max(geometry.top, rawY))
              const stroke = line.color ?? "#F0444C"
              return (
                <g key={`ref-${line.value}`}>
                  <line
                    x1={0}
                    x2={dimensions.width}
                    y1={y}
                    y2={y}
                    stroke={stroke}
                    strokeWidth="1.5"
                    strokeDasharray="5 4"
                    vectorEffect="non-scaling-stroke"
                  />
                  {line.label ? (
                    <text x={4} y={y - 5} className="font-data text-[11px] font-normal" fill={stroke}>
                      {line.label}
                    </text>
                  ) : null}
                </g>
              )
            })}
          </g>
        ) : null}
        {geometry.axisTicks.length > 0 ? (
          <g aria-hidden="true">
            {geometry.axisTicks.map((tick) => (
              <g key={`${tick.value}-${tick.y}-label`}>
                <text
                  x={dimensions.width - 2}
                  y={tick.y}
                  dominantBaseline="middle"
                  textAnchor="end"
                  className="fill-muted-foreground font-data text-[12px] font-normal"
                >
                  {tick.label}
                </text>
              </g>
            ))}
          </g>
        ) : null}
        {geometry.xAxisTicks.length > 0 ? (
          <g aria-hidden="true">
            {geometry.xAxisTicks.map((tick) => (
              <text
                key={`${tick.x}-${tick.label}`}
                x={tick.x}
                y={dimensions.height - 8}
                textAnchor={tick.anchor}
                className="fill-muted-foreground font-data text-[12px] font-normal"
              >
                {tick.label}
              </text>
            ))}
          </g>
        ) : null}
      </svg>

      {scrub && showYAxisPill ? (
        <div
          className="pointer-events-none absolute z-10 -translate-y-1/2 rounded-md bg-muted px-1.5 py-0.5 font-data text-[11px] font-medium text-foreground shadow-sm"
          style={{ right: 2, top: scrub.y }}
          data-testid="hero-scrub-y-pill"
        >
          {formatValue(scrub.value)}
        </div>
      ) : null}

      {scrub && showTooltip ? (
        <div
          className="pointer-events-none absolute z-10 -translate-x-1/2 -translate-y-[calc(100%+8px)] rounded-xs border border-border bg-popover px-2.5 py-1.5 shadow-elev-2"
          style={{ left: scrub.x, top: scrub.y }}
        >
          <div className="flex flex-col gap-0.5">
            <span className="text-[10px] font-medium text-muted-foreground">{scrub.label}</span>
            <span className="font-data text-[12px] font-normal text-foreground">{formatValue(scrub.value)}</span>
          </div>
        </div>
      ) : null}
    </div>
  )
}
