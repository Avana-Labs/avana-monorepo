// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {RouteMode} from "../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {PayoutEscrow} from "../../src/liquidation/payout-escrow/PayoutEscrow.sol";
import {Lock} from "../../src/lock/lock/Lock.sol";
import {FlashLiquidator} from "../../src/periphery/flash-liquidator/FlashLiquidator.sol";
import {IFlashLiquidator} from "../../src/periphery/flash-liquidator/IFlashLiquidator.sol";
import {IFlashLiquidatorErrors} from "../../src/periphery/flash-liquidator/IFlashLiquidatorErrors.sol";
import {OperatorFlashLiquidator} from "../../src/periphery/flash-liquidator/OperatorFlashLiquidator.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {DebtReserveDef} from "../../src/policy/market-registry/types/DebtReserveDef.sol";
import {Market} from "../../src/types/Market.sol";
import {MockAaveV3ACLManager, MockAaveV3AddressesProvider, MockAaveV3Pool} from "../utils/mocks/AaveV3PoolMocks.sol";
import {LockMember} from "../utils/mocks/LockMember.sol";
import {MockFlashFeeCap} from "../utils/mocks/MockFlashReceiver.sol";
import {MockLiquidationSwap} from "../utils/mocks/MockLiquidationSwap.sol";
import {MockMarketRegistry} from "../utils/mocks/MockMarketRegistry.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {Test} from "forge-std/Test.sol";

