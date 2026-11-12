# Flash source lifecycle

The chain's IFlashSource lends LPVaultSwap the debt asset itself for a repay with collateral (`deleverage`), from a lender that is never an Avana Hub (the chain's Aave V3 Pool at launch), checks the premium against `maxFlashFeeBps`, and repays the lender in the same call; LPVaultSwap receives the loan through IFlashReceiver. A liquidation never uses it: `liquidate` is funded by its caller, and a caller without the debt asset borrows through the [flash liquidation helper](../periphery/flash-liquidator/LIFECYCLE.md) (Q-404).

## Walkthrough

Repay with collateral on Ethereum (V, USDC debt, the repay-with-collateral flow of [LIFECYCLES.md](../../LIFECYCLES.md)). Setup: Avana does not yet hold `FLASH_BORROWER` on the Ethereum Aave V3 Pool, so the premium is 5 bps; `maxFlashFeeBps = 10`, strictly above the rate as `SPEC-LIQ-015` requires (with the cap equal to the rate most loan sizes would fail the exact check).

1. **AvanaTimelock → MarketRegistry [`setFlashSource`](../policy/market-registry/IMarketRegistryHubs.sol#L247)`(FS)`** (normal delay). The registry refuses a source whose [`LENDER`](AaveV3FlashSource.sol#L73) is a recorded Hub.
2. **Lens [`previewRepayWithCollateral`](../lens/lens/ILensPreview.sol#L91)** sizes the repayment `x = 2,968.505747` USDC for V's 1,500 vault tokens after a premium of at most `maxFlashFeeBps`; FS quotes [`maxFlashLoan`](AaveV3FlashSource.sol#L183)`(USDC) ≥ x` and [`flashPremium`](AaveV3FlashSource.sol#L197)`(USDC, x) = 1,484,253`.
3. **LPVaultSwap → [`flashLoan`](AaveV3FlashSource.sol#L99)`(USDC, x, HD, context)`** inside `deleverage`, with the Lock held by the AaveAdapter. Checks: caller is LPVaultSwap, no loan open ([`FlashLoanActive`](IFlashSource.sol#L33)), `LENDER() != HD` (the Spoke's Hub), `x ≤ maxFlashLoan`, and `1,484,253 × 10^4 = 14,842,530,000 ≤ 10 × 2,968,505,747`. Errors: [`NotLPVaultSwap`](IFlashSource.sol#L29), [`FlashSourceIsHub`](IFlashSource.sol#L51), [`InsufficientFlashLiquidity`](IFlashSource.sol#L42), [`FlashFeeTooHigh`](IFlashSource.sol#L48).
4. **Aave V3 Pool → FS [`executeOperation`](AaveV3FlashSource.sol#L142).** FS checks the lender, initiator, single asset and active context ([`InvalidFlashCallback`](IFlashSource.sol#L55)), re-checks the charged premium against `maxFlashFeeBps` and forwards the USDC the Pool delivered (the rise of its balance over the snapshot taken before the loan; a donation sitting in FS is never forwarded).
5. **FS → LPVaultSwap [`onFlashLoan`](IFlashReceiver.sol#L26)`(USDC, x, premium, context)`.** LPVaultSwap checks the caller is `MarketRegistry.flashSource()`, the Lock holder is the AaveAdapter and the deleverage context is its own, repays V's debt, unwinds and swaps the units (recovery 2,999.40 USDC) and transfers `x + premium` back to FS by balance delta.
6. **FS approves the Pool for exactly the amount owed and the Pool pulls it.** FS keeps no allowance; it holds nothing between calls unless someone donated to it, and a donation only lowers the next repayment. V receives 29.41 USDC. Event: [`FlashLoanServed`](IFlashSource.sol#L67); LPVaultSwap emits [`FlashLoanUsed`](../liquidation/lp-vault-swap/ILPVaultSwapEvents.sol#L46) and `Deleveraged`. Error: [`FlashRepayShort`](IFlashSource.sol#L61).
7. **Liquidations do not reach FS:** Bob's liquidation of 3.5 `LIQ-069` is funded by its caller or through the helper, which calls the same Aave V3 Pool directly with its own `FLASH_BORROWER` grant.
8. **Once Avana's source holds `FLASH_BORROWER`**, the premium is 0; once the helper holds it too, governance may run ParameterStore [`tightenMaxFlashFeeBps`](../policy/parameter-store/IParameterStoreAdmin.sol#L112)`(0)` at the short delay. **If the Pool's USDC reserve is paused**, `maxFlashLoan` returns 0 and `deleverage` reverts `FlashLiquidityShort`; the borrower repays from its own funds (3.6 `EMG-109`, P-15).

## What the UI reads and calls

- Lens: [`previewRepayWithCollateral`](../lens/lens/ILensPreview.sol#L91).
- Events to index: [`FlashLoanServed`](IFlashSource.sol#L67); LPVaultSwap `FlashLoanUsed`.
- User calls: none; only LPVaultSwap borrows, inside `deleverage`.

## Spec

- [2.11 LPVaultSwap](../../../spec/02-contracts/11-lpvaultswap.md): `REQ-FLASH-001`–`REQ-FLASH-010`, `REQ-SWAP-012`, `REQ-SWAP-013`, `REQ-SWAP-106`, `REQ-SWAP-122`, `INV-095`.
- Flows: [3.5](../../../spec/03-operations/05-liquidation.md) `LIQ-081`; [3.3 Repay](../../../spec/03-operations/03-repay.md); [3.6](../../../spec/03-operations/06-emergency-operations.md) `EMG-098` (P-15), `EMG-109`.
