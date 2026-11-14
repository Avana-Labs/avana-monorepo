import type { ReactNode } from "react"
import { ActionsLayoutChrome } from "@/app/actions/actions-layout-chrome"

// Standalone /actions/* pages render focused transaction chrome from ActionPageShell.
export default function ActionsLayout({ children }: { children: ReactNode }) {
  return <ActionsLayoutChrome>{children}</ActionsLayoutChrome>
}
