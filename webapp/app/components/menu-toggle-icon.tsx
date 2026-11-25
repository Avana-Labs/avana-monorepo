import { cn } from "@/lib/utils"

const BAR =
  "absolute left-1/2 top-1/2 h-[2px] w-[22px] rounded-full bg-current transition-[transform,opacity] duration-300 ease-[cubic-bezier(0.32,0.72,0,1)] motion-reduce:transition-none"

/**
 * Mobile menu toggle glyph: three bars that morph into an X (and back) in place. The outer bars
 * slide to the center and rotate; their arms stretch so the X reads as large as the bars. Shared
 * by the lazy trigger and the loaded menu, so swapping one for the other never changes the icon.
 */
export function MenuToggleIcon({ open, className }: { open: boolean; className?: string }) {
  return (
    <span aria-hidden="true" className={cn("relative block size-[30px]", className)}>
      <span
        className={BAR}
        style={{ transform: open ? "translate(-50%, -50%) rotate(45deg) scaleX(1.18)" : "translate(-50%, -7px)" }}
      />
      <span
        className={BAR}
        style={{ transform: open ? "translate(-50%, -50%) scaleX(0)" : "translate(-50%, -50%)", opacity: open ? 0 : 1 }}
      />
      <span
        className={BAR}
        style={{ transform: open ? "translate(-50%, -50%) rotate(-45deg) scaleX(1.18)" : "translate(-50%, 5px)" }}
      />
    </span>
  )
}
