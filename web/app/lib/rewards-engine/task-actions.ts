import type { RewardTask, RewardTaskActionKind, UserRewardProgress } from "./types"
import { buildDefaultRewardsCatalog, REWARD_SANDBOX_TOURS, REWARD_TASK_DEEP_LINKS } from "./catalog"

export function getTaskDeepLink(taskId: string) {
  return REWARD_TASK_DEEP_LINKS[taskId]
}

export function getSandboxTour(taskId: string) {
  return REWARD_SANDBOX_TOURS[taskId]
}

export function getTaskActionKind(task: RewardTask): RewardTaskActionKind {
  return task.actionKind ?? "product_action"
}

export function canRunTaskAction(progress: UserRewardProgress, actionKind: RewardTaskActionKind) {
  if (progress.status === "claimed" || progress.status === "expired") return false
  if (actionKind === "auto" || actionKind === "wait_timer") return false
  return progress.status === "available" || progress.status === "in_progress" || progress.status === "claimable"
}

export function isReferralTaskAction(actionKind: RewardTaskActionKind) {
  return (
    actionKind === "copy_referral" ||
    actionKind === "sandbox_referral_invite" ||
    actionKind === "sandbox_referral_activate" ||
    actionKind === "sandbox_referral_fund"
  )
}

export function findTaskById(taskId: string, now = Date.now()) {
  return buildDefaultRewardsCatalog(now).find((task) => task.id === taskId)
}
