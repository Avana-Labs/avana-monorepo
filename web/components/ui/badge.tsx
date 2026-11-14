import * as React from "react"
import { cva, type VariantProps } from "class-variance-authority"

import { cn } from "@/lib/utils"

const badgeVariants = cva(
  "inline-flex items-center rounded-xs border px-1.5 py-0.5 font-compact text-[11px] font-normal leading-4 tracking-[0.01em] transition-colors focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-1",
  {
    variants: {
      variant: {
        default: "border-transparent bg-accent-primary text-accent-primary-foreground hover:bg-accent-primary-hover",
        secondary: "border-border bg-surface-inset text-foreground hover:bg-surface-hover",
        destructive: "border-transparent bg-destructive/10 text-destructive hover:bg-destructive/15 dark:text-rose-300",
        outline: "border-border text-muted-foreground",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  },
)

interface BadgeProps extends React.HTMLAttributes<HTMLDivElement>, VariantProps<typeof badgeVariants> {}

function Badge({ className, variant, ...props }: BadgeProps) {
  return <div className={cn(badgeVariants({ variant }), className)} {...props} />
}

export { Badge }
