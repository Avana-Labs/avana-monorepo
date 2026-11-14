import { buttonVariants } from "@/components/ui/button"
import { cn } from "@/lib/utils"

/**
 * Canonical action CTAs — one Uniswap-style treatment shared by every
 * lend / borrow / multiply / express surface. The visual tokens now live in the
 * shared Button (`buttonVariants` `brand` / `brand-secondary` variants + `cta` /
 * `compact` sizes); these helpers just adapt them for callers that render a class
 * string on a plain <button>/<Link> (e.g. the sticky action bars and ActionFooter).
 * Prefer `<Button variant="brand" size="cta">` in new code.
 *
 * Primary  enabled : solid brand (cyan) fill + white text.
 * Primary  disabled: soft brand tint + legible brand text (a <Link> can't be
 *                    `:disabled`, so the tint is painted explicitly here).
 * Secondary        : outlined surface button, matched height/radius.
 *
 * Sizes:
 *   "default" (h-14) — the final confirm/submit button inside an action flow.
 *   "compact" (h-12) — slimmer, for sticky detail-page action bars.
 */
type CtaSize = "default" | "compact"

const SIZE_TO_BUTTON = { default: "cta", compact: "compact" } as const

export function primaryCtaClass(
  opts: { disabled?: boolean; pending?: boolean; size?: CtaSize; className?: string } = {},
): string {
  const { disabled, pending, size = "default", className } = opts
  return cn(
    buttonVariants({ variant: "brand", size: SIZE_TO_BUTTON[size] }),
    "cursor-pointer disabled:cursor-not-allowed",
    // A <Link> can't be `:disabled`, so paint the disabled look directly for it.
    disabled && "cursor-not-allowed bg-brand-soft text-brand-soft-foreground hover:bg-brand-soft active:bg-brand-soft",
    pending && "opacity-80",
    className,
  )
}

export function secondaryCtaClass(opts: { size?: CtaSize; className?: string } = {}): string {
  const { size = "default", className } = opts
  return cn(buttonVariants({ variant: "brand-secondary", size: SIZE_TO_BUTTON[size] }), className)
}

/** Default-size secondary CTA class string (used by the in-flow ActionFooter). */
export const SECONDARY_CTA_CLASS = secondaryCtaClass()
