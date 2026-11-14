"use client"

import { useCallback, useEffect } from "react"
import { useMutation } from "convex/react"
import { api } from "@/convex/_generated/api"
import type { SupportSubmit } from "./support-center-client"

export function ConvexSupportSubmissionBridge({ onReady }: { onReady: (submit: SupportSubmit | null) => void }) {
  const submitSupportRequest = useMutation(api.support.submitSupportRequest)
  const submit = useCallback<SupportSubmit>(
    async (payload) => {
      await submitSupportRequest({
        ...payload,
        userAgent: typeof navigator !== "undefined" ? navigator.userAgent : undefined,
      })
    },
    [submitSupportRequest],
  )

  useEffect(() => {
    onReady(submit)
    return () => onReady(null)
  }, [onReady, submit])

  return null
}
