import type { Metadata } from "next"
import Link from "next/link"

// The 404 route otherwise inherits the generic root title. A route-specific title
// (rendered as "Page not found | Avana" via the root title template) makes the tab
// and any shared/bookmarked 404 legible. Metadata can only be exported from a Server
// Component, so this route renders its (English source) copy directly rather than
// through the client-only useTranslation hook.
export const metadata: Metadata = {
  title: "Page not found",
}

export default function NotFound() {
  return (
    <main className="flex min-h-[calc(100vh-5rem)] items-center bg-background px-6 py-16 text-foreground sm:px-8 sm:py-20">
      <section className="mx-auto w-full max-w-[760px]">
        <div className="py-14 text-center sm:py-18">
          <p className="mt-5 text-[4.5rem] font-semibold leading-none tracking-[-0.06em] text-brand-readable sm:text-[5.75rem]">
            404
          </p>

          <h1 className="mx-auto mt-6 max-w-[620px] text-[1.05rem] font-semibold leading-7 tracking-[-0.02em] text-foreground">
            This page isn&apos;t available.
          </h1>

          <p className="mx-auto mt-5 max-w-[440px] text-[1rem] leading-7 text-muted-foreground sm:text-[1.05rem]">
            The address may be wrong or the page may have moved.
          </p>

          <div className="mt-8 flex flex-wrap items-center justify-center gap-4">
            <Link
              href="/"
              className="inline-flex h-11 items-center justify-center rounded-full bg-[hsl(var(--brand))] px-5 text-sm font-medium text-white transition hover:bg-[hsl(var(--brand))]/90"
            >
              Home
            </Link>

            <nav aria-label="Helpful links" className="flex flex-wrap justify-center gap-x-5 gap-y-3">
              <Link href="/borrow" className="text-sm font-medium text-foreground transition hover:text-brand-readable">
                Borrow
              </Link>
              <Link href="/lend" className="text-sm font-medium text-foreground transition hover:text-brand-readable">
                Lend
              </Link>
              <Link
                href="/multiply"
                className="text-sm font-medium text-foreground transition hover:text-brand-readable"
              >
                Multiply
              </Link>
              <Link
                href="/dashboard"
                className="text-sm font-medium text-foreground transition hover:text-brand-readable"
              >
                Dashboard
              </Link>
            </nav>
          </div>
        </div>
      </section>
    </main>
  )
}
