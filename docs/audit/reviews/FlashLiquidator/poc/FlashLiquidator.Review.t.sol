// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILPVaultSwapLiquidation} from "../../src/liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {LiquidationParams} from "../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {FlashLiquidator} from "../../src/periphery/flash-liquidator/FlashLiquidator.sol";
import {OperatorFlashLiquidator} from "../../src/periphery/flash-liquidator/OperatorFlashLiquidator.sol";
import {FlashLiquidationRequest} from "../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {FlashLiquidatorFixture} from "../utils/fixtures/FlashLiquidatorFixture.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice LPVaultSwap's funding and shortfall pulls as SPEC-LIQ-019 and REQ-SWAP-011 state them, and nothing else:
/// pull `X` from `msg.sender`, let the Spoke take `D`, recover `R`, then pull `shortfall = max(0, minRec - R)` from
/// `msg.sender` when it is at most `maxShortfall`, and pay `keeperOut = Kf + R + shortfall - D - A` to `msg.sender`.
contract ShortfallLiquidationSwap is ILPVaultSwapLiquidation {
    using SafeERC20 for IERC20;

    address public constant SPOKE = address(0x5B0CE);
    PayoutToken public immutable T;
    uint256 public d;
    uint256 public r;
    uint256 public a;
    uint256 public minRec;
    uint256 public lastShortfall;

    constructor(
        PayoutToken t
    ) {
        T = t;
    }

    function setOutcome(
        uint256 d_,
        uint256 r_,
        uint256 a_,
        uint256 minRec_
    ) external {
        (d, r, a, minRec) = (d_, r_, a_, minRec_);
    }

    function liquidate(
        LiquidationParams calldata params
    ) external override returns (LiquidationResult memory result) {
        IERC20 t = IERC20(address(T));
        uint256 before = t.balanceOf(address(this));
        t.safeTransferFrom(msg.sender, address(this), params.debtToCover);
        uint256 kf = t.balanceOf(address(this)) - before;
        t.safeTransfer(SPOKE, d);
        T.mint(address(this), r);
        uint256 shortfall = minRec > r ? minRec - r : 0;
        require(shortfall <= params.maxShortfall, "RecoveryBelowFloor");
        // SPEC-LIQ-019: "pulls exactly shortfall of T from msg.sender".
        if (shortfall != 0) t.safeTransferFrom(msg.sender, address(this), shortfall);
        lastShortfall = shortfall;
        uint256 keeperOut = kf + r + shortfall - d - a;
        t.safeTransfer(address(0xFEE), a);
        t.safeTransfer(msg.sender, keeperOut);
        result.keeperOut = keeperOut;
    }

    function settlePending(
        uint256,
        uint256
    ) external pure override returns (uint256, uint256[] memory, uint256) {
        revert("not modelled");
    }
}

