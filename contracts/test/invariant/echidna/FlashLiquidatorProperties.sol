// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV3FlashLoanReceiver} from "../../../src/interfaces/external/aave/IAaveV3FlashLoanReceiver.sol";
import {LiquidationParams} from "../../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {FlashLiquidator} from "../../../src/periphery/flash-liquidator/FlashLiquidator.sol";
import {IFlashLiquidator} from "../../../src/periphery/flash-liquidator/IFlashLiquidator.sol";
import {IFlashLiquidatorErrors} from "../../../src/periphery/flash-liquidator/IFlashLiquidatorErrors.sol";
import {FlashLiquidationRequest} from "../../../src/periphery/flash-liquidator/types/FlashLiquidationRequest.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {Market} from "../../../src/types/Market.sol";
import {MockFlashFeeCap} from "../../utils/mocks/MockFlashReceiver.sol";
import {PayoutToken} from "../../utils/mocks/PayoutToken.sol";

/// @notice An Aave V3 Pool stand-in with only what the helper calls: the reserve of one asset (held by the Pool itself,
/// which is also its aToken), its ACLManager and PoolAddressesProvider (the Pool, refusing every flash borrower), and
/// `flashLoan` lending from it, calling back with the premium and initiator the harness sets and pulling
/// `amount + premium` back. The premium is `FLASHLOAN_PREMIUM_TOTAL` half-up (V3.4 `percentMul`) unless overridden.
contract FlashLiquidatorPoolStandIn {
    uint128 public constant FLASHLOAN_PREMIUM_TOTAL = 5;
    /// @dev Active (bit 56) and flash loans enabled (bit 63), not paused.
    uint256 internal constant CONFIGURATION = (1 << 56) | (1 << 63);
    PayoutToken internal immutable ASSET;

    bool public premiumOverridden;
    uint256 public premiumOverride;
    address public initiatorOverride;

    constructor(
        PayoutToken asset
    ) {
        ASSET = asset;
    }

    function setPremiumOverride(
        uint256 premium
    ) external {
        (premiumOverridden, premiumOverride) = (true, premium);
    }

    function setInitiatorOverride(
        address initiator
    ) external {
        initiatorOverride = initiator;
    }

    function ADDRESSES_PROVIDER() external view returns (address) {
        return address(this);
    }

    function getACLManager() external view returns (address) {
        return address(this);
    }

    function isFlashBorrower(
        address
    ) external pure returns (bool) {
        return false;
    }

    function getConfiguration(
        address asset
    ) external view returns (uint256) {
        return asset == address(ASSET) ? CONFIGURATION : 0;
    }

    function getReserveAToken(
        address asset
    ) external view returns (address) {
        return asset == address(ASSET) ? address(this) : address(0);
    }

    function getVirtualUnderlyingBalance(
        address asset
    ) external view returns (uint128) {
        return asset == address(ASSET) ? uint128(ASSET.balanceOf(address(this))) : 0;
    }

    function flashLoan(
        address receiver,
        address[] calldata assets,
        uint256[] calldata amounts,
        uint256[] calldata modes,
        address,
        bytes calldata params,
        uint16
    ) external {
        require(assets.length == 1 && amounts.length == 1 && modes.length == 1, "one asset");
        require(assets[0] == address(ASSET) && modes[0] == 0, "reserve");
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = premiumOverridden ? premiumOverride : (amounts[0] * FLASHLOAN_PREMIUM_TOTAL + 5000) / 1e4;
        require(ASSET.transfer(receiver, amounts[0]), "lend");
        address initiator = initiatorOverride == address(0) ? msg.sender : initiatorOverride;
        require(
            IAaveV3FlashLoanReceiver(receiver).executeOperation(assets, amounts, premiums, initiator, params),
            "invalid return"
        );
        require(ASSET.transferFrom(receiver, address(this), amounts[0] + premiums[0]), "repay");
    }
}

/// @notice A MarketRegistry stand-in with only what the helper reads: one market of the debt asset and one other token
/// on `SPOKE`, its debt reserve, no recorded Hub and no settlement route.
contract FlashLiquidatorRegistryStandIn {
    address internal immutable ASSET;
    address internal immutable OTHER;
    address internal immutable SPOKE;

    constructor(
        address asset,
        address other,
        address spoke
    ) {
        (ASSET, OTHER, SPOKE) = (asset, other, spoke);
    }

    function isRecordedHub(
        address
    ) external pure returns (bool) {
        return false;
    }

    function getMarket(
        uint256
    ) external view returns (Market memory m) {
        m.spoke = SPOKE;
        m.tokens = new address[](2);
        (m.tokens[0], m.tokens[1]) = (ASSET, OTHER);
    }

    function getDebtReserve(
        address,
        uint256 reserveId
    ) external view returns (DebtReserveDef memory d) {
        d.reserveId = reserveId;
        d.asset = ASSET;
        d.approved = true;
    }

    function getRoute(
        uint256,
        address,
        address,
        uint8
    ) external pure returns (address route, bool usable) {}
}

