// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveV3FlashSource} from "../../../src/flash/AaveV3FlashSource.sol";
import {IFlashSource} from "../../../src/flash/IFlashSource.sol";
import {MockAaveV3ACLManager, MockAaveV3AddressesProvider, MockAaveV3Pool} from "../../utils/mocks/AaveV3PoolMocks.sol";
import {MockFlashFeeCap, MockFlashReceiver} from "../../utils/mocks/MockFlashReceiver.sol";
import {PayoutToken} from "../../utils/mocks/PayoutToken.sol";

/// @title AaveV3FlashSourceProperties
/// @notice Echidna and Medusa properties of the flash source (2.11 Flash source). Between transactions: the immutables
/// are fixed, the source holds no allowance and no balance beyond what is left of donations (never forwarded, counted
/// toward repayments), and the Pool's reserve holds its idle liquidity plus every premium paid. Inside one transaction:
/// a loan completes exactly when it is within the idle liquidity and the exact cap on the source's ceiling quote, and
/// returns the half-up premium the Pool charged; an outsider's loan, a direct
/// callback and every hostile receiver behaviour revert with the error of the first failing check.
/// @dev `property_` functions run in property mode; `loan`, `outsiderLoan`, `directCallback`, `hostileReceiver`,
/// `grantFlashBorrower` and `donate` run in assertion mode, each selecting among concrete cases with `if` branches.
/// `maxFlashFeeBps` comes from `MockFlashFeeCap`, bounded to the ParameterStore range [0, 100].
contract AaveV3FlashSourceProperties {
    uint256 internal constant IDLE = 18_000_000e6;
    address internal constant HUB = address(0x4B);

    MockAaveV3ACLManager internal immutable ACL;
    MockAaveV3Pool internal immutable POOL;
    MockFlashFeeCap internal immutable CAP;
    PayoutToken internal immutable TOKEN;
    address internal immutable A_TOKEN;
    MockFlashReceiver internal immutable SWAP;
    AaveV3FlashSource internal immutable SOURCE;

    uint256 internal premiumsPaid;
    uint256 internal pendingDonation;

    /// @notice Number of assertion sequences run; written so each call is a transaction.
    uint256 public sequences;

    constructor() {
        ACL = new MockAaveV3ACLManager();
        MockAaveV3AddressesProvider provider = new MockAaveV3AddressesProvider(address(ACL));
        POOL = new MockAaveV3Pool(address(provider), 5);
        CAP = new MockFlashFeeCap(10);
        TOKEN = new PayoutToken("USDC", 6);
        A_TOKEN = POOL.listReserve(address(TOKEN));
        TOKEN.mint(A_TOKEN, IDLE);
        POOL.recordSupply(address(TOKEN), IDLE);
        SWAP = new MockFlashReceiver();
        SOURCE = new AaveV3FlashSource(address(POOL), address(SWAP), address(CAP));
        SWAP.setSource(address(SOURCE));
        TOKEN.mint(address(SWAP), type(uint128).max);
    }

    function _is(
        bytes memory reason,
        bytes memory expected
    ) internal pure returns (bool) {
        return keccak256(reason) == keccak256(expected);
    }

    // ─── Properties (between transactions) ───

    function property_immutablesFixed() external view returns (bool) {
        return SOURCE.LENDER() == address(POOL) && SOURCE.LP_VAULT_SWAP() == address(SWAP)
            && SOURCE.PARAMETER_STORE() == address(CAP);
    }

    function property_noAllowanceAndOnlyPendingDonation() external view returns (bool) {
        return
            TOKEN.allowance(address(SOURCE), address(POOL)) == 0 && TOKEN.balanceOf(address(SOURCE)) == pendingDonation;
    }

    function property_reserveKeepsIdlePlusPremiums() external view returns (bool) {
        return TOKEN.balanceOf(A_TOKEN) == IDLE + premiumsPaid;
    }

    // ─── Assertion entry points (inside one transaction) ───

    /// @notice A loan by LPVaultSwap completes exactly when `amount ≤ idle` and `⌈amount × rate / 10⁴⌉ × 10⁴ ≤ cap ×
    /// amount`; a refusal names the first failing check.
    function loan(
        uint64 amount,
        uint8 rate,
        uint8 cap
    ) external {
        uint256 r = rate % 101;
        uint256 c = cap % 101;
        POOL.setPremiumTotal(uint128(r));
        CAP.setMaxFlashFeeBps(uint16(c));
        bool borrower = ACL.isFlashBorrower(address(SOURCE));
        uint256 phi = borrower ? 0 : (uint256(amount) * r + 9999) / 10_000;
        uint256 charged = borrower ? 0 : (uint256(amount) * r + 5000) / 10_000;
        // Premiums paid stay in the reserve and are lendable.
        uint256 idle = IDLE + premiumsPaid;
        try SWAP.borrow(address(TOKEN), amount, HUB, "") returns (uint256 premium) {
            assert(amount > 0 && amount <= idle && phi * 10_000 <= c * amount && premium == charged);
            assert(SWAP.lastReceived() == amount);
            premiumsPaid += premium;
            uint256 owed = uint256(amount) + premium;
            pendingDonation = pendingDonation > owed ? pendingDonation - owed : 0;
        } catch (bytes memory reason) {
            if (amount == 0) {
                // LPVaultSwap refuses an empty receipt (REQ-SWAP-013); it never requests F = 0.
                assert(_is(reason, abi.encodeWithSelector(MockFlashReceiver.InvalidFlashCallback.selector)));
            } else if (amount > idle) {
                assert(_is(reason, abi.encodeWithSelector(IFlashSource.InsufficientFlashLiquidity.selector, idle)));
            } else {
                assert(phi * 10_000 > c * amount);
                assert(
                    _is(reason, abi.encodeWithSelector(IFlashSource.FlashFeeTooHigh.selector, phi, c * amount / 10_000))
                );
            }
        }
        ++sequences;
    }

    /// @notice Any caller other than LPVaultSwap gets `NotLPVaultSwap`, even naming the Pool as the Hub.
    function outsiderLoan(
        uint64 amount,
        bool hubIsPool
    ) external {
        address hub = hubIsPool ? address(POOL) : HUB;
        try SOURCE.flashLoan(address(TOKEN), amount, hub, "") {
            assert(false);
        } catch (bytes memory reason) {
            assert(_is(reason, abi.encodeWithSelector(IFlashSource.NotLPVaultSwap.selector)));
        }
        ++sequences;
    }

    /// @notice A callback outside a loan is refused whoever names itself initiator.
    function directCallback(
        uint64 amount,
        uint64 premium,
        bool initiatorIsSource
    ) external {
        address[] memory assets = new address[](1);
        assets[0] = address(TOKEN);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = premium;
        address initiator = initiatorIsSource ? address(SOURCE) : address(this);
        try SOURCE.executeOperation(assets, amounts, premiums, initiator, "") {
            assert(false);
        } catch (bytes memory reason) {
            assert(_is(reason, abi.encodeWithSelector(IFlashSource.InvalidFlashCallback.selector)));
        }
        ++sequences;
    }

    /// @notice A receiver that repays short, not at all, returns a wrong magic value or re-enters is refused, and the
    /// state is unchanged.
    function hostileReceiver(
        uint8 which
    ) external {
        uint256 w = which % 5;
        POOL.setPremiumTotal(5);
        CAP.setMaxFlashFeeBps(10);
        uint256 premium = ACL.isFlashBorrower(address(SOURCE)) ? 0 : 500_000;
        uint256 owed = 1000e6 + premium;
        // A donation counts toward the repayment; one that alone covers it makes a short repayer succeed.
        if (w < 2 && pendingDonation + 1 >= owed) return;
        bytes memory expected;
        if (w == 0) {
            SWAP.setMode(MockFlashReceiver.Mode.RepayShort);
            expected = abi.encodeWithSelector(IFlashSource.FlashRepayShort.selector, owed - 1, owed);
        } else if (w == 1) {
            SWAP.setMode(MockFlashReceiver.Mode.NoRepay);
            expected = abi.encodeWithSelector(IFlashSource.FlashRepayShort.selector, pendingDonation, owed);
        } else if (w == 2) {
            SWAP.setMode(MockFlashReceiver.Mode.WrongMagic);
            expected = abi.encodeWithSelector(IFlashSource.InvalidFlashCallback.selector);
        } else if (w == 3) {
            SWAP.setMode(MockFlashReceiver.Mode.ReenterLoan);
            expected = abi.encodeWithSelector(IFlashSource.FlashLoanActive.selector);
        } else {
            SWAP.setMode(MockFlashReceiver.Mode.ReenterCallback);
            expected = abi.encodeWithSelector(IFlashSource.InvalidFlashCallback.selector);
        }
        uint256 reserveBefore = TOKEN.balanceOf(A_TOKEN);
        try SWAP.borrow(address(TOKEN), 1000e6, HUB, "") {
            assert(false);
        } catch (bytes memory reason) {
            // A pending donation is forwarded with the loan, so the short repay still ends one unit short.
            assert(_is(reason, expected));
        }
        SWAP.setMode(MockFlashReceiver.Mode.Repay);
        assert(TOKEN.balanceOf(A_TOKEN) == reserveBefore);
        ++sequences;
    }

    /// @notice The `FLASH_BORROWER` grant makes the premium 0 for every amount.
    function grantFlashBorrower(
        uint64 amount
    ) external {
        ACL.addFlashBorrower(address(SOURCE));
        assert(SOURCE.flashPremium(address(TOKEN), amount) == 0);
        ++sequences;
    }

    /// @notice A donation to the source is never forwarded; it stays until a repayment counts it.
    function donate(
        uint32 units
    ) external {
        TOKEN.mint(address(SOURCE), units);
        pendingDonation += units;
        ++sequences;
    }
}
