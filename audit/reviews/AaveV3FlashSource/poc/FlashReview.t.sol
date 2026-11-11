// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AaveV3FlashSource} from "../../src/flash/AaveV3FlashSource.sol";
import {IFlashReceiver} from "../../src/flash/IFlashReceiver.sol";
import {IFlashSource} from "../../src/flash/IFlashSource.sol";
import {IAaveV3FlashLoanReceiver} from "../../src/interfaces/external/aave/IAaveV3FlashLoanReceiver.sol";
import {FlashSourceFixture} from "../utils/fixtures/FlashSourceFixture.sol";
import {MockAaveV3ACLManager, MockAaveV3AddressesProvider, MockAaveV3Pool, MockAToken} from "../utils/mocks/AaveV3PoolMocks.sol";
import {PayoutToken} from "../utils/mocks/PayoutToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// LPVaultSwap side as REQ-SWAP-013 states it: reverts InvalidFlashCallback unless 0 < Fr <= amount.
contract StrictReceiver is IFlashReceiver {
    using SafeERC20 for IERC20;

    error InvalidFlashCallback();

    IFlashSource public source;
    uint256 internal before;

    function setSource(address s) external {
        source = IFlashSource(s);
    }

    function borrow(address asset, uint256 amount, address hub, bytes calldata ctx) external returns (uint256) {
        before = IERC20(asset).balanceOf(address(this));
        return source.flashLoan(asset, amount, hub, ctx);
    }

    function onFlashLoan(address asset, uint256 amount, uint256 premium, bytes calldata)
        external
        returns (bytes32)
    {
        uint256 fr = IERC20(asset).balanceOf(address(this)) - before;
        if (fr == 0 || fr > amount) revert InvalidFlashCallback(); // REQ-SWAP-013
        uint256 owed = amount + premium;
        for (uint256 i = 0; i < 4; ++i) {
            uint256 b = IERC20(asset).balanceOf(address(source));
            if (b >= owed) break;
            IERC20(asset).safeTransfer(address(source), owed - b);
        }
        return keccak256("IFlashReceiver.onFlashLoan");
    }
}

/// Aave V3.1+ virtual accounting: the Pool lends from `virtualUnderlyingBalance` with checked math, not from
/// `balanceOf(aToken)`; a direct transfer to the aToken is not counted.
contract VirtualAccountingPool {
    using SafeERC20 for IERC20;

    address public ADDRESSES_PROVIDER;
    uint128 public FLASHLOAN_PREMIUM_TOTAL = 5;
    mapping(address => address) public aTokenOf;
    mapping(address => uint128) public virtualUnderlyingBalance;

    constructor(address provider) {
        ADDRESSES_PROVIDER = provider;
    }

    function list(address asset, uint128 supplied) external returns (address a) {
        a = address(new MockAToken(address(this), asset));
        aTokenOf[asset] = a;
        virtualUnderlyingBalance[asset] = supplied;
    }

    function getConfiguration(address) external pure returns (uint256) {
        return (1 << 56) | (1 << 63);
    }

    function getReserveAToken(address asset) external view returns (address) {
        return aTokenOf[asset];
    }

    function flashLoan(
        address receiver,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata,
        address,
        bytes calldata params,
        uint16
    ) external {
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = (amounts[0] * FLASHLOAN_PREMIUM_TOTAL + 5000) / 10_000; // percentMul, half-up (V3.0-3.4)
        virtualUnderlyingBalance[assets[0]] -= uint128(amounts[0]); // checked: panic 0x11 when short
        MockAToken(aTokenOf[assets[0]]).transferUnderlyingTo(receiver, amounts[0]);
        require(
            IAaveV3FlashLoanReceiver(receiver).executeOperation(assets, amounts, premiums, msg.sender, params), "ret"
        );
        IERC20(assets[0]).safeTransferFrom(receiver, aTokenOf[assets[0]], amounts[0] + premiums[0]);
        virtualUnderlyingBalance[assets[0]] += uint128(amounts[0] + premiums[0]);
    }
}

contract FlashReviewTest is FlashSourceFixture {
    bytes internal constant CTX = hex"c0ffee";

    function setUp() public {
        _deployFlashSource();
    }

    /// H-1: a 1-wei donation to the source makes every later flash loan of that asset forward Fr = amount + 1,
    /// which REQ-SWAP-013 refuses; the revert restores the donation, so the block is permanent (no sweep).
    function test_REVIEW_donationBricksFlashPathUnderReqSwap013() public {
        StrictReceiver strict = new StrictReceiver();
        AaveV3FlashSource src = new AaveV3FlashSource(address(aavePool), address(strict), address(store));
        strict.setSource(address(src));
        usdcToken.mint(address(strict), 1_000e6);

        // Works before the donation.
        strict.borrow(address(usdcToken), 1_000e6, address(hub), CTX);

        // Anyone donates 1 wei.
        usdcToken.mint(address(this), 1);
        usdcToken.transfer(address(src), 1);

        for (uint256 i = 0; i < 3; ++i) {
            vm.expectRevert(StrictReceiver.InvalidFlashCallback.selector);
            strict.borrow(address(usdcToken), 1_000e6 + i, address(hub), CTX);
        }
        assertEq(usdcToken.balanceOf(address(src)), 1, "donation is stuck: no sweep, every loan reverts");
    }

    /// M-1: under virtual accounting, a direct transfer to the aToken raises `maxFlashLoan` above what the Pool can
    /// lend; a loan sized to `maxFlashLoan` passes the source's check and the Pool panics instead of the source
    /// refusing with InsufficientFlashLiquidity.
    function test_REVIEW_maxFlashLoanOverstatesUnderVirtualAccounting() public {
        VirtualAccountingPool vp = new VirtualAccountingPool(address(provider));
        PayoutToken t = new PayoutToken("USDC2", 6);
        address a = vp.list(address(t), 1_000_000e6);
        t.mint(a, 1_000_000e6); // supplied liquidity
        t.mint(a, 50_000e6); // donation to the aToken, not counted by the Pool
        AaveV3FlashSource src = new AaveV3FlashSource(address(vp), address(swap), address(store));
        swap.setSource(address(src));
        t.mint(address(swap), 10_000e6);

        assertEq(src.maxFlashLoan(address(t)), 1_050_000e6, "reports donation as lendable");
        vm.expectRevert(abi.encodeWithSignature("Panic(uint256)", 0x11));
        swap.borrow(address(t), 1_000_001e6, address(hub), CTX);
    }

    /// Info: Pool rounds half-up (V3.0-3.4 percentMul); the source quotes ceil. The quote can exceed the charge,
    /// so the pre-check refuses a loan the Pool would charge within the cap (fails closed).
    function test_REVIEW_ceilQuoteRefusesLoanThatHalfUpChargeAdmits() public {
        _setCap(5); // cap == rate
        VirtualAccountingPool vp = new VirtualAccountingPool(address(provider));
        PayoutToken t = new PayoutToken("USDC3", 6);
        address a = vp.list(address(t), 1_000_000e6);
        t.mint(a, 1_000_000e6);
        AaveV3FlashSource src = new AaveV3FlashSource(address(vp), address(swap), address(store));
        swap.setSource(address(src));
        t.mint(address(swap), 10_000e6);
        // F = 1,950,000,001: half-up charge = 975,000 (within cap: 9,750,000,000 <= 9,750,000,005); ceil = 975,001.
        vm.expectRevert(abi.encodeWithSelector(IFlashSource.FlashFeeTooHigh.selector, 975_001, 975_000));
        swap.borrow(address(t), 1_950_000_001, address(hub), CTX);
    }
}
