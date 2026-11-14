function isSameLocalDay(left: Date, right: Date) {
  return (
    left.getFullYear() === right.getFullYear() &&
    left.getMonth() === right.getMonth() &&
    left.getDate() === right.getDate()
  )
}

export function formatAskAIMessageTimestamp(createdAt: Date, now = new Date()) {
  const time = createdAt.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })
  if (isSameLocalDay(createdAt, now)) return time

  const yesterday = new Date(now)
  yesterday.setDate(now.getDate() - 1)
  if (isSameLocalDay(createdAt, yesterday)) return `Yesterday, ${time}`

  const date = createdAt.toLocaleDateString([], {
    month: "short",
    day: "numeric",
    ...(createdAt.getFullYear() === now.getFullYear() ? {} : { year: "numeric" as const }),
  })
  return `${date}, ${time}`
}
