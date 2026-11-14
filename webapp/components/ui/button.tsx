import * as React from "react"
import { Slot } from "@radix-ui/react-slot"
import { cva, type VariantProps } from "class-variance-authority"

import { cn } from "@/lib/utils"

const buttonVariants = cva(
  "inline-flex items-center justify-center gap-1.5 whitespace-nowrap rounded-radius-sm text-[13px] font-normal leading-5 ring-offset-background transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-1 disabled:pointer-events-none disabled:opacity-50 [&_svg]:pointer-events-none [&_svg]:size-3.5 [&_svg]:shrink-0",
  {
    variants: {
      variant: {
        default: "bg-accent-primary text-accent-primary-foreground shadow-elev-1 hover:bg-accent-primary-hover",
        destructive: "bg-destructive text-destructive-foreground hover:bg-destructive/90",
        outline: "border border-border bg-surface-raised text-foreground hover:bg-surface-hover",
        secondary: "border border-border bg-surface-inset text-foreground hover:bg-surface-hover",
        ghost: "text-muted-foreground hover:bg-hover hover:text-foreground",
        link: "text-foreground underline-offset-2 hover:underline",
        // Canonical action CTA (Uniswap-style solid brand fill). Disabled falls back
        // to the soft brand tint instead of a low-contrast dimmed fill.
        brand:
          "w-full bg-brand text-white hover:bg-brand/90 active:bg-brand/80 focus-visible:ring-brand/40 disabled:!opacity-100 disabled:bg-brand-soft disabled:text-brand-soft-foreground",
        // Secondary CTA that pairs with `brand` (matched height/radius).
        "brand-secondary": "w-full border border-border bg-surface-raised text-foreground hover:bg-surface-hover",
        // Muted pill that pairs with `brand` inside desktop table action columns.
        // Rests muted, then jumps to a solid mid-gray on row hover — a clear step
        // (not the near-identical surface tokens) so it reads plainly "on".
        "table-secondary":
          "w-auto bg-muted text-foreground group-hover:bg-neutral-300 group-focus-within:bg-neutral-300 dark:group-hover:bg-neutral-700 dark:group-focus-within:bg-neutral-700 disabled:!opacity-100 disabled:!bg-muted disabled:!text-muted-foreground",
        // Primary table pill: mobile has no row-hover state, so it renders as
        // the Avana brand CTA immediately. Desktop rests muted, then turns
        // brand cyan with white text on row/button hover, focus, or active press.
        "table-primary":
          "w-auto bg-brand text-white hover:bg-brand/90 active:bg-brand/80 focus-visible:ring-brand/40 md:bg-muted md:text-foreground md:hover:!bg-brand/90 md:hover:!text-white md:active:!bg-brand/80 md:active:!text-white md:group-hover:!bg-brand md:group-hover:!text-white md:group-focus-within:!bg-brand md:group-focus-within:!text-white disabled:!opacity-100 disabled:!bg-brand-soft disabled:!text-brand-soft-foreground md:disabled:!bg-muted md:disabled:!text-muted-foreground",
      },
      size: {
        default: "h-9 px-3",
        sm: "h-8 rounded-radius-sm px-2.5 text-[12px]",
        lg: "h-10 rounded-radius-sm px-4",
        icon: "h-9 w-9",
        // Full-height action-flow CTAs.
        cta: "h-14 rounded-radius-xl px-4 text-[16px]",
        compact: "h-12 rounded-radius-xl px-4 text-[15px]",
        table: "h-auto gap-2 rounded-full px-3.5 py-2 text-[14px] [&_svg]:size-4",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  },
)

interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement>, VariantProps<typeof buttonVariants> {
  asChild?: boolean
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, asChild = false, ...props }, ref) => {
    const Comp = asChild ? Slot : "button"
    return <Comp className={cn(buttonVariants({ variant, size, className }))} ref={ref} {...props} />
  },
)
Button.displayName = "Button"

export { Button, buttonVariants }