/// @title FlashLiquidatorHalmosTest
/// @notice Symbolic checks of the public flash liquidation helper (2.11 `REQ-HELPER-002`, `REQ-HELPER-005`): for every
/// caller, initiator, amount and premium, `executeOperation` outside an open context reverts `InvalidFlashCallback`; a
/// Pool reporting any initiator other than the helper makes the call revert; a completed call was charged a premium
/// within the caller's `maxPremium` and the exact `maxFlashFeeBps` cap, repaid the Pool `F + premium`, paid the caller
/// the rest and left the helper with no balance or allowance; a Pool recorded as a Hub is refused at deployment and on
/// every call; the ERC-3156 minter callback `onFlashLoan` reaches no function, for every caller and argument (the Pool
/// is the only lender, REQ-HELPER-015); the operator variant's Safe loses at most `MAX_TOP_UP_BPS` of the debt repaid, with or without a loan, and
/// never funds a loan above the need.
/// @dev The Pool, ACLManager and PoolAddressesProvider are the unit suite's mocks; `maxFlashFeeBps` is
/// `MockFlashFeeCap` (10, the launch value); LPVaultSwap is `MockLiquidationSwap` over the real Lock and PayoutEscrow,
/// settling the 2.11 example (`keeperOut = 2,020.8` USDC for `X = F = 1,950` USDC). Premiums are bounded to uint64.
contract FlashLiquidatorHalmosTest is Test {
    address internal constant CALLER = address(0xCA11E2);
    address internal constant TREASURY = address(0x7EA5);
    address internal constant SPOKE = address(0x5B);
    address internal constant SIGNER = address(0x5161);
    address internal constant SAFE = address(0x5AFE);
    uint256 internal constant IDLE = 18_000_000e6;
    uint256 internal constant MARKET_ID = 7;
    uint256 internal constant DEBT_RESERVE = 3;
    uint256 internal constant X = 1950e6;

    MockAaveV3ACLManager internal acl;
    MockAaveV3AddressesProvider internal provider;
    MockAaveV3Pool internal pool;
    MockFlashFeeCap internal capStore;
    MockMarketRegistry internal registry;
    PayoutToken internal usdc;
    PayoutToken internal usdt;
    address internal aUsdc;
    MockLiquidationSwap internal lvs;
    FlashLiquidator internal helper;
    OperatorFlashLiquidator internal op;

    function setUp() public {
        acl = new MockAaveV3ACLManager();
        provider = new MockAaveV3AddressesProvider(address(acl));
        pool = new MockAaveV3Pool(address(provider), 5);
        capStore = new MockFlashFeeCap(10);
        usdc = new PayoutToken("USDC", 6);
        usdt = new PayoutToken("USDT", 6);
        aUsdc = pool.listReserve(address(usdc));
        usdc.mint(aUsdc, IDLE);
        pool.recordSupply(address(usdc), IDLE);

        lvs = new MockLiquidationSwap();
        LockMember adapter = new LockMember();
        Lock lock = new Lock(address(adapter), address(lvs));
        adapter.setLock(lock);
        PayoutEscrow escrow = new PayoutEscrow(address(lvs), address(lock));
        lvs.setUp(lock, escrow, usdc, TREASURY);
        lvs.setOutcome(X, 2040.3e6, 19.5e6);

        registry = new MockMarketRegistry();
        registry.setRouteReads(true);
        Market memory m;
        m.spoke = SPOKE;
        m.tokens = new address[](2);
        (m.tokens[0], m.tokens[1]) = (address(usdc), address(usdt));
        registry.setMarket(MARKET_ID, m);
        DebtReserveDef memory d;
        d.reserveId = DEBT_RESERVE;
        d.asset = address(usdc);
        d.approved = true;
        registry.setDebtReserve(SPOKE, d);
        helper = new FlashLiquidator(address(pool), address(lvs), address(registry), address(capStore));
        op = new OperatorFlashLiquidator(
            address(pool), address(lvs), address(registry), address(capStore), SIGNER, SAFE, 100
        );
        usdc.mint(SAFE, 1_000_000e6);
        vm.prank(SAFE);
        usdc.approve(address(op), type(uint256).max);
    }

    function _request(
        uint256 maxPremium
    ) internal view returns (FlashLiquidationRequest memory r) {
        LiquidationParams memory p;
        p.proxy = address(0xB0B);
        p.marketId = MARKET_ID;
        p.debtReserveId = DEBT_RESERVE;
        p.debtToCover = X;
        p.routeMode = RouteMode.PrimaryThenBackup;
        p.deadline = block.timestamp + 60;
        r.params = p;
        r.flashAmount = X;
        r.maxPremium = maxPremium;
    }

    function _call(
        FlashLiquidationRequest memory request
    ) internal returns (bool ok, bytes memory ret) {
        vm.prank(CALLER);
        (ok, ret) = address(helper).call(abi.encodeCall(IFlashLiquidator.flashLiquidate, (request)));
    }

    function _is(
        bytes memory ret,
        bytes4 selector
    ) internal pure returns (bool) {
        return ret.length >= 4 && bytes4(ret) == selector;
    }

    /// @notice Outside an open context every callback reverts, whoever sends it and whatever it carries.
    // PROP-036 verifies: REQ-HELPER-005, REQ-HELPER-013, INV-040, Q-045
    function check_PROP_036_helperCallbackOutsideContextRefused(
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
        (bool ok, bytes memory ret) = address(helper)
            .call(
                abi.encodeCall(
                    IFlashLiquidator.executeOperation,
                    (assets, amounts, premiums, initiator, abi.encode(_request(0).params))
                )
            );
        assert(!ok);
        assert(_is(ret, IFlashLiquidatorErrors.InvalidFlashCallback.selector));
    }

    /// @notice The Pool reporting any initiator other than the helper makes the whole call revert.
    // PROP-036 verifies: REQ-HELPER-005, REQ-HELPER-013, INV-040, Q-045
    function check_PROP_036_helperOnlyOwnInitiator(
        address initiator
    ) public {
        pool.setInitiatorOverride(initiator);
        (bool ok,) = _call(_request(975_000));
        assert(!ok || initiator == address(0) || initiator == address(helper));
    }

    /// @notice A completed call, for every premium the Pool charges and every `maxPremium`, was charged within both
    /// bounds, repaid the Pool `F + premium`, paid the caller `keeperOut − F − premium` and left the helper empty.
    // PROP-036 verifies: REQ-HELPER-005, REQ-HELPER-007, REQ-HELPER-008, SPEC-LIQ-015, INV-040
    function check_PROP_036_helperCompletedCallWithinBounds(
        uint64 premium,
        uint64 maxPremium
    ) public {
        pool.setPremiumOverride(premium);
        (bool ok, bytes memory ret) = _call(_request(maxPremium));
        if (ok) {
            assert(premium <= maxPremium);
            assert(uint256(premium) * 10_000 <= 10 * X);
            uint256 payout = abi.decode(ret, (uint256));
            assert(payout == 2020.8e6 - X - premium);
            assert(usdc.balanceOf(CALLER) == payout);
            assert(usdc.balanceOf(aUsdc) == IDLE + premium);
            assert(usdc.balanceOf(address(helper)) == 0);
            assert(usdc.allowance(address(helper), address(pool)) == 0);
            assert(usdc.allowance(address(helper), address(lvs)) == 0);
        }
    }

    /// @notice A Pool recorded as a Hub: deployment reverts, and a recording after deployment refuses every call.
    // PROP-096 verifies: REQ-HELPER-002, REQ-HELPER-013, INV-095, Q-386
    function check_PROP_096_helperHubPoolRefused(
        bool recorded
    ) public {
        registry.setHub(address(pool), recorded);
        bool deployed;
        try new FlashLiquidator(address(pool), address(lvs), address(registry), address(capStore)) {
            deployed = true;
        } catch (bytes memory reason) {
            assert(_is(reason, IFlashLiquidatorErrors.FlashSourceIsHub.selector));
        }
        assert(deployed == !recorded);
        (bool ok, bytes memory ret) = _call(_request(975_000));
        if (recorded) {
            assert(!ok);
            assert(_is(ret, IFlashLiquidatorErrors.FlashSourceIsHub.selector));
        } else {
            assert(ok);
        }
        assert(pool.flashLoanCalls() == (ok ? 1 : 0));
    }

    /// @notice The helper has no ERC-3156 minter callback: `onFlashLoan(address,address,uint256,uint256,bytes)` reverts
    /// with no data in both variants, whoever sends it and whatever it carries, because no function answers it.
    // PROP-036 verifies: REQ-HELPER-001, REQ-HELPER-005, REQ-HELPER-015, INV-040
    function check_PROP_036_helperHasNoMinterCallback(
        address caller,
        address initiator,
        address token,
        uint256 amount,
        uint256 fee
    ) public {
        bytes memory data = abi.encodeWithSelector(
            bytes4(keccak256("onFlashLoan(address,address,uint256,uint256,bytes)")),
            initiator,
            token,
            amount,
            fee,
            abi.encode(_request(0).params)
        );
        vm.prank(caller);
        (bool ok, bytes memory ret) = address(helper).call(data);
        assert(!ok);
        assert(ret.length == 0);
        vm.prank(caller);
        (ok, ret) = address(op).call(data);
        assert(!ok);
        assert(ret.length == 0);
    }

    /// @notice Operator variant, for every recovery and every `maxTopUp`: a completed call left the Safe at most
    /// `floor(D x MAX_TOP_UP_BPS / 1e4)` = 19.5 USDC poorer (D = 1,950 USDC).
    // PROP-036 verifies: REQ-HELPER-007, REQ-HELPER-008, REQ-HELPER-011
    function check_PROP_036_operatorSafeLossBoundedByDebtRepaid(
        uint40 recovered,
        uint64 maxTopUp
    ) public {
        lvs.setOutcome(X, recovered, 0);
        FlashLiquidationRequest memory r = _request(975_000);
        r.maxTopUp = maxTopUp;
        uint256 before = usdc.balanceOf(SAFE);
        vm.prank(SIGNER);
        (bool ok,) = address(op).call(abi.encodeCall(IFlashLiquidator.flashLiquidate, (r)));
        if (ok) {
            uint256 after_ = usdc.balanceOf(SAFE);
            assert(after_ + 19.5e6 >= before);
            assert(usdc.balanceOf(address(op)) == 0);
        }
    }

    /// @notice Operator variant with `F = 0` (no loan, REQ-HELPER-004), for every recovery and Avana fee: the Pool is never
    /// called, a completed call left the Safe at most `floor(D x MAX_TOP_UP_BPS / 1e4)` = 19.5 USDC poorer and the
    /// helper empty, and a refused call left the Safe whole.
    // PROP-036 verifies: REQ-HELPER-008, REQ-HELPER-011
    function check_PROP_036_operatorZeroLoanSafeLossBounded(
        uint40 recovered,
        uint32 avanaFee
    ) public {
        vm.assume(avanaFee <= recovered);
        lvs.setOutcome(X, recovered, avanaFee);
        FlashLiquidationRequest memory r = _request(0);
        r.flashAmount = 0;
        uint256 before = usdc.balanceOf(SAFE);
        vm.prank(SIGNER);
        (bool ok,) = address(op).call(abi.encodeCall(IFlashLiquidator.flashLiquidate, (r)));
        uint256 after_ = usdc.balanceOf(SAFE);
        if (ok) {
            assert(after_ + 19.5e6 >= before);
            assert(usdc.balanceOf(address(op)) == 0);
            assert(usdc.allowance(address(op), address(lvs)) == 0);
        } else {
            assert(after_ == before);
        }
        assert(pool.flashLoanCalls() == 0);
    }

    /// @notice Operator variant, for every loan size up to `X = 1,000,000` USDC against a 1,950 USDC debt: a completed
    /// call borrowed at most `ceil(1,950 x 1.05)` = 2,047.5 USDC.
    // PROP-036 verifies: REQ-HELPER-011
    function check_PROP_036_operatorLoanWithinNeed(
        uint40 flashAmount
    ) public {
        FlashLiquidationRequest memory r = _request(type(uint64).max);
        r.params.debtToCover = 1_000_000e6;
        r.flashAmount = flashAmount;
        vm.prank(SIGNER);
        (bool ok,) = address(op).call(abi.encodeCall(IFlashLiquidator.flashLiquidate, (r)));
        if (ok) assert(flashAmount <= 2047.5e6);
    }
}
