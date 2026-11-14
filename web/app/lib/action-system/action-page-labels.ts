export function getProcessingTitle(verb: string, symbol: string) {
  const labels: Record<string, string> = {
    Borrow: "Borrowing",
    Deposit: "Depositing",
    Withdraw: "Withdrawing",
    Repay: "Repaying",
    Remove: "Removing",
    Claim: "Claiming",
    Multiply: "Multiplying",
    Deleverage: "Deleveraging",
    Swap: "Swapping",
    Pledge: "Pledging",
  }
  const label = labels[verb] ?? `${verb}ing`
  return `${label} ${symbol}`
}
