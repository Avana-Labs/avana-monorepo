"use client"

import { type ThreadMessage, ThreadPrimitive } from "@assistant-ui/react"
import { useMutation } from "convex/react"
import Link from "next/link"
import { ArrowUp, Check, ChevronDown, Copy, Square, ThumbsDown, ThumbsUp } from "lucide-react"
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react"
import type { ComponentType, MouseEvent as ReactMouseEvent } from "react"
import { Code2, PieChart, Sparkles, SunMedium, TrendingUp } from "@/app/components/icons"
import { ASK_AI_CONFIG } from "@/convex/lib/askAI/config"
import { Chart } from "@/components/elements/chart"
import { ErrorState } from "@/components/elements/error-state"
import { FeedbackDialog } from "@/components/elements/feedback-dialog"
import {
  Composer as ElementComposer,
  ComposerActions,
  ComposerBar,
  ComposerContext,
  ComposerToolbar,
} from "@/components/elements/composer"
import { ThinkingIndicator } from "@/components/elements/thinking-indicator"
import { AskAIThreadSkeleton } from "./ask-ai-skeleton"
import { MessageQueue } from "@/components/elements/message-queue"
import { RetrievalChunks, type RetrievalChunk } from "@/components/elements/retrieval-chunks"
import { Sources, type Source } from "@/components/elements/sources"
import { AskAIMarkdown } from "./ask-ai-markdown"
import { AskAIAaveChart } from "./ask-ai-aave-chart"
import type { AaveApyVisual } from "@/convex/lib/askAI/aaveMcp"
import { sanitizeAskAISources } from "@/convex/lib/askAI/sources"
import { api } from "@/convex/_generated/api"
import type { AskAIUsage } from "@/convex/lib/askAI/chatProtocol"
import { formatAskAIMessageTimestamp } from "@/app/lib/ask-ai/message-timestamp"
import { formatAskAIGreeting } from "@/app/lib/ask-ai/greeting"
import { AskAIFinancialResultCard, type AskAIFinancialResult } from "./ask-ai-financial-result-card"
import { AskAiRunCards } from "./ask-ai-run-cards"
import type { AskAiRun } from "@/convex/lib/askAI/modeRun"

const FEEDBACK_REASONS = ["Incorrect", "Outdated data", "Not helpful", "Missing context", "Unsafe", "Other"]

type AskAISuggestion = {
  icon: ComponentType<{ className?: string }>
  label: string
  prompt: string
}

// Single source of truth for the starter prompts. The thread renders these as
// labeled pills; the page-client derives the runtime `suggestions` adapter list
// from the same array so the two never drift.
export const ASK_AI_SUGGESTIONS: readonly AskAISuggestion[] = [
  { icon: SunMedium, label: "Markets", prompt: "Find ETH/USDC markets" },
  { icon: Code2, label: "Positions", prompt: "Analyze my positions" },
  { icon: TrendingUp, label: "Borrow", prompt: "How much can I borrow?" },
  { icon: PieChart, label: "Risk", prompt: "What is my health factor?" },
  { icon: Sparkles, label: "Stress test", prompt: "What if ETH falls 20%?" },
]

// User-facing error copy, keyed by the ConvexError `code` thrown server-side.
// Never surface raw error text (it can leak function paths / request ids).
export const ASK_AI_ERROR_COPY: Record<string, string> = {
  ASK_AI_GENERATION_FAILED: "Avana couldn't finish this answer. Please try again.",
  ASK_AI_ATTACHMENT_FAILED: "We couldn't read that attachment. Remove it and try again.",
  ASK_AI_RATE_LIMITED: "You're sending messages too quickly. Wait a moment, then try again.",
  ASK_AI_UNAVAILABLE: "Ask AI is temporarily unavailable. Please try again shortly.",
}
export const FALLBACK_ASK_AI_ERROR = "Something went wrong generating this answer. Please try again."

export type FriendlyAskAIError = { code?: string; message: string }

// Normalizes an unknown thrown value into a user-safe { code, message }. Reads
// the ConvexError payload (`error.data`) when present; otherwise falls back to
// generic copy. Never returns raw `String(error)`.
export function toFriendlyAskAIError(error: unknown): FriendlyAskAIError {
  const data = (error as { data?: unknown } | null | undefined)?.data
  if (data && typeof data === "object") {
    const record = data as { code?: unknown; message?: unknown }
    const code = typeof record.code === "string" ? record.code : undefined
    const message =
      typeof record.message === "string" && record.message.trim()
        ? record.message
        : ((code ? ASK_AI_ERROR_COPY[code] : undefined) ?? FALLBACK_ASK_AI_ERROR)
    return code ? { code, message } : { message }
  }
  return { message: FALLBACK_ASK_AI_ERROR }
}

