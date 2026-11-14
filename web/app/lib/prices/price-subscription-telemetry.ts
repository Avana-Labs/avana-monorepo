export type PriceSubscriptionSnapshot = {
  instanceId: number
  activeInstances: number
  route: string
  queries: ["prices.getPriceSnapshot", "prices.getPriceStatus"]
  event: "mount" | "unmount"
}

let nextInstanceId = 1
const activeInstances = new Set<number>()

export function registerPriceSubscription(route: string): () => void {
  const instanceId = nextInstanceId++
  activeInstances.add(instanceId)
  emitPriceSubscriptionEvent({
    instanceId,
    activeInstances: activeInstances.size,
    route,
    queries: ["prices.getPriceSnapshot", "prices.getPriceStatus"],
    event: "mount",
  })

  return () => {
    if (!activeInstances.delete(instanceId)) return
    emitPriceSubscriptionEvent({
      instanceId,
      activeInstances: activeInstances.size,
      route,
      queries: ["prices.getPriceSnapshot", "prices.getPriceStatus"],
      event: "unmount",
    })
  }
}

export function getActivePriceSubscriptionCount() {
  return activeInstances.size
}

function emitPriceSubscriptionEvent(detail: PriceSubscriptionSnapshot) {
  if (typeof window === "undefined") return
  window.dispatchEvent(new CustomEvent("avana:price-subscription", { detail }))
  if (process.env.NODE_ENV !== "production") {
    // eslint-disable-next-line no-console
    console.debug("[prices] Convex price subscription", detail)
  }
}
