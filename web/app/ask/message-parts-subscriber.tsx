"use client"

import * as React from "react"
import { useQuery } from "convex/react"
import { api } from "@/convex/_generated/api"

export type AskAIMessagePartsRow = { messageId: string; parts: unknown }

// Rich assistant parts (result cards, sources, retrieval chunks) are enhancement
// data layered onto the streamed answer. A fetch failure should degrade to "no
// cards", never blank the whole chat — so the live subscription runs behind an
// error boundary that reports empty on error and recovers on the next success.
class MessagePartsBoundary extends React.Component<{ children: React.ReactNode }, { errored: boolean }> {
  state = { errored: false }
  static getDerivedStateFromError() {
    return { errored: true }
  }
  render() {
    return this.state.errored ? null : this.props.children
  }
}

function MessagePartsQuery({ threadId, onData }: { threadId: string; onData: (rows: AskAIMessagePartsRow[]) => void }) {
  const parts = useQuery(api.askAI.messageParts, { threadId })
  React.useEffect(() => {
    if (parts) onData(parts)
  }, [parts, onData])
  return null
}

/** Renders nothing; pushes the thread's rich parts to `onData`, fail-soft. */
export function AskAIMessagePartsSubscriber({
  threadId,
  onData,
}: {
  threadId: string | null
  onData: (rows: AskAIMessagePartsRow[]) => void
}) {
  if (!threadId) return null
  // key resets the boundary + query when the thread changes.
  return (
    <MessagePartsBoundary key={threadId}>
      <MessagePartsQuery threadId={threadId} onData={onData} />
    </MessagePartsBoundary>
  )
}