// Resolves the detail line for the error card from a message `status.error`
// value (our FriendlyAskAIError, or nothing for a persisted failed turn).
export function resolveAskAIErrorDetail(rawError: unknown): string {
  if (rawError && typeof rawError === "object") {
    const err = rawError as { code?: unknown; message?: unknown }
    if (typeof err.message === "string" && err.message.trim()) return err.message
    if (typeof err.code === "string" && ASK_AI_ERROR_COPY[err.code]) return ASK_AI_ERROR_COPY[err.code]
  }
  return FALLBACK_ASK_AI_ERROR
}

// Live "thinking" status line (assistant-ui element) with elapsed time, shown before the first token.
function ThinkingIndicatorLive({ label = "Thinking…" }: { label?: string }) {
  const [start] = useState(() => Date.now())
  const [seconds, setSeconds] = useState(0)
  useEffect(() => {
    const timer = setInterval(() => setSeconds(Math.max(0, Math.round((Date.now() - start) / 1000))), 1000)
    return () => clearInterval(timer)
  }, [start])
  return <ThinkingIndicator label={label} elapsed={`${seconds}s`} className="py-3" />
}

function DirectMessageTimestamp({
  createdAt,
  align = "left",
}: {
  createdAt?: Date
  align?: "left" | "right" | "inline"
}) {
  if (!(createdAt instanceof Date) || Number.isNaN(createdAt.getTime())) return null
  return (
    <time
      dateTime={createdAt.toISOString()}
      className={`px-2 py-1.5 text-xs leading-none text-muted-foreground ${
        align === "right" ? "self-end" : align === "left" ? "self-start" : "self-center"
      }`}
    >
      {formatAskAIMessageTimestamp(createdAt)}
    </time>
  )
}

function DirectUserMessage({ message }: { message: ThreadMessage }) {
  const text = message.content
    .filter((part) => part.type === "text")
    .map((part) => part.text)
    .join("\n")
  return (
    <div className="group/msg relative mx-auto flex w-full max-w-[var(--thread-max-width)] flex-col px-2 py-2 text-[15px] leading-6 tracking-normal">
      <div className="ml-auto max-w-[min(80%,32rem)] break-words rounded-3xl bg-muted px-5 py-2.5 text-foreground [&_p]:mb-0">
        {text}
      </div>
      <DirectMessageTimestamp createdAt={message.createdAt} align="right" />
    </div>
  )
}

// Sources renders collapsed by default and expands on click. It owns its open state so the
// disclosure actually works — it was previously rendered with a hardcoded open={false} and a
// no-op onOpenChange, which left the pill permanently shut and its links unreachable.
function SourcesPart({ sources }: { sources: Source[] }) {
  const [open, setOpen] = useState(false)
  return <Sources sources={sanitizeAskAISources(sources)} open={open} onOpenChange={setOpen} className="max-w-none" />
}

function DirectAssistantPart({ part }: { part: ThreadMessage["content"][number] }) {
  if (part.type === "text") return <AskAIMarkdown text={part.text} />
  if (part.type !== "data") return null
  if (part.name === "financial-result") return <AskAIFinancialResultCard result={part.data as AskAIFinancialResult} />
  if (part.name === "mode-run") return <AskAiRunCards run={part.data as AskAiRun} />
  if (part.name === "aave-apy") return <AskAIAaveChart visual={part.data as AaveApyVisual} />
  if (part.name === "chart") {
    const data = part.data as { label: string; value: string; points: number[]; delta?: string }
    return <Chart {...data} visibleCount={data.points.length} variant="line" className="max-w-md" />
  }
  if (part.name === "sources") return <SourcesPart sources={part.data as Source[]} />
  if (part.name === "retrieval") {
    const data = part.data as { query: string; chunks: RetrievalChunk[] }
    return (
      <RetrievalChunks
        query={data.query}
        chunks={data.chunks}
        visibleCount={data.chunks.length}
        searching={false}
        className="max-w-none"
      />
    )
  }
  return null
}