/// @notice Review PoCs for the flash liquidation helper (2.11 REQ-HELPER-*).
contract FlashLiquidatorReviewTest is FlashLiquidatorFixture {
    function setUp() public {
        _deployHelpers();
    }

    // ─── FL-01: the helper cannot fund a SPEC-LIQ-019 shortfall ───

    /// @notice SPEC-LIQ-019 example: V = 12,422.6, minRec = 12,297.373998, the routes return R = 12,174 USDC, so
    /// LPVaultSwap pulls shortfall = 123.373998 USDC from its caller. A direct caller that approves X + maxShortfall
    /// settles; the same liquidation through the public helper reverts whatever `maxShortfall`, `maxTopUp` and
    /// inventory the caller gives it, because the helper approves LPVaultSwap for exactly X and holds exactly X.
    function test_POC_FL01_helperCannotPayTheShortfallTopUp() public {
        ShortfallLiquidationSwap swap = new ShortfallLiquidationSwap(usdcToken);
        uint256 x = 12_000e6;
        uint256 minRec = 12_297.373998e6;
        uint256 rec = 12_174e6;
        swap.setOutcome(x, rec, 0, minRec);
        FlashLiquidator h = new FlashLiquidator(address(aavePool), address(swap), address(registry), address(store));

        LiquidationParams memory p = _params(x);
        p.maxShortfall = 200e6;

        // A direct caller with its own funds: X plus the shortfall.
        _fund(caller, address(swap), x + 200e6);
        vm.prank(caller);
        swap.liquidate(p);
        assertEq(swap.lastShortfall(), 123.373998e6, "direct caller paid the floor gap");

        // The same liquidation through the helper: flash X, ample top-up budget, caller funded and approved.
        address keeper = makeAddr("keeper");
        _fund(keeper, address(h), 1_000_000e6);
        FlashLiquidationRequest memory req;
        req.params = p;
        req.flashAmount = x;
        req.maxPremium = 10e6;
        req.maxTopUp = 1_000_000e6;
        req.minPayout = 0;
        vm.prank(keeper);
        // The shortfall pull fails: the X pull used the helper's whole allowance.
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(swap), 0, 123.373998e6)
        );
        h.flashLiquidate(req);

        // Inventory instead of a loan for part of X changes nothing: the helper still approves and holds exactly X.
        req.flashAmount = 1e6;
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(swap), 0, 123.373998e6)
        );
        h.flashLiquidate(req);
    }

    // ─── FL-02: the operator Safe's loss is not bounded by MAX_TOP_UP_BPS ───

    /// @notice REQ-HELPER-011: "a compromised signer key ... can lose at most the bounded top-up per call, never the
    /// Safe's inventory". The bound is `⌊X × MAX_TOP_UP_BPS / 10⁴⌋` with X chosen by the signer, and the premium on
    /// an oversized loan is paid out of the Safe's own inventory without any top-up. Bob's liquidation repays
    /// D = 1,950 USDC (keeper reward 70.8 USDC).
    function test_POC_FL02_signerBurnsSafeInventoryWithTopUpsDisabled() public {
        // An operator helper with top-ups disabled entirely.
        OperatorFlashLiquidator noTopUp = new OperatorFlashLiquidator(
            address(aavePool), address(lvs), address(registry), address(store), signer, safe, 0
        );
        // The operator's Safe holds and approves inventory, as REQ-HELPER-011 expects.
        _fund(safe, address(noTopUp), 10_000e6);

        // Honest sizing: X = F = 1,950 USDC pays the Safe 69.825 USDC.
        vm.prank(signer);
        uint256 honest = noTopUp.flashLiquidate(_request(1950e6, 1950e6, 975_000, 0, 0));
        assertEq(honest, 69.825e6);
        uint256 safeAfterHonest = usdcToken.balanceOf(safe);
        assertEq(safeAfterHonest, 10_000e6 + 69.825e6);

        // Compromised signer, same account and outcome: X = 10,000,000 USDC, F = X - 5,000 USDC (premium 4,997.5 USDC
        // at 5 bps), maxTopUp = 0, minPayout = 0. No top-up is pulled, yet the Safe pays the premium.
        uint256 x = 10_000_000e6;
        uint256 f = x - 5000e6;
        vm.prank(signer);
        uint256 payout = noTopUp.flashLiquidate(_request(x, f, 5000e6, 0, 0));
        assertEq(payout, 73.3e6, "keeperOut - F - premium = (X + 70.8) - (X - 5,000) - 4,997.5");
        uint256 lost = safeAfterHonest - usdcToken.balanceOf(safe);
        assertEq(lost, 4926.7e6, "the Safe lost 4,926.7 USDC of inventory with MAX_TOP_UP_BPS = 0");
    }

    /// @notice With the fixture's MAX_TOP_UP_BPS = 100 and F = X, the top-up bound is 1 % of the signer's X, so one
    /// liquidation of a 1,950 USDC debt can take 4,929.2 USDC from the Safe (the 2.11 example suggests 98 USDC for a
    /// 9,800 USDC call).
    function test_POC_FL02_topUpBoundScalesWithTheSignersDebtToCover() public {
        _fund(safe, address(opHelper), 10_000e6);
        uint256 x = 10_000_000e6;
        vm.prank(signer);
        uint256 payout = opHelper.flashLiquidate(_request(x, x, 5000e6, type(uint256).max, 0));
        assertEq(payout, 0);
        assertEq(usdcToken.balanceOf(safe), 10_000e6 - 4929.2e6, "top-up = 5,000 premium - 70.8 reward");
    }

    // ─── FL-03: an issuer block on the public helper strands residues and stops its liquidations ───

    /// @notice REQ-HELPER-010: a residue escrowed for the public helper "arises only when a market token refuses
    /// transfers to the helper, in which case no forward to the caller could succeed either". A per-address issuer
    /// block (USDT, USDC) on the helper alone refuses the helper while the caller could receive: the residue is
    /// credited to the helper, which has no claim function, so it is stranded; and once the debt asset itself blocks
    /// the helper, every helper liquidation of that debt reverts for every caller.
    function test_POC_FL03_issuerBlockOnHelperStrandsResidue() public {
        usdtToken.setBlocked(address(helper), true);
        lvs.addResidue(usdtToken, 0.4e6);
        vm.prank(caller);
        helper.flashLiquidate(_exampleRequest());
        assertEq(usdtToken.balanceOf(caller), 0, "the unblocked caller gets nothing");
        assertEq(escrow.claimable(address(usdtToken), address(helper)), 0.4e6, "credited to a helper with no claim");

        usdcToken.setBlocked(address(helper), true);
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(PayoutToken.Blocked.selector, address(helper)));
        helper.flashLiquidate(_exampleRequest());
    }
}
