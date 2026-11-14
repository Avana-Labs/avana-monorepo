import { getDeterministicAmount, hashString } from "@/app/lib/deterministic"

type SparklinePoint = {
  x: number
  y: number
}

/** Builds stable sparkline points so charts match between renders and test runs. */
export function buildSparklinePoints(totalPoints: number, isPositive: boolean, seed: string): SparklinePoint[] {
  const result: SparklinePoint[] = []

  for (let index = 0; index < totalPoints; index++) {
    const x = totalPoints === 1 ? 50 : (index / (totalPoints - 1)) * 100
    const previousY = result[index - 1]?.y ?? 50
    const delta = getDeterministicAmount(`${seed}-${index}`, isPositive ? -3 : -7, isPositive ? 7 : 3)
    const nextY = Math.max(20, Math.min(80, previousY + delta))

    result.push({ x, y: nextY })
  }

  return result
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
