// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveV3FlashSource} from "../../src/flash/AaveV3FlashSource.sol";
import {IFlashSource} from "../../src/flash/IFlashSource.sol";
import {MockAaveV3ACLManager, MockAaveV3AddressesProvider, MockAaveV3Pool} from "../utils/mocks/AaveV3PoolMocks.sol";
import {MockFlashFeeCap, MockFlashReceiver} from "../utils/mocks/MockFlashReceiver.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {Test} from "forge-std/Test.sol";

/// @title AaveV3FlashSourceHalmosTest
/// @notice Symbolic checks of the flash source (2.11 Flash source) for every caller, initiator, amount, Pool rate and
/// cap: only LPVaultSwap borrows; the callback runs only from the Pool, for a loan this source opened, with itself as
/// initiator; the liquidated Spoke's Hub is never the lender; a completed loan was within the idle liquidity and the
/// exact premium cap, repaid the Pool `amount + premium`, and left the source with no allowance; a donation to the
/// source is never forwarded.
/// @dev The Pool, ACLManager and PoolAddressesProvider are the mocks of the unit suite; `maxFlashFeeBps` comes from
/// `MockFlashFeeCap` (the ParameterStore proxy is too heavy for symbolic setUp). Amounts are bounded to uint64 and rates
/// and caps to the ParameterStore range [0, 100] so the premium products stay within the solver's reach.
contract AaveV3FlashSourceHalmosTest is Test {
    address internal constant HUB = address(0x4B);
    uint256 internal constant IDLE = 18_000_000e6;
    bytes internal constant CTX = hex"c0ffee";

    MockAaveV3ACLManager internal acl;
    MockAaveV3AddressesProvider internal provider;
    MockAaveV3Pool internal pool;
    MockFlashFeeCap internal capStore;
    PayoutToken internal usdc;
    address internal aUsdc;
    MockFlashReceiver internal swap;
    AaveV3FlashSource internal source;

    function setUp() public {
        acl = new MockAaveV3ACLManager();
        provider = new MockAaveV3AddressesProvider(address(acl));
        pool = new MockAaveV3Pool(address(provider), 5);
        capStore = new MockFlashFeeCap(10);
        usdc = new PayoutToken("USDC", 6);
        aUsdc = pool.listReserve(address(usdc));
        usdc.mint(aUsdc, IDLE);
        pool.recordSupply(address(usdc), IDLE);
        swap = new MockFlashReceiver();
        source = new AaveV3FlashSource(address(pool), address(swap), address(capStore));
        swap.setSource(address(source));
        usdc.mint(address(swap), 1_000_000e6);
    }

    function _is(
        bytes memory ret,
        bytes4 selector
    ) internal pure returns (bool) {
        return ret.length >= 4 && bytes4(ret) == selector;
    }

    // PROP-080 verifies: REQ-FLASH-001, REQ-FLASH-009, INV-040, INV-095
    function check_PROP_080_onlyLPVaultSwapBorrows(
        address caller,
        address asset,
        uint256 amount,
        address spokeHub
    ) public {
        vm.assume(caller != address(swap));
        vm.prank(caller);
        (bool ok, bytes memory ret) =
            address(source).call(abi.encodeCall(IFlashSource.flashLoan, (asset, amount, spokeHub, CTX)));
        assert(!ok);
        assert(_is(ret, IFlashSource.NotLPVaultSwap.selector));
    }

    // PROP-036 verifies: REQ-FLASH-003, INV-040, Q-045
    // PROP-080 verifies: REQ-FLASH-003, INV-040, INV-095
    function check_PROP_036_callbackOutsideContextRefused(
        address caller,
        address initiator,
        uint256 amount,
        uint256 premium
    ) public {
        address[] memory assets = new address[](1);
        assets[0] = address(usdc);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = premium;
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(source)
            .call(
                abi.encodeWithSignature(
                    "executeOperation(address[],uint256[],uint256[],address,bytes)",
                    assets,
                    amounts,
                    premiums,
                    initiator,
                    CTX
                )
            );
        assert(!ok);
        assert(_is(ret, IFlashSource.InvalidFlashCallback.selector));
    }

    /// @notice The Pool reporting any initiator other than the source itself is refused inside an open loan.
    // PROP-036 verifies: REQ-FLASH-003, INV-040, Q-045
    function check_PROP_036_onlyOwnInitiator(
        address initiator,
        uint64 amount
    ) public {
        vm.assume(amount >= 1000);
        pool.setInitiatorOverride(initiator);
        (bool ok,) = address(swap).call(abi.encodeCall(MockFlashReceiver.borrow, (address(usdc), amount, HUB, CTX)));
        assert(!ok || initiator == address(0) || initiator == address(source));
    }

    // PROP-080 verifies: REQ-FLASH-001, REQ-FLASH-005, INV-095, Q-386
    function check_PROP_080_neverTheLiquidatedHub(
        uint256 amount
    ) public {
        (bool ok, bytes memory ret) =
            address(swap).call(abi.encodeCall(MockFlashReceiver.borrow, (address(usdc), amount, address(pool), CTX)));
        assert(!ok);
        assert(_is(ret, IFlashSource.FlashSourceIsHub.selector));
    }

    /// @notice A completed loan, for every amount at the launch rate (5 bps) and cap (10 bps), was within the idle
    /// liquidity and left the source with no balance and no allowance.
    // PROP-080 verifies: REQ-FLASH-001, REQ-FLASH-002, REQ-FLASH-003, INV-095, Q-335
    function check_PROP_080_completedLoanLeavesSourceEmpty(
        uint64 amount
    ) public {
        (bool ok,) = address(swap).call(abi.encodeCall(MockFlashReceiver.borrow, (address(usdc), amount, HUB, CTX)));
        if (ok) {
            assert(amount <= IDLE);
            assert(usdc.balanceOf(address(source)) == 0);
            assert(usdc.allowance(address(source), address(pool)) == 0);
        }
    }

    /// @notice A completed loan paid a premium within the exact cap and repaid the Pool in full.
    /// @dev The premium is a full-width `mulDiv` in both the source and the Pool, which the solver may not close within
    /// the timeout; `testFuzz_TEST_052_capDecisionIsExact` (10,000 runs in the final pass) checks the same over rates
    /// and caps in [0, 100].
    // PROP-080 verifies: REQ-FLASH-001, REQ-FLASH-003, SPEC-LIQ-015, INV-095
    function check_PROP_080_completedLoanRepaidWithinCap(
        uint64 amount
    ) public {
        (bool ok, bytes memory ret) =
            address(swap).call(abi.encodeCall(MockFlashReceiver.borrow, (address(usdc), amount, HUB, CTX)));
        if (ok) {
            uint256 premium = abi.decode(ret, (uint256));
            assert(premium * 10_000 <= uint256(amount) * 10);
            assert(usdc.balanceOf(aUsdc) == IDLE + premium);
        }
    }

    /// @notice A donation of any size to the source is never forwarded: a completed loan delivered LPVaultSwap exactly
    /// `amount` (that such loans complete is `testFuzz_TEST_080_donationNeverForwarded` and `test_TEST_080_*`).
    // PROP-080 verifies: REQ-FLASH-001, REQ-FLASH-003, INV-021
    function check_PROP_080_donationNeverForwarded(
        uint64 amount,
        uint64 donation
    ) public {
        usdc.mint(address(source), donation);
        (bool ok,) = address(swap).call(abi.encodeCall(MockFlashReceiver.borrow, (address(usdc), amount, HUB, CTX)));
        if (ok) {
            assert(swap.lastReceived() == amount);
            assert(usdc.allowance(address(source), address(pool)) == 0);
        }
    }

    /// @notice The cap above the rate: at `rate = 5` and `cap > 5`, the source's ceiling quote of every loan with
    /// `F (cap − 5) ≥ 10⁴` passes the exact pre-loan check (the half-up charge never exceeds the quote: MATH-ST-115;
    /// completion of such loans: `testFuzz_TEST_052_capDecisionIsExact`).
    // PROP-080 verifies: SPEC-LIQ-015, REQ-FLASH-001, REQ-FLASH-003
    function check_PROP_080_capAboveRateAdmits(
        uint64 amount,
        uint8 cap
    ) public view {
        vm.assume(cap > 5 && cap <= 100);
        vm.assume(uint256(amount) * (cap - 5) >= 10_000);
        uint256 quote = source.flashPremium(address(usdc), amount);
        assert(quote * 10_000 <= uint256(cap) * amount);
    }
}
