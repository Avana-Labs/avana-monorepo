/** FNV-1a hash, for stable SVG ids. */
function hashString(value: string) {
  let hash = 2166136261
  for (let index = 0; index < value.length; index++) {
    hash ^= value.charCodeAt(index)
    hash = Math.imul(hash, 16777619)
  }
  return hash >>> 0
}

type SparklinePoint = {
  x: number
  y: number
}

/** A flat line: what a sparkline shows when its series has no values yet. */
export function buildSparklinePoints(totalPoints: number, _isPositive: boolean, _seed: string): SparklinePoint[] {
  return Array.from({ length: Math.max(1, totalPoints) }, (_, index) => ({
    x: totalPoints <= 1 ? 50 : (index / (totalPoints - 1)) * 100,
    y: 50,
  }))
}

export function buildSparklineLinePath(points: SparklinePoint[]) {
  return points.map((point, index) => `${index === 0 ? "M" : "L"} ${point.x} ${point.y}`).join(" ")
}

export function buildSparklineAreaPath(linePath: string) {
  return `${linePath} L 100 100 L 0 100 Z`
}

export function getSparklineColor(isPositive: boolean) {
  return isPositive ? "rgb(34, 197, 94)" : "rgb(239, 68, 68)"
}

export function getSparklineGradientId(seed: string, isPositive: boolean) {
  return `sparkline-${isPositive ? "positive" : "negative"}-${hashString(seed).toString(36)}`
}
