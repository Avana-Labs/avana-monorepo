import { redirect } from "next/navigation"

type PageProps = {
  params: Promise<{ poolId: string }>
}

/** Older pool links: redirect to the market detail page. */
export default async function PoolDetailRedirectPage({ params }: PageProps) {
  const { poolId } = await params
  redirect(`/borrow/markets/${encodeURIComponent(poolId)}`)
}
