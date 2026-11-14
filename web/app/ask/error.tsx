"use client"

export default function AskAIError({ error, reset }: { error: Error & { digest?: string }; reset: () => void }) {
  return (
    <main className="flex min-h-[calc(100dvh-56px)] items-center justify-center px-6 py-12">
      <div className="max-w-md rounded-2xl border border-border bg-card p-8 text-center">
        <h1 className="text-xl font-medium tracking-[-0.02em]">Ask AI couldn&apos;t load</h1>
        <p className="mt-3 text-sm leading-6 text-muted-foreground">Your Avana positions were not changed.</p>
        {process.env.NODE_ENV === "development" ? (
          <pre className="mt-3 whitespace-pre-wrap text-left text-xs text-destructive">
            {error.stack ?? error.message}
          </pre>
        ) : null}
        <button
          type="button"
          onClick={reset}
          className="mt-6 rounded-full bg-brand px-5 py-2.5 text-sm font-medium text-brand-foreground"
        >
          Try again
        </button>
      </div>
    </main>
  )
}