function isRenderableAssistantPart(part: ThreadMessage["content"][number]) {
  if (part.type === "text") return part.text.trim().length > 0
  if (part.type !== "data") return false
  return ["financial-result", "mode-run", "chart", "aave-apy", "sources", "retrieval"].includes(part.name)
}

function DirectAssistantMessage({
  message,
  threadId,
  onRetry,
}: {
  message: ThreadMessage
  threadId: string | null
  onRetry: () => void | Promise<void>
}) {
  const submitFeedback = useMutation(api.askAI.submitFeedback)
  const [feedbackOpen, setFeedbackOpen] = useState(false)
  const [selected, setSelected] = useState<string[]>([])
  const [note, setNote] = useState("")
  const [sent, setSent] = useState(false)
  const [copied, setCopied] = useState(false)
  const [helpful, setHelpful] = useState(false)
  const copyResetRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => () => void (copyResetRef.current && clearTimeout(copyResetRef.current)), [])
  const responseText = message.content
    .filter((part) => part.type === "text")
    .map((part) => part.text)
    .join("\n")
  const status = "status" in message ? message.status : undefined
  const complete = status?.type === "complete"
  const failed = status?.type === "incomplete"
  const errorValue = failed && status && "error" in status ? status.error : undefined
  const persisted = !message.id.endsWith("-assistant")
  const renderableContent = message.content.filter(isRenderableAssistantPart)
  return (
    <div className="group/msg px-2 text-[15px] leading-6 tracking-normal text-foreground">
      <div className="flex flex-col gap-3" aria-live="polite" aria-atomic="false">
        {renderableContent.length === 0 && !failed ? (
          // An assistant bubble with no content and no error is always still
          // working: the transient running turn, a streaming turn before its
          // first token (a long web search can sit here for many seconds), or
          // the brief gap before rich parts merge in. Keep the live indicator
          // for all of them so the chat never shows a blank turn.
          <ThinkingIndicatorLive />
        ) : (
          renderableContent.map((part, index) => <DirectAssistantPart key={`${message.id}-${index}`} part={part} />)
        )}
        {failed ? (
          <ErrorState
            title="The response stopped"
            detail={resolveAskAIErrorDetail(errorValue)}
            retrying={false}
            onRetry={persisted ? undefined : () => void onRetry()}
          />
        ) : null}
        {complete && persisted && responseText.trim() ? (
          <div className="flex flex-col items-start gap-2">
            <div className="flex items-center gap-2 text-muted-foreground">
              {!feedbackOpen && !sent ? (
                <>
                  <button
                    type="button"
                    aria-label="Copy answer"
                    onClick={async () => {
                      await navigator.clipboard.writeText(responseText)
                      setCopied(true)
                      if (copyResetRef.current) clearTimeout(copyResetRef.current)
                      copyResetRef.current = setTimeout(() => setCopied(false), 2000)
                    }}
                    className="inline-flex size-8 items-center justify-center rounded-md hover:bg-muted hover:text-foreground"
                  >
                    {copied ? <Check className="size-4" /> : <Copy className="size-4" />}
                  </button>
                  <button
                    type="button"
                    aria-label="Mark answer as helpful"
                    disabled={helpful || !threadId}
                    onClick={async () => {
                      if (!threadId) return
                      await submitFeedback({ threadId, messageId: message.id, categories: ["Helpful"] })
                      setHelpful(true)
                    }}
                    className="inline-flex size-8 items-center justify-center rounded-md hover:bg-muted hover:text-foreground disabled:opacity-50"
                  >
                    <ThumbsUp className="size-4" />
                  </button>
                  <button
                    type="button"
                    aria-label="Report a problem with this answer"
                    onClick={() => setFeedbackOpen(true)}
                    className="inline-flex size-8 items-center justify-center rounded-md hover:bg-muted hover:text-foreground"
                  >
                    <ThumbsDown className="size-4" />
                  </button>
                </>
              ) : null}
              <DirectMessageTimestamp createdAt={message.createdAt} align="inline" />
            </div>
            {feedbackOpen || sent ? (
              <FeedbackDialog
                reasons={FEEDBACK_REASONS}
                selected={selected}
                note={note}
                sent={sent}
                onToggleReason={(reason) =>
                  setSelected((current) =>
                    current.includes(reason) ? current.filter((item) => item !== reason) : [...current, reason],
                  )
                }
                onNoteChange={setNote}
                onSubmit={async () => {
                  if (!threadId) return
                  await submitFeedback({ threadId, messageId: message.id, categories: selected, note })
                  setSent(true)
                }}
              />
            ) : null}
          </div>
        ) : null}
      </div>
    </div>
  )
}

