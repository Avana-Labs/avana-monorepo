"use client"

import ReactMarkdown from "react-markdown"
import remarkGfm from "remark-gfm"
import { safeAskAIUrl } from "@/app/lib/ask-ai/sources"

/** Streamed prose is also an untrusted surface. Links belong in Sources; only
 * official protocol/app destinations are actionable inline. Never load images.
 */
export function AskAIMarkdown({ text }: { text: string }) {
  return (
    <div className="aui-md break-words [&_p]:my-3 [&_p:first-child]:mt-0 [&_p:last-child]:mb-0 [&_ul]:list-disc [&_ul]:pl-5 [&_ol]:list-decimal [&_ol]:pl-5">
      <ReactMarkdown
        remarkPlugins={[remarkGfm]}
        components={{
          a: ({ href, children }) => {
            const safe = safeAskAIUrl(href, true)
            return safe ? (
              <a href={safe} rel="noreferrer" target="_blank" className="text-primary underline underline-offset-2">
                {children}
              </a>
            ) : (
              <span>{children}</span>
            )
          },
          img: ({ alt }) => <span>{alt}</span>,
        }}
      >
        {text}
      </ReactMarkdown>
    </div>
  )
}
