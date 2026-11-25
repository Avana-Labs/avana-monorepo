import type { ReactNode } from "react"

export function ActionsLayoutChrome({ children }: { children: ReactNode }) {
  return <div className="min-h-[100dvh] bg-background">{children}</div>
}
