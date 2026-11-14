/**
 * Canonical desktop table geometry and typography — matches lend discovery tables.
 * Callers add horizontal padding (px-4 / pl-6 / pr-5) and `text-right` for numeric columns.
 */
export const TABLE_BASE = "text-[12px]"

export const TABLE_HEADER_CELL =
  "bg-table-header pb-2 pt-2.5 text-[11px] font-normal uppercase tracking-[0.08em] text-muted-foreground dark:text-white/58"

/** Canonical 33px desktop header strip and 72px populated row geometry. */
export const TABLE_HEADER_ROW =
  "h-[33px] bg-table-header text-left text-muted-foreground [&>th]:whitespace-nowrap [&>th]:pb-2 [&>th]:pt-2.5 [&>th]:text-[11px] [&>th]:font-normal [&>th]:!uppercase [&>th]:tracking-[0.08em] [&>th]:text-muted-foreground [&>th:first-child]:pl-6 [&>th:last-child]:pr-5 dark:[&>th]:text-white/58"

/** Force uppercase labels — CSS alone is overridden in some sortable header buttons. */
export function formatTableHeaderLabel(label: string): string {
  return label.toLocaleUpperCase("en-US")
}

export const TABLE_BODY_ROW = "h-[72px]"

/** Primary body text — 15px regular, same as lend page rows. */
export const TABLE_CELL_PRIMARY =
  "text-[15px] font-normal tracking-normal text-foreground dark:text-white md:text-[15px]"

/**
 * Geometry only, for sub-lines carrying a semantic tone. Use these plus the tone class: the
 * color-bearing variants below bake in a `dark:text-white/XX` two-class selector that outranks
 * a single-class tone and would grey it out in dark mode.
 */
export const TABLE_CELL_SECONDARY_UNCOLORED = "mt-0.5 text-[13px] font-normal tracking-normal md:text-[13px]"
export const TABLE_CELL_CAPTION_UNCOLORED = "mt-0.5 text-[13px] tracking-normal"

/** Secondary line under a primary value (symbol, venue, USD sub-line). */
export const TABLE_CELL_SECONDARY = `${TABLE_CELL_SECONDARY_UNCOLORED} text-muted-foreground dark:text-white/38`

/** Caption under a stacked metric (per day, liquidation value). */
export const TABLE_CELL_CAPTION = `${TABLE_CELL_CAPTION_UNCOLORED} text-muted-foreground dark:text-white/40`

/** Inline numeric metric with tabular alignment. Keep amount + symbol on one line. */
export const TABLE_CELL_NUMERIC = `${TABLE_CELL_PRIMARY} tabular-nums whitespace-nowrap`

/** Index column (#) in numbered tables. */
export const TABLE_CELL_INDEX =
  "align-middle font-data text-[14px] font-medium tabular-nums text-muted-foreground dark:text-white/52"

/** Standard data cell padding. */
export const TABLE_CELL_PADDING = "py-3 px-4"

/** First column padding when it holds row identity. */
export const TABLE_CELL_PADDING_LEADING = "py-3 pl-6 pr-3"

/** Trailing data column padding. */
export const TABLE_CELL_PADDING_TRAILING = "py-3 px-4 pr-5"

/** Shared table row hover treatment for lend, borrow, multiply, and dashboard tables. */
export const TABLE_ROW_HOVER_BG = "transition-colors group-hover:bg-hover"
export const TABLE_ROW_HOVER_LEFT = TABLE_ROW_HOVER_BG
export const TABLE_ROW_HOVER_RIGHT = TABLE_ROW_HOVER_BG

/**
 * Column kinds shared by every desktop table, with the width (px, padding included) each one
 * needs to show its content without truncating. One kind = one width everywhere, so an APY
 * column on Lend is as wide as the APY column on Multiply.
 */
export const TABLE_COLUMN_MIN_PX = {
  /** `#` row index. */
  index: 56,
  /** Asset / pool / loop identity (icon + two text lines). Pinned while the rest scrolls. */
  identity: 264,
  /** Identity in the narrower dashboard column. Pinned like `identity`. */
  identityCompact: 248,
  /** Short single value: APY, fees, LTV, leverage, premium. */
  compact: 104,
  /** Token amount over a USD sub-line. */
  metric: 136,
  /** Value over a long sub-line (e.g. wallet value over its P/L). */
  metricWide: 176,
  /** Capacity-filled ring + percentage (header label is the long one). */
  gauge: 164,
  /** One action button. */
  action: 160,
  /** One action button in the narrower dashboard column (no "Review risk"-length labels). */
  actionCompact: 144,
  /** One button on desktop, two on phones (e.g. My Deposits: Withdraw, plus Add on phones). */
  actionPhone2: 144,
  /** Two action buttons side by side. */
  actions2: 212,
  /** Bare row-open arrow. */
  arrow: 72,
} as const

export type TableColumnKind = keyof typeof TABLE_COLUMN_MIN_PX

/**
 * Kinds whose share of the table is taken from a reference width instead of the table's own
 * mix of columns. Every table on a page shares that reference, so the index, identity, and
 * action columns (and the pinned column's edge) land in the same place on every table; only the
 * data columns in between vary.
 */
const ANCHOR_KINDS: ReadonlySet<TableColumnKind> = new Set([
  "index",
  "identity",
  "identityCompact",
  "action",
  "actionCompact",
  "actionPhone2",
  "actions2",
  "arrow",
])

