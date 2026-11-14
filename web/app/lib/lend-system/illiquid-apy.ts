// Always show the real APY, even on low-TVL markets: the detail page shows the number too, and
// the low TVL is already visible in the row.
export function formatReliableLendApyLabel(apy: number, _tvlUsd: number, formatter: (value: number) => string) {
  return formatter(apy)
}
