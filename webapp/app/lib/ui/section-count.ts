/** English count label with singular/plural noun (e.g. "1 asset" vs "2 assets"). */
export function formatSectionCount(count: number, singular: string, plural: string): string {
  return `${count} ${count === 1 ? singular : plural}`
}
