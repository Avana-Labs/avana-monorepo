// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {LPVaultSwapSettlement} from "../../../src/liquidation/lp-vault-swap/LPVaultSwapSettlement.sol";
import {LPVaultSwapStorage} from "../../../src/liquidation/lp-vault-swap/LPVaultSwapStorage.sol";
import {LPVaultSwapImmutables} from "../../../src/liquidation/lp-vault-swap/types/LPVaultSwapImmutables.sol";
import {RouteMode} from "../../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal mintable token of the settlement harness.
contract LVSHarnessToken is ERC20 {
    uint8 internal immutable _DECIMALS;

    constructor(
        string memory name_,
        uint8 decimals_
    ) ERC20(name_, name_) {
        _DECIMALS = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _DECIMALS;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @notice A route of the settlement harness: pulls `takeBps` of `amountIn` of its input token and pays `amountIn × num
/// / den` of its output token (minted), reverting below `minOut`; it can be set to revert in `swap` or in
/// `intermediates()`, to name an intermediate token and to send `leftover` of it back to its caller; records every call.
contract LVSHarnessRoute {
    LVSHarnessToken public immutable tokenIn;
    LVSHarnessToken public immutable tokenOut;
    uint256 public num;
    uint256 public den;
    uint256 public calls;
    uint256 public lastMinOut;
    uint256 public lastAmountIn;
    uint256 public takeBps = 10_000;
    bool public reverts;
    bool public intermediatesReverts;
    LVSHarnessToken public intermediate;
    uint256 public leftover;

    constructor(
        LVSHarnessToken tokenIn_,
        LVSHarnessToken tokenOut_,
        uint256 num_,
        uint256 den_
    ) {
        (tokenIn, tokenOut, num, den) = (tokenIn_, tokenOut_, num_, den_);
    }

    function setRate(
        uint256 num_,
        uint256 den_
    ) external {
        (num, den) = (num_, den_);
    }

    function setBehaviour(
        uint256 takeBps_,
        bool reverts_,
        bool intermediatesReverts_
    ) external {
        (takeBps, reverts, intermediatesReverts) = (takeBps_, reverts_, intermediatesReverts_);
    }

    function setIntermediate(
        LVSHarnessToken token,
        uint256 leftover_
    ) external {
        (intermediate, leftover) = (token, leftover_);
    }

    function intermediates() external view returns (address[] memory list) {
        require(!intermediatesReverts, "IntermediatesDown");
        if (address(intermediate) == address(0)) return new address[](0);
        list = new address[](1);
        list[0] = address(intermediate);
    }

    function swap(
        uint256 amountIn,
        uint256 minOut
    ) external returns (uint256 out) {
        require(!reverts, "RouteDown");
        ++calls;
        (lastMinOut, lastAmountIn) = (minOut, amountIn);
        tokenIn.transferFrom(msg.sender, address(this), amountIn * takeBps / 10_000);
        out = amountIn * num / den;
        require(out >= minOut, "MinOutNotMet");
        tokenOut.mint(msg.sender, out);
        if (leftover != 0) intermediate.mint(msg.sender, leftover);
    }
}

/// @notice Registry of the settlement harness: a primary (kind 0) and a backup (kind 1) route per (token, debt asset),
/// each usable unless switched off.
contract LVSHarnessRegistry {
    mapping(address token => mapping(address asset => mapping(uint8 kind => address route))) public routeOf;
    mapping(address token => mapping(address asset => mapping(uint8 kind => bool off))) public disabled;

    function setRoute(
        address token,
        address asset,
        address route
    ) external {
        routeOf[token][asset][0] = route;
    }

    function setBackup(
        address token,
        address asset,
        address route
    ) external {
        routeOf[token][asset][1] = route;
    }

    function setUsable(
        address token,
        address asset,
        uint8 kind,
        bool usable
    ) external {
        disabled[token][asset][kind] = !usable;
    }

    function getRoute(
        uint256,
        address token,
        address asset,
        uint8 kind
    ) external view returns (address route, bool usable) {
        route = routeOf[token][asset][kind];
        usable = route != address(0) && !disabled[token][asset][kind];
    }
}

/// @title LPVaultSwapSettlementHarness
/// @notice Exposes LPVaultSwap's shared swap-leg step (`_snapshot`, `_swapLegs`, `_residues`) on its own address, for
/// the Halmos and Echidna checks of PROP-059 and SPEC-LIQ-018: a released token that is the debt asset is never routed,
/// every route call is into the debt asset at its oracle-derived minimum, and no leg buys one asset with another.
contract LPVaultSwapSettlementHarness is LPVaultSwapSettlement {
    constructor(
        LPVaultSwapImmutables memory im
    ) LPVaultSwapStorage(im) {}

    /// @notice One leg step's inputs.
    struct HarnessLegs {
        address asset;
        uint8 assetDecimals;
        address[] tokens;
        uint8[] decimals;
        uint256[] prices;
        uint256[] amounts;
        uint256 sLeg;
        uint256 allowance;
    }

    /// @notice Runs the legs of a released `amounts` vector into `asset` at `sLeg`, `PrimaryThenBackup`, and returns
    /// the routes used and `R` (the rise of the harness's `asset` balance).
    function swapLegs(
        address asset,
        uint8 assetDecimals,
        address[] memory tokens,
        uint8[] memory decimals,
        uint256[] memory prices,
        uint256[] memory amounts,
        uint256 sLeg,
        uint256 allowance
    ) external returns (uint8[] memory used, uint256 recovered, uint256[] memory residues) {
        return swapLegsIn(
            RouteMode.PrimaryThenBackup,
            HarnessLegs(asset, assetDecimals, tokens, decimals, prices, amounts, sLeg, allowance)
        );
    }

    /// @notice `swapLegs` in route mode `mode`. The amounts were minted to the harness before the call: they are the
    /// release, so the snapshot starts below them and a released debt-asset leg counts in `R`.
    function swapLegsIn(
        RouteMode mode,
        HarnessLegs memory h
    ) public returns (uint8[] memory used, uint256 recovered, uint256[] memory residues) {
        Tracked memory t = _snapshot(h.tokens, h.asset);
        uint256 before = ERC20(h.asset).balanceOf(address(this));
        for (uint256 i = 0; i < h.tokens.length; ++i) {
            t.start[i] -= h.amounts[i];
            if (h.tokens[i] == h.asset) before -= h.amounts[i];
        }
        used = _swapLegs(
            LegArgs({
                marketId: 1,
                asset: h.asset,
                assetDecimals: h.assetDecimals,
                assetPrice: 1e8,
                sLeg: h.sLeg,
                allowance: h.allowance,
                mode: mode,
                tokens: h.tokens,
                decimals: h.decimals,
                prices: h.prices,
                amounts: h.amounts
            }),
            t
        );
        recovered = ERC20(h.asset).balanceOf(address(this)) - before;
        residues = _residues(t);
    }
}