/** Smallest width an anchor column may shrink to before the table scrolls instead. */
const ANCHOR_FLOOR_PX: Partial<Record<TableColumnKind, number>> = {
  index: 44,
  identity: 232,
  identityCompact: 228,
  action: 144,
  actionCompact: 140,
  actionPhone2: 140,
  actions2: 204,
  arrow: 56,
}

/** Market pages' content column (`max-w-[1152px]`). */
export const MARKET_TABLE_REFERENCE_PX = 1152

/** Dashboard main column beside the activity rail at the 1152px page width. */
export const DASHBOARD_TABLE_REFERENCE_PX = 712

export type TableColumnLayout = {
  /** Column kinds, in order (drives the phone widths in `TABLE_COLUMN_PHONE_CLASS`). */
  kinds: readonly TableColumnKind[]
  /** Table min-width in px — the table fits its container above this and scrolls below it. */
  minWidth: number
  /** Per-column `<col>` widths as percentages. */
  widths: string[]
}

/**
 * Turns an ordered list of column kinds into a `table-fixed` layout (percentages only — browsers
 * ignore `calc()` in column widths). Anchor kinds take `px / referenceWidth` of the table; data
 * columns split the rest in proportion to their minimums. `minWidth` is the narrowest width at
 * which every data column still gets its minimum and every anchor its floor.
 */
export function tableColumnLayout(
  kinds: readonly TableColumnKind[],
  { referenceWidth = MARKET_TABLE_REFERENCE_PX }: { referenceWidth?: number } = {},
): TableColumnLayout {
  const anchorShare = (kind: TableColumnKind) => TABLE_COLUMN_MIN_PX[kind] / referenceWidth
  const anchorTotal = kinds.reduce((sum, kind) => (ANCHOR_KINDS.has(kind) ? sum + anchorShare(kind) : sum), 0)
  const flexPx = kinds.reduce((sum, kind) => (ANCHOR_KINDS.has(kind) ? sum : sum + TABLE_COLUMN_MIN_PX[kind]), 0)
  const flexTotal = Math.max(0, 1 - anchorTotal)
  const shares = kinds.map((kind) =>
    ANCHOR_KINDS.has(kind) || flexPx === 0
      ? anchorShare(kind) / (flexPx === 0 ? anchorTotal : 1)
      : (flexTotal * TABLE_COLUMN_MIN_PX[kind]) / flexPx,
  )
  const minWidth = Math.ceil(
    Math.max(
      ...kinds.map((kind, index) => {
        const floor = ANCHOR_KINDS.has(kind)
          ? (ANCHOR_FLOOR_PX[kind] ?? TABLE_COLUMN_MIN_PX[kind])
          : TABLE_COLUMN_MIN_PX[kind]
        return shares[index] > 0 ? floor / shares[index] : 0
      }),
    ),
  )
  return { kinds, minWidth, widths: shares.map((share) => `${(share * 100).toFixed(3)}%`) }
}

/**
 * Phone (< md) column widths. Phones show the same tables as desktop, so the percentages above
 * (tuned for a 1152px row) would leave a ~240px pinned column on a 351px screen. Below md each
 * column takes a fixed px width instead (`!` beats the inline percentage), the identity column
 * narrows so a column and a half of data stays visible beside it, and the `#` column is hidden.
 * Literal class names so Tailwind can see them.
 */
export const TABLE_COLUMN_PHONE_CLASS: Record<TableColumnKind, string> = {
  index: "max-md:hidden",
  identity: "max-md:!w-[204px]",
  identityCompact: "max-md:!w-[204px]",
  compact: "max-md:!w-[104px]",
  metric: "max-md:!w-[136px]",
  metricWide: "max-md:!w-[176px]",
  gauge: "max-md:!w-[164px]",
  action: "max-md:!w-[148px]",
  actionCompact: "max-md:!w-[140px]",
  actionPhone2: "max-md:!w-[212px]",
  actions2: "max-md:!w-[212px]",
  arrow: "max-md:!w-[64px]",
}

/** Hides the `#` cells on phones (pair with the `index` column's `max-md:hidden`). */
export const TABLE_INDEX_PHONE_HIDDEN = "max-md:hidden"

/** Row action pill: one minimum width so Pledge / Deposit / Borrow / Multiply line up. */
export const TABLE_ACTION_BUTTON = "w-auto min-w-[108px] justify-center"

/** Table element classes for the shared layout (pair with `style={{ minWidth }}`). */
export const TABLE_FIXED = "w-full table-fixed border-separate border-spacing-0"

/**
 * Pinned identity column. The cell keeps an opaque page background so scrolled columns pass
 * underneath it; row hover is painted with an inset shadow instead of the translucent
 * `bg-hover` (which would let the scrolled content show through).
 */
const TABLE_STICKY_BODY =
  "sticky z-[1] bg-background transition-shadow group-hover:shadow-[inset_0_0_0_9999px_hsl(var(--hover-overlay))]"
const TABLE_STICKY_HEADER = "sticky z-[2] bg-table-header"

/**
 * Classes for the pinned identity cell. It sticks at the left edge: a leading `#` column
 * scrolls away underneath it, then the data columns slide under it. No divider line: the
 * opaque background alone marks the edge.
 */
export function tableStickyCell(part: "header" | "body"): string {
  // Tighter side padding on phones: the pinned column is only 204px there.
  return `${part === "header" ? TABLE_STICKY_HEADER : TABLE_STICKY_BODY} left-0 max-md:!pl-3 max-md:!pr-2`
}
