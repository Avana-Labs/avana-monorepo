import type { ComponentType, SVGProps } from "react"
import { HugeiconsIcon, type HugeiconsIconProps } from "@hugeicons/react"
import {
  AlertTriangle as _AlertTriangle,
  ArrowDown as _ArrowDown,
  ArrowLeft as _ArrowLeft,
  ArrowRight as _ArrowRight,
  ArrowShrinkIcon as _ArrowShrink,
  ArrowUpRight as _ArrowUpRight,
  ArrowUpRight03Icon as _ArrowUpRightLong,
  ArrowUpRightStackIcon as _ArrowUpRightStack,
  BookOpen as _BookOpen,
  Check as _Check,
  CheckCircle as _CheckCircle,
  ChevronDown as _ChevronDown,
  ChevronLeft as _ChevronLeft,
  ChevronRight as _ChevronRight,
  ChevronUp as _ChevronUp,
  Circle as _Circle,
  CircleArrowOutDownRightIcon as _CircleArrowOutDownRight,
  CircleArrowOutUpLeftIcon as _CircleArrowOutUpLeft,
  CircleArrowUp as _CircleArrowUp,
  Code as _Code,
  Coins as _Coins,
  Compass as _Compass,
  Copy as _Copy,
  DashboardSquareAddIcon as _DashboardSquareAdd,
  DollarCircleIcon as _DollarCircleIcon,
  Droplets as _Droplets,
  EnteringGeoFenceIcon as _EnteringGeoFence,
  ExternalLink as _ExternalLink,
  Eye as _Eye,
  EyeOff as _EyeOff,
  FileText as _FileText,
  Flame as _Flame,
  GiftIcon as _Gift,
  Globe as _Globe,
  GraduationCap as _GraduationCap,
  Heart as _Heart,
  HelpCircleIcon as _HelpCircleIcon,
  Info as _Info,
  LayerSendBackwardIcon as _LayerSendBackward,
  Layers as _Layers,
  LeavingGeoFenceIcon as _LeavingGeoFence,
  LifeBuoy as _LifeBuoy,
  Link2 as _Link2,
  LoaderCircle as _LoaderCircle,
  LockKeyhole as _LockKeyhole,
  Mail as _Mail,
  Menu as _Menu,
  MessageSquare as _MessageSquare,
  MoonStar as _MoonStar,
  MoreHorizontal as _MoreHorizontal,
  MoveUpRight as _MoveUpRight,
  Orbit as _Orbit,
  PieChart as _PieChart,
  Repeat as _Repeat,
  Repeat2 as _Repeat2,
  Rocket as _Rocket,
  Search as _Search,
  Shield as _Shield,
  ShieldCheck as _ShieldCheck,
  Sparkles as _Sparkles,
  SquareLock02Icon as _SquareLock02,
  SunMedium as _SunMedium,
  Target as _Target,
  TrendingUp as _TrendingUp,
  Trophy as _Trophy,
  Umbrella as _Umbrella,
  Unlock as _Unlock,
  Wallet as _Wallet,
  X as _X,
} from "@hugeicons/core-free-icons"

/**
 * Central icon module. Every app icon renders via Hugeicons; this re-exports them
 * under Lucide-compatible component names so call sites keep the <Icon className=…/>
 * API. Generated to drop the lucide-react dependency.
 */
type IconProps = SVGProps<SVGSVGElement> & { size?: string | number }
export type IconComponent = ComponentType<IconProps>
// Back-compat alias for the old lucide type name.
export type LucideIcon = IconComponent

// This factory only creates a component; PURE annotations let unused icons be removed per route.
function makeIcon(icon: HugeiconsIconProps["icon"]): IconComponent {
  function Icon({ size, strokeWidth, ...rest }: IconProps) {
    return (
      <HugeiconsIcon
        icon={icon}
        size={size}
        strokeWidth={strokeWidth == null ? undefined : Number(strokeWidth)}
        {...rest}
      />
    )
  }
  return Icon
}

