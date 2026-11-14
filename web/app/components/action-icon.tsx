import type { LucideIcon } from "@/app/components/icons"
import {
  AlertTriangle,
  ArrowShrink,
  ArrowUpRight,
  Circle,
  CircleArrowUp,
  CircleArrowOutDownRight,
  CircleArrowOutUpLeft,
  EnteringGeoFence,
  Gift,
  LayerSendBackward,
  LeavingGeoFence,
  Repeat2,
  SquareLock02,
  Unlock,
  X,
} from "@/app/components/icons"

const ACTION_ICONS: Record<string, LucideIcon> = {
  deposit: EnteringGeoFence,
  supply: EnteringGeoFence,
  pledge: SquareLock02,
  borrow: CircleArrowOutDownRight,
  repay: CircleArrowOutUpLeft,
  withdraw: LeavingGeoFence,
  deleverage: ArrowShrink,
  close: X,
  swap: Repeat2,
  stake: CircleArrowUp,
  claim: Gift,
  cooldown: Circle,
  unstake: Unlock,
  remove: LayerSendBackward,
  // Opens the market/position detail page.
  manage: ArrowUpRight,
  // Risk-review pill keeps the same shape as the other action pills.
  "review risk": AlertTriangle,
}

/** Renders the directional icon for an action label, or nothing if unmapped.
 * Sizing/color come from the parent Button (`[&_svg]:size-3.5`, text color). */
export function ActionIcon({ label, className }: { label: string; className?: string }) {
  const Icon = ACTION_ICONS[label.trim().toLowerCase()]
  return Icon ? <Icon className={className} strokeWidth={2.1} aria-hidden="true" /> : null
}