// Warm, in-voice quota nudge above the composer: a gentle heads-up as chats run
// low, and — once they're used up — an offer to hand off to the Avana team.
export function QuotaNudge({ remaining }: { remaining: number }) {
  if (remaining > 4) return null
  if (remaining > 0) {
    return (
      <div className="mx-auto w-full max-w-[var(--thread-max-width)] rounded-2xl border border-border/60 bg-muted/40 px-4 py-2.5 text-center text-sm text-foreground">
        {`Just a heads up, you have ${remaining} ${remaining === 1 ? "chat" : "chats"} left today. Let’s make them count.`}
      </div>
    )
  }
  return (
    <div className="mx-auto flex w-full max-w-[var(--thread-max-width)] flex-col items-center gap-2.5 rounded-2xl border border-border/60 bg-muted/40 px-4 py-3 text-center text-sm text-foreground">
      <span>That&apos;s all your chats for today. The Avana team can keep helping in the Support Center.</span>
      <Link
        href="/support-center"
        className="inline-flex items-center rounded-full bg-foreground px-4 py-1.5 text-[14px] font-normal leading-5 text-background transition hover:opacity-90"
      >
        Open Support Center
      </Link>
    </div>
  )
}

function Composer({
  usage,
  disabled = false,
  running,
  value,
  onChange,
  onSend,
  onCancel,
}: {
  usage?: AskAIUsage
  disabled?: boolean
  running: boolean
  value: string
  onChange: (value: string) => void
  onSend: (prompt: string) => void | Promise<void>
  onCancel: () => void | Promise<void>
}) {
  const textareaRef = useRef<HTMLTextAreaElement>(null)
  const submit = () => {
    const prompt = value.trim()
    if (!prompt || disabled || running) return
    onChange("")
    void onSend(prompt)
  }
  const focusComposer = (event: ReactMouseEvent<HTMLElement>) => {
    const target = event.target as HTMLElement
    // Keep send/stop/context controls clickable; everything else focuses typing.
    if (target.closest("button, a, textarea, input, [role='button']")) return
    if (disabled) return
    textareaRef.current?.focus()
  }
  return (
    <form
      className="relative flex w-full flex-col"
      aria-disabled={disabled}
      onSubmit={(event) => {
        event.preventDefault()
        submit()
      }}
    >
      <ElementComposer className="max-w-none">
        <ComposerBar className="relative cursor-text bg-card focus-within:border-border" onClick={focusComposer}>
          <textarea
            ref={textareaRef}
            value={value}
            onChange={(event) => onChange(event.currentTarget.value)}
            onKeyDown={(event) => {
              if (event.key === "Enter" && !event.shiftKey) {
                event.preventDefault()
                submit()
              }
            }}
            aria-label="Ask Avana a question"
            placeholder={
              disabled ? "Your chats reset tomorrow" : "Ask Avana about markets, your positions, or how it works…"
            }
            maxLength={ASK_AI_CONFIG.maxInputCharacters}
            rows={1}
            disabled={disabled}
            enterKeyHint="send"
            // Textarea fills the card; bottom padding clears the overlaid toolbar so
            // nearly the whole composer is a real typing hit-target (not just one row).
            className="max-h-48 min-h-[5.25rem] w-full resize-none bg-transparent px-2.5 pb-11 pt-1 text-base leading-6 outline-none placeholder:text-muted-foreground/60"
          />
          <ComposerToolbar className="pointer-events-none absolute inset-x-2.5 bottom-2.5">
            <ComposerActions className="pointer-events-auto">
              {usage ? (
                <ComposerContext
                  usage={{
                    input: usage.inputTokens,
                    output: usage.outputTokens,
                    total: ASK_AI_CONFIG.contextWindowTokens,
                  }}
                />
              ) : null}
            </ComposerActions>
            <ComposerActions className="pointer-events-auto">
              {running ? (
                <button
                  type="button"
                  aria-label="Stop generating"
                  onClick={() => void onCancel()}
                  className="inline-flex size-9 items-center justify-center rounded-full bg-foreground text-background transition hover:bg-foreground/90"
                >
                  <Square className="size-3.5 fill-current" />
                </button>
              ) : (
                <button
                  type="submit"
                  aria-label="Send message"
                  disabled={disabled || !value.trim()}
                  className="inline-flex size-9 items-center justify-center rounded-full bg-foreground text-background transition hover:opacity-90 disabled:cursor-not-allowed disabled:bg-foreground/15 disabled:text-foreground/40"
                >
                  <ArrowUp className="size-[18px]" />
                </button>
              )}
            </ComposerActions>
          </ComposerToolbar>
        </ComposerBar>
      </ElementComposer>
    </form>
  )
}