export const AlertTriangle: IconComponent = /*#__PURE__*/ makeIcon(_AlertTriangle)
export const ArrowDown: IconComponent = /*#__PURE__*/ makeIcon(_ArrowDown)
export const ArrowLeft: IconComponent = /*#__PURE__*/ makeIcon(_ArrowLeft)
export const ArrowRight: IconComponent = /*#__PURE__*/ makeIcon(_ArrowRight)
export const ArrowShrink: IconComponent = /*#__PURE__*/ makeIcon(_ArrowShrink)
export const ArrowUpRight: IconComponent = /*#__PURE__*/ makeIcon(_ArrowUpRight)
/** Same diagonal as ArrowUpRight with a longer shaft — reads clearly at small sizes. */
export const ArrowUpRightLong: IconComponent = /*#__PURE__*/ makeIcon(_ArrowUpRightLong)
export const ArrowUpRightStack: IconComponent = /*#__PURE__*/ makeIcon(_ArrowUpRightStack)
export const BadgeDollarSign: IconComponent = /*#__PURE__*/ makeIcon(_DollarCircleIcon)
export const BookOpen: IconComponent = /*#__PURE__*/ makeIcon(_BookOpen)
export const Check: IconComponent = /*#__PURE__*/ makeIcon(_Check)
export const CheckCircle2: IconComponent = /*#__PURE__*/ makeIcon(_CheckCircle)
export const ChevronDown: IconComponent = /*#__PURE__*/ makeIcon(_ChevronDown)
export const ChevronLeft: IconComponent = /*#__PURE__*/ makeIcon(_ChevronLeft)
export const ChevronRight: IconComponent = /*#__PURE__*/ makeIcon(_ChevronRight)
export const ChevronUp: IconComponent = /*#__PURE__*/ makeIcon(_ChevronUp)
export const Circle: IconComponent = /*#__PURE__*/ makeIcon(_Circle)
export const CircleArrowOutDownRight: IconComponent = /*#__PURE__*/ makeIcon(_CircleArrowOutDownRight)
export const CircleArrowOutUpLeft: IconComponent = /*#__PURE__*/ makeIcon(_CircleArrowOutUpLeft)
export const CircleArrowUp: IconComponent = /*#__PURE__*/ makeIcon(_CircleArrowUp)
export const CircleDollarSign: IconComponent = /*#__PURE__*/ makeIcon(_DollarCircleIcon)
export const CircleHelp: IconComponent = /*#__PURE__*/ makeIcon(_HelpCircleIcon)
export const Code2: IconComponent = /*#__PURE__*/ makeIcon(_Code)
export const Coins: IconComponent = /*#__PURE__*/ makeIcon(_Coins)
export const Compass: IconComponent = /*#__PURE__*/ makeIcon(_Compass)
export const Copy: IconComponent = /*#__PURE__*/ makeIcon(_Copy)
export const DashboardSquareAdd: IconComponent = /*#__PURE__*/ makeIcon(_DashboardSquareAdd)
export const Droplets: IconComponent = /*#__PURE__*/ makeIcon(_Droplets)
export const EnteringGeoFence: IconComponent = /*#__PURE__*/ makeIcon(_EnteringGeoFence)
export const ExternalLink: IconComponent = /*#__PURE__*/ makeIcon(_ExternalLink)
export const Eye: IconComponent = /*#__PURE__*/ makeIcon(_Eye)
export const EyeOff: IconComponent = /*#__PURE__*/ makeIcon(_EyeOff)
export const FileText: IconComponent = /*#__PURE__*/ makeIcon(_FileText)
export const Flame: IconComponent = /*#__PURE__*/ makeIcon(_Flame)
export const Gift: IconComponent = /*#__PURE__*/ makeIcon(_Gift)
export const Globe: IconComponent = /*#__PURE__*/ makeIcon(_Globe)
export const Globe2: IconComponent = /*#__PURE__*/ makeIcon(_Globe)
export const GraduationCap: IconComponent = /*#__PURE__*/ makeIcon(_GraduationCap)
export const Heart: IconComponent = /*#__PURE__*/ makeIcon(_Heart)
export const Info: IconComponent = /*#__PURE__*/ makeIcon(_Info)
export const LayerSendBackward: IconComponent = /*#__PURE__*/ makeIcon(_LayerSendBackward)
export const Layers3: IconComponent = /*#__PURE__*/ makeIcon(_Layers)
export const LeavingGeoFence: IconComponent = /*#__PURE__*/ makeIcon(_LeavingGeoFence)
export const LifeBuoy: IconComponent = /*#__PURE__*/ makeIcon(_LifeBuoy)
export const Link2: IconComponent = /*#__PURE__*/ makeIcon(_Link2)
export const LoaderCircle: IconComponent = /*#__PURE__*/ makeIcon(_LoaderCircle)
export const LockKeyhole: IconComponent = /*#__PURE__*/ makeIcon(_LockKeyhole)
export const Mail: IconComponent = /*#__PURE__*/ makeIcon(_Mail)
export const Menu: IconComponent = /*#__PURE__*/ makeIcon(_Menu)
export const MessageSquare: IconComponent = /*#__PURE__*/ makeIcon(_MessageSquare)
export const MoonStar: IconComponent = /*#__PURE__*/ makeIcon(_MoonStar)
export const MoreHorizontal: IconComponent = /*#__PURE__*/ makeIcon(_MoreHorizontal)
export const MoveUpRight: IconComponent = /*#__PURE__*/ makeIcon(_MoveUpRight)
export const Orbit: IconComponent = /*#__PURE__*/ makeIcon(_Orbit)
export const PieChart: IconComponent = /*#__PURE__*/ makeIcon(_PieChart)
export const Repeat: IconComponent = /*#__PURE__*/ makeIcon(_Repeat)
export const Repeat2: IconComponent = /*#__PURE__*/ makeIcon(_Repeat2)
export const Rocket: IconComponent = /*#__PURE__*/ makeIcon(_Rocket)
export const Search: IconComponent = /*#__PURE__*/ makeIcon(_Search)
export const Shield: IconComponent = /*#__PURE__*/ makeIcon(_Shield)
export const ShieldCheck: IconComponent = /*#__PURE__*/ makeIcon(_ShieldCheck)
export const Sparkles: IconComponent = /*#__PURE__*/ makeIcon(_Sparkles)
export const SquareLock02: IconComponent = /*#__PURE__*/ makeIcon(_SquareLock02)
export const SunMedium: IconComponent = /*#__PURE__*/ makeIcon(_SunMedium)
export const Target: IconComponent = /*#__PURE__*/ makeIcon(_Target)
export const TrendingUp: IconComponent = /*#__PURE__*/ makeIcon(_TrendingUp)
export const Trophy: IconComponent = /*#__PURE__*/ makeIcon(_Trophy)
export const Umbrella: IconComponent = /*#__PURE__*/ makeIcon(_Umbrella)
export const Unlock: IconComponent = /*#__PURE__*/ makeIcon(_Unlock)
export const Wallet: IconComponent = /*#__PURE__*/ makeIcon(_Wallet)
export const X: IconComponent = /*#__PURE__*/ makeIcon(_X)
