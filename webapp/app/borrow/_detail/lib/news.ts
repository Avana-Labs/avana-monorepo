import type { AboutCard } from "@/app/lib/borrow-detail"

type NewsCardItem = {
  title: string
  description?: string
  source: string
  time: string
  imageUrl?: string
  imageLabel?: string
}

export function buildNewsItems(about: AboutCard, _imageUrl?: string, imageLabel?: string): NewsCardItem[] {
  const deployedOn = about.stats.find((stat) => stat.label === "Deployed On")?.value
  const deploymentItem = deployedOn
    ? [
        {
          title: "Deployed",
          description: "Market contracts deployed.",
          source: "Deployment",
          time: deployedOn,
        },
      ]
    : []
  const items = [
    ...deploymentItem,
    ...(about.news ??
      about.history.slice(0, 3).map((entry, index) => ({
        title: entry.title,
        description: entry.description,
        source: entry.title === "Deployed" ? "Deployment" : index === 0 ? "Latest update" : "Protocol note",
        time: entry.date,
      }))),
  ]

  return items.map((item) => ({
    ...item,
    // No picsum placeholders — omit images until real editorial assets exist.
    imageUrl: undefined,
    imageLabel,
  }))
}