/// @notice An LPVaultSwap stand-in settling the 2.11 example: it pulls `debtToCover` from the caller, repays
/// `min(DEBT_REPAID, Kf)` to the Spoke, recovers `RECOVERED`, pays the Avana fee to the treasury and the rest
/// (`keeperOut = Kf + R − D − A`) to the caller. It is its own PayoutEscrow, which credits nobody.
contract FlashLiquidatorSwapStandIn {
    uint256 internal constant DEBT_REPAID = 1950e6;
    uint256 internal constant RECOVERED = 2040.3e6;
    uint256 internal constant AVANA_FEE = 19.5e6;
    PayoutToken internal immutable ASSET;
    address internal immutable SPOKE;
    address internal immutable TREASURY;

    constructor(
        PayoutToken asset,
        address spoke,
        address treasury
    ) {
        (ASSET, SPOKE, TREASURY) = (asset, spoke, treasury);
    }

    function PAYOUT_ESCROW() external view returns (address) {
        return address(this);
    }

    function claimable(
        address,
        address
    ) external pure returns (uint256) {
        return 0;
    }

    function liquidate(
        LiquidationParams calldata params
    ) external returns (LiquidationResult memory result) {
        require(block.timestamp <= params.deadline, "deadline");
        uint256 kf = params.debtToCover;
        require(kf != 0 && ASSET.transferFrom(msg.sender, address(this), kf), "funding");
        uint256 d = DEBT_REPAID < kf ? DEBT_REPAID : kf;
        uint256 keeperOut = kf + RECOVERED - d - AVANA_FEE;
        require(keeperOut >= params.minPayout, "payout");
        ASSET.mint(address(this), RECOVERED);
        require(ASSET.transfer(SPOKE, d) && ASSET.transfer(TREASURY, AVANA_FEE), "settle");
        require(ASSET.transfer(msg.sender, keeperOut), "keeperOut");
        result.debtAsset = address(ASSET);
        result.debtRepaid = d;
        result.callerFunds = kf;
        result.recovered = RECOVERED;
        result.avanaFee = AVANA_FEE;
        result.keeperOut = keeperOut;
    }
}