export function AskAIThread({
  threadsOpen,
  onToggleThreads,
  threadId,
  usage,
  messagesRemaining = null,
  canLoadMoreMessages,
  onLoadMoreMessages,
  queue,
  runningPrompt,
  messages,
  onRetry,
  onSend,
  onCancelRunning,
  onCancelQueued,
  loading = false,
  displayName = null,
}: {
  threadsOpen: boolean
  onToggleThreads: () => void
  threadId: string | null
  usage?: AskAIUsage
  messagesRemaining?: number | null
  canLoadMoreMessages: boolean
  onLoadMoreMessages: () => void
  queue: readonly { id: string; prompt: string }[]
  runningPrompt?: string
  messages: readonly ThreadMessage[]
  onRetry: () => void | Promise<void>
  onSend: (prompt: string) => void | Promise<void>
  onCancelRunning: () => void | Promise<void>
  onCancelQueued: (turnId: string) => void | Promise<void>
  loading?: boolean
  /** Onboarding `preferences.name` when signed in; guests pass null. */
  displayName?: string | null
}) {
  const isEmpty = messages.length === 0
  const [draft, setDraft] = useState("")
  const [hoveredPrompt, setHoveredPrompt] = useState<string | null>(null)
  const composerValue = hoveredPrompt ?? draft
  // Freeze the clock on mount; recompute only when the display name arrives from Convex.
  const [greetingNow] = useState(() => new Date())
  const greeting = useMemo(() => formatAskAIGreeting(displayName, greetingNow), [displayName, greetingNow])
  const scrollSignature = (() => {
    const last = messages.at(-1)
    const content = last?.content
      .map((part) => (part.type === "text" ? `${part.type}:${part.text.length}` : part.type))
      .join(",")
    const status = last && "status" in last ? last.status?.type : ""
    return `${messages.length}:${last?.id ?? ""}:${status ?? ""}:${content ?? ""}`
  })()
  const viewportRef = useRef<HTMLDivElement>(null)
  const stickToBottomRef = useRef(true)
  const [showScrollToLatest, setShowScrollToLatest] = useState(false)

  const scrollToLatest = useCallback((smooth = false) => {
    const viewport = viewportRef.current
    if (!viewport) return
    if (smooth && typeof viewport.scrollTo === "function")
      viewport.scrollTo({ top: viewport.scrollHeight, behavior: "smooth" })
    else viewport.scrollTop = viewport.scrollHeight
    stickToBottomRef.current = true
    setShowScrollToLatest(false)
  }, [])

  useLayoutEffect(() => {
    if (!stickToBottomRef.current) return
    const frame = requestAnimationFrame(() => scrollToLatest(false))
    return () => cancelAnimationFrame(frame)
  }, [scrollSignature, runningPrompt, queue.length, scrollToLatest])

  return (
    <section className="relative flex min-w-0 flex-1 flex-col overflow-hidden bg-background">
      <div className="flex h-16 shrink-0 items-center gap-3 px-5 sm:px-8">
        <button
          type="button"
          aria-label={threadsOpen ? "Hide sidebar" : "Open sidebar"}
          title={threadsOpen ? "Hide sidebar" : "Open sidebar"}
          onClick={onToggleThreads}
          className="inline-flex size-8 items-center justify-center rounded-md text-muted-foreground transition-colors hover:bg-muted hover:text-foreground"
        >
          <span aria-hidden className="relative block h-4 w-[18px] rounded-[3px] border border-current">
            <span className="absolute bottom-0 left-[5px] top-0 border-l border-current" />
          </span>
        </button>
      </div>

      <ThreadPrimitive.Root className="flex min-h-0 flex-1 flex-col [--thread-max-width:44rem]">
        <div
          ref={viewportRef}
          onScroll={(event) => {
            const viewport = event.currentTarget
            const atBottom = viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight < 80
            stickToBottomRef.current = atBottom
            setShowScrollToLatest(!atBottom)
          }}
          className="relative flex flex-1 flex-col overflow-x-auto overflow-y-auto"
        >
          <div
            className={`mx-auto flex w-full max-w-[44rem] flex-1 flex-col px-4 pt-4 ${
              isEmpty && !loading ? "justify-center" : ""
            }`}
          >
            {loading && isEmpty ? (
              <AskAIThreadSkeleton />
            ) : (
              <>
                {isEmpty ? (
                  <div className="mb-6 flex flex-col items-center px-4 text-center">
                    <h1 className="text-[24px] font-normal leading-[30px] tracking-[-0.02em]">{greeting}</h1>
                  </div>
                ) : null}

                <div className="mb-14 flex flex-col gap-y-6 empty:hidden">
                  {canLoadMoreMessages ? (
                    <button
                      type="button"
                      onClick={onLoadMoreMessages}
                      className="mx-auto rounded-md px-3 py-1.5 text-sm text-muted-foreground hover:bg-muted hover:text-foreground"
                    >
                      Load earlier messages
                    </button>
                  ) : null}
                  {messages.map((message) =>
                    message.role === "user" ? (
                      <DirectUserMessage key={message.id} message={message} />
                    ) : message.role === "assistant" ? (
                      <DirectAssistantMessage
                        key={message.id}
                        message={message}
                        threadId={threadId}
                        onRetry={onRetry}
                      />
                    ) : null,
                  )}
                </div>
              </>
            )}

            <div
              className={`flex flex-col gap-4 overflow-visible bg-background pb-4 md:pb-6 ${
                isEmpty ? "" : "sticky bottom-0 mt-auto rounded-t-3xl"
              }`}
            >
              {showScrollToLatest ? (
                <button
                  type="button"
                  aria-label="Scroll to latest"
                  onClick={() => scrollToLatest(true)}
                  className="absolute -top-12 left-1/2 z-10 inline-flex size-9 -translate-x-1/2 items-center justify-center rounded-full border border-border bg-card text-muted-foreground shadow-md transition hover:text-foreground"
                >
                  <ChevronDown className="size-4" />
                </button>
              ) : null}
              {runningPrompt && queue.length ? (
                <MessageQueue
                  running={runningPrompt}
                  queued={queue.map((turn) => ({ id: turn.id, text: turn.prompt }))}
                  onCancel={(turnId) => void onCancelQueued(turnId)}
                  className="mx-auto max-w-full"
                />
              ) : null}
              {messagesRemaining !== null ? <QuotaNudge remaining={messagesRemaining} /> : null}
              <Composer
                usage={usage}
                disabled={messagesRemaining === 0}
                running={Boolean(runningPrompt)}
                value={composerValue}
                onChange={(next) => {
                  setHoveredPrompt(null)
                  setDraft(next)
                }}
                onSend={onSend}
                onCancel={onCancelRunning}
              />
              {isEmpty && messagesRemaining !== 0 ? (
                <div
                  className="flex w-full flex-wrap items-center justify-center gap-2 px-4"
                  onMouseLeave={() => setHoveredPrompt(null)}
                  onBlur={(event) => {
                    if (!event.currentTarget.contains(event.relatedTarget as Node | null)) {
                      setHoveredPrompt(null)
                    }
                  }}
                >
                  {ASK_AI_SUGGESTIONS.map(({ icon: Icon, label, prompt }) => (
                    <ThreadPrimitive.Suggestion
                      key={label}
                      prompt={prompt}
                      send
                      title={prompt}
                      aria-label={`${label}: ${prompt}`}
                      onMouseEnter={() => setHoveredPrompt(prompt)}
                      onFocus={() => setHoveredPrompt(prompt)}
                      onClick={() => {
                        setHoveredPrompt(null)
                        setDraft("")
                      }}
                      className="flex h-auto items-center gap-1.5 whitespace-nowrap rounded-full border border-border/60 px-3.5 py-1.5 text-[14px] font-normal leading-5 text-foreground transition-colors hover:bg-muted"
                    >
                      <Icon className="size-4" aria-hidden />
                      {label}
                    </ThreadPrimitive.Suggestion>
                  ))}
                </div>
              ) : null}
            </div>
          </div>
        </div>
      </ThreadPrimitive.Root>
    </section>
  )
}
