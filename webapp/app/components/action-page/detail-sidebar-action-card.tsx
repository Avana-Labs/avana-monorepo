import type { ReactNode } from "react"
import { cn } from "@/lib/utils"

export function DetailSidebarActionCard({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <div className={cn("flex flex-col gap-2", className)} data-testid="detail-sidebar-action-card">
      {children}
    </div>
  )
}
