import { redirect } from "next/navigation"
import type { Metadata } from "next"
import { getPoolDetail } from "@/app/lib/borrow-detail"

type PageProps = {
  params: Promise<{ poolId: string }>
}

export async function generateMetadata({ params }: PageProps): Promise<Metadata> {
  const { poolId } = await params
  const detail = getPoolDetail(poolId)
  if (!detail) return { title: "Pool · Avana" }
  return {
    title: `${detail.hero.name} · Avana Borrow`,
    description: detail.about.description,
  }
}

export default async function PoolDetailPage({ params }: PageProps) {
  const { poolId } = await params
  redirect(`/borrow/markets/${poolId}`)
}