/// @title FlashLiquidatorProperties
/// @notice Echidna and Medusa properties of the public flash liquidation helper (2.11 `REQ-HELPER-002`,
/// `REQ-HELPER-005`, `REQ-HELPER-007`, `REQ-HELPER-008`). Between transactions: the helper holds no token and no
/// allowance, and the Pool's reserve holds its idle liquidity plus every premium paid. Inside one transaction: a
/// completed liquidation was charged within the caller's `maxPremium` and the exact `maxFlashFeeBps` cap, repaid the
/// Pool `F + premium` and paid the caller `keeperOut − F − premium`; a failed one moves nothing; a callback outside an
/// open context reverts `InvalidFlashCallback`; a Pool reporting another initiator makes the call revert; the ERC-3156
/// minter callback reaches no function.
/// @dev The harness is the caller. The Pool, MarketRegistry and LPVaultSwap are the minimal stand-ins above (with the
/// unit suite's full mocks, the Lock and the PayoutEscrow the harness's initcode was 60,176 bytes at 200 runs, above
/// the 49,152-byte limit Medusa enforces); `maxFlashFeeBps` is `MockFlashFeeCap` (10, the launch value). The swap
/// settles the 2.11 example (`keeperOut = 2,020.8` USDC for `X = F = 1,950` USDC), as in
/// `test/halmos/FlashLiquidator.halmos.t.sol`. Premiums are bounded to uint64.
contract FlashLiquidatorProperties {
    uint256 internal constant IDLE = 18_000_000e6;
    uint256 internal constant MARKET_ID = 7;
    uint256 internal constant DEBT_RESERVE = 3;
    uint256 internal constant X = 1950e6;
    uint256 internal constant KEEPER_OUT = 2020.8e6;
    uint256 internal constant CAP_BPS = 10;
    address internal constant TREASURY = address(0x7EA5);
    address internal constant SPOKE = address(0x5B);

    FlashLiquidatorPoolStandIn internal immutable POOL;
    FlashLiquidatorSwapStandIn internal immutable LVS;
    PayoutToken internal immutable USDC;
    PayoutToken internal immutable USDT;
    FlashLiquidator internal immutable HELPER;

    /// @notice Sum of the premiums the Pool collected on completed liquidations.
    uint256 internal premiumsPaid;

    constructor() {
        USDC = new PayoutToken("USDC", 6);
        USDT = new PayoutToken("USDT", 6);
        POOL = new FlashLiquidatorPoolStandIn(USDC);
        USDC.mint(address(POOL), IDLE);
        LVS = new FlashLiquidatorSwapStandIn(USDC, SPOKE, TREASURY);
        FlashLiquidatorRegistryStandIn registry =
            new FlashLiquidatorRegistryStandIn(address(USDC), address(USDT), SPOKE);
        MockFlashFeeCap capStore = new MockFlashFeeCap(uint16(CAP_BPS));
        HELPER = new FlashLiquidator(address(POOL), address(LVS), address(registry), address(capStore));
    }

    // ─── Properties ───

    /// @notice The helper keeps nothing between transactions: no debt asset, no market token, no allowance.
    function property_helperHoldsNothing() external view returns (bool) {
        return USDC.balanceOf(address(HELPER)) == 0 && USDT.balanceOf(address(HELPER)) == 0
            && USDC.allowance(address(HELPER), address(POOL)) == 0 && USDC.allowance(address(HELPER), address(LVS)) == 0;
    }

    /// @notice Every loan was repaid in full: the reserve holds its idle liquidity plus the premiums collected.
    function property_reserveHoldsIdlePlusPremiums() external view returns (bool) {
        return USDC.balanceOf(address(POOL)) == IDLE + premiumsPaid;
    }

    // ─── Assertions ───

    /// @notice A liquidation with the Pool charging `premium` and the caller accepting `maxPremium`: a completed call is
    /// within both bounds and pays the 2.11 split; a failed one moves nothing.
    function liquidate(
        uint64 premium,
        uint64 maxPremium
    ) external {
        POOL.setPremiumOverride(premium);
        uint256 callerBefore = USDC.balanceOf(address(this));
        uint256 reserveBefore = USDC.balanceOf(address(POOL));
        (bool ok, bytes memory ret) =
            address(HELPER).call(abi.encodeCall(IFlashLiquidator.flashLiquidate, (_request(maxPremium))));
        if (ok) {
            assert(premium <= maxPremium);
            assert(uint256(premium) * 10_000 <= CAP_BPS * X);
            uint256 payout = abi.decode(ret, (uint256));
            assert(payout == KEEPER_OUT - X - premium);
            assert(USDC.balanceOf(address(this)) == callerBefore + payout);
            assert(USDC.balanceOf(address(POOL)) == reserveBefore + premium);
            premiumsPaid += premium;
        } else {
            assert(USDC.balanceOf(address(this)) == callerBefore);
            assert(USDC.balanceOf(address(POOL)) == reserveBefore);
        }
    }

    /// @notice Outside an open context the lender callback reverts `InvalidFlashCallback`, whatever it carries.
    function callbackOutsideContext(
        address initiator,
        uint256 amount,
        uint256 premium
    ) external {
        address[] memory assets = new address[](1);
        assets[0] = address(USDC);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        uint256[] memory premiums = new uint256[](1);
        premiums[0] = premium;
        (bool ok, bytes memory ret) = address(HELPER)
            .call(
                abi.encodeCall(
                    IFlashLiquidator.executeOperation,
                    (assets, amounts, premiums, initiator, abi.encode(_request(0).params))
                )
            );
        assert(!ok);
        assert(ret.length >= 4 && bytes4(ret) == IFlashLiquidatorErrors.InvalidFlashCallback.selector);
    }

    /// @notice A Pool reporting any initiator other than the helper makes the whole call revert; a call that completes
    /// was charged within the cap.
    function foreignInitiator(
        address initiator
    ) external {
        POOL.setInitiatorOverride(initiator);
        uint256 reserveBefore = USDC.balanceOf(address(POOL));
        (bool ok,) = address(HELPER).call(abi.encodeCall(IFlashLiquidator.flashLiquidate, (_request(type(uint64).max))));
        POOL.setInitiatorOverride(address(0));
        assert(!ok || initiator == address(0) || initiator == address(HELPER));
        if (ok) {
            uint256 charged = USDC.balanceOf(address(POOL)) - reserveBefore;
            assert(charged * 10_000 <= CAP_BPS * X);
            premiumsPaid += charged;
        } else {
            assert(USDC.balanceOf(address(POOL)) == reserveBefore);
        }
    }

    /// @notice The helper has no ERC-3156 minter callback: `onFlashLoan` reverts with no data.
    function noMinterCallback(
        address initiator,
        uint256 amount,
        uint256 fee
    ) external {
        (bool ok, bytes memory ret) = address(HELPER)
            .call(
                abi.encodeWithSelector(
                    bytes4(keccak256("onFlashLoan(address,address,uint256,uint256,bytes)")),
                    initiator,
                    address(USDC),
                    amount,
                    fee,
                    abi.encode(_request(0).params)
                )
            );
        assert(!ok);
        assert(ret.length == 0);
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
}
