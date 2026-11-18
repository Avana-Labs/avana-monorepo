// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IGsm} from "../../interfaces/external/gho/IGsm.sol";
import {IDaiUsds} from "../../interfaces/external/sky/IDaiUsds.sol";
import {ILitePsm} from "../../interfaces/external/sky/ILitePsm.sol";
import {IPegModuleRoute} from "./IPegModuleRoute.sol";
import {ISettlementRoute} from "./ISettlementRoute.sol";
import {RouteMath} from "./RouteMath.sol";
import {RouteReads} from "./RouteReads.sol";
import {SwapRouteBase} from "./SwapRouteBase.sol";
import {PegModuleKind, PegModuleStep} from "./types/PegModuleStep.sol";
import {RouteConfig} from "./types/RouteConfig.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @title PegModuleRoute
/// @notice Swap route type 0 (`PegModule`): a token into the debt asset through a GSM or the Sky LitePSM.
/// @dev The module pays LPVaultSwap directly.
contract PegModuleRoute is SwapRouteBase, IPegModuleRoute {
    uint8 internal constant ROUTE_TYPE = 0;

    PegModuleKind private immutable _KIND;

    address private immutable _MODULE;

    address private immutable _WRAPPER;

    address private immutable _INTERMEDIATE;

    /// @dev LitePSM `to18ConversionFactor`, `10^(18 − decimals(TOKEN_OUT))`; 0 for a GSM route.
    uint256 private immutable _GEM_CONVERSION;

    /// @notice Fixes the route; reverts `InvalidRouteConfig` on any failed check of the shared config or the legs.
    constructor(
        RouteConfig memory config,
        PegModuleStep memory step
    ) SwapRouteBase(config) {
        if (step.module == address(0)) revert InvalidRouteConfig();
        uint256 gemConversion = 0;
        if (step.kind == PegModuleKind.Gsm) {
            if (!_gsmLegsValid(config, step)) revert InvalidRouteConfig();
        } else {
            bool valid;
            (valid, gemConversion) = _litePsmLegs(config, step);
            if (!valid) revert InvalidRouteConfig();
        }
        // Named addresses are distinct; a GSM's static aToken is both wrapper and intermediate by design.
        address[4] memory named = [config.tokenIn, config.tokenOut, step.module, step.wrapper];
        bool clash = false;
        for (uint256 a = 0; a < named.length; ++a) {
            for (uint256 b = a + 1; b < named.length; ++b) {
                clash = clash || (named[a] == named[b] && named[a] != address(0));
            }
            clash = clash
                || (step.kind == PegModuleKind.LitePsm
                    && step.intermediate != address(0)
                    && step.intermediate == named[a]);
        }
        if (clash) revert InvalidRouteConfig();
        _GEM_CONVERSION = gemConversion;
        _KIND = step.kind;
        _MODULE = step.module;
        _WRAPPER = step.wrapper;
        _INTERMEDIATE = step.intermediate;
    }

    /// @inheritdoc ISettlementRoute
    function routeType() external pure override returns (uint8 typeId) {
        typeId = ROUTE_TYPE;
    }

    /// @inheritdoc IPegModuleRoute
    function pegModule() external view override returns (PegModuleKind kind, address module) {
        (kind, module) = (_KIND, _MODULE);
    }

    /// @inheritdoc ISettlementRoute
    /// @dev GSM: `[staticAToken, gsm]`; LitePSM with USDS input: `[converter, litePsm]`; with DAI input: `[litePsm]`.
    function dependencies() external view override returns (address[] memory contracts) {
        if (_WRAPPER == address(0)) {
            contracts = new address[](1);
            contracts[0] = _MODULE;
        } else {
            contracts = new address[](2);
            contracts[0] = _WRAPPER;
            contracts[1] = _MODULE;
        }
    }

    /// @inheritdoc ISettlementRoute
    function exactAmountInputs() external view override returns (address[] memory tokens) {
        if (_KIND == PegModuleKind.Gsm) {
            tokens = new address[](1);
            tokens[0] = _TOKEN_IN;
        } else {
            tokens = new address[](0);
        }
    }

    function _runLegs(
        uint256 amount
    ) internal override {
        if (_KIND == PegModuleKind.Gsm) {
            uint256 sharesBefore = _balance(_WRAPPER);
            _approve(_TOKEN_IN, _WRAPPER, amount);
            // Shares are measured as the route's balance rise, not taken from the return value.
            // forge-lint: disable-next-line(unused-return)
            IERC4626(_WRAPPER).deposit(amount, address(this));
            _approve(_TOKEN_IN, _WRAPPER, 0);
            uint256 shares = _rise(_WRAPPER, sharesBefore);
            // No shares: no sale, and the final check reverts `MinOutNotMet(0, minOut)`.
            if (shares != 0) {
                _approve(_WRAPPER, _MODULE, shares);
                // Output and residue are measured as balance changes, so the returned amounts are not used.
                // forge-lint: disable-next-line(unused-return)
                IGsm(_MODULE).sellAsset(shares, _LP_VAULT_SWAP);
                _approve(_WRAPPER, _MODULE, 0);
            }
        } else {
            address dai = _TOKEN_IN;
            uint256 daiAmount = amount;
            if (_WRAPPER != address(0)) {
                dai = _INTERMEDIATE;
                uint256 daiBefore = _balance(dai);
                _approve(_TOKEN_IN, _WRAPPER, amount);
                IDaiUsds(_WRAPPER).usdsToDai(address(this), amount);
                _approve(_TOKEN_IN, _WRAPPER, 0);
                daiAmount = _rise(dai, daiBefore);
            }
            uint256 gemAmt = RouteMath.litePsmGemAmt(daiAmount, ILitePsm(_MODULE).tout(), _GEM_CONVERSION);
            // No gem unit affordable (or a halted LitePSM): no call, and the final check reverts `MinOutNotMet`.
            if (gemAmt != 0) {
                _approve(dai, _MODULE, daiAmount);
                // Output and residue are measured as balance changes, so the returned cost is not used.
                // forge-lint: disable-next-line(unused-return)
                ILitePsm(_MODULE).buyGem(_LP_VAULT_SWAP, gemAmt);
                _approve(dai, _MODULE, 0);
            }
        }
    }

    function _gsmLegsValid(
        RouteConfig memory config,
        PegModuleStep memory step
    ) private view returns (bool) {
        if (step.wrapper == address(0) || step.intermediate != step.wrapper) return false;
        return _answers(step.wrapper, abi.encodeCall(IERC4626.asset, ()), config.tokenIn)
            && _answers(step.module, abi.encodeCall(IGsm.UNDERLYING_ASSET, ()), step.wrapper)
            && _answers(step.module, abi.encodeCall(IGsm.GHO_TOKEN, ()), config.tokenOut)
            && !RouteReads.hasFeeSwitch(config.tokenIn);
    }

    function _litePsmLegs(
        RouteConfig memory config,
        PegModuleStep memory step
    ) private view returns (bool valid, uint256 gemConversion) {
        if ((step.wrapper == address(0)) != (step.intermediate == address(0))) return (false, 0);
        (bool okDec, uint256[3] memory dec) =
            RouteReads.words(config.tokenOut, abi.encodeCall(IERC20Metadata.decimals, ()), false);
        if (!okDec || dec[0] > 18) return (false, 0);
        gemConversion = 10 ** (18 - dec[0]);
        address dai = step.wrapper == address(0) ? config.tokenIn : step.intermediate;
        (bool okFactor, uint256[3] memory factor) =
            RouteReads.words(step.module, abi.encodeCall(ILitePsm.to18ConversionFactor, ()), false);
        valid = okFactor && factor[0] == gemConversion
            && _answers(step.module, abi.encodeCall(ILitePsm.gem, ()), config.tokenOut)
            && _answers(step.module, abi.encodeCall(ILitePsm.dai, ()), dai);
        if (valid && step.wrapper != address(0)) {
            valid = _answers(step.wrapper, abi.encodeCall(IDaiUsds.usds, ()), config.tokenIn)
                && _answers(step.wrapper, abi.encodeCall(IDaiUsds.dai, ()), step.intermediate);
        }
    }

    function _answers(
        address target,
        bytes memory data,
        address expected
    ) private view returns (bool) {
        (bool ok, address value) = RouteReads.addressOf(target, data);
        return ok && value == expected;
    }

    function _intermediates() internal view override returns (address[] memory tokens) {
        if (_INTERMEDIATE == address(0)) {
            tokens = new address[](0);
        } else {
            tokens = new address[](1);
            tokens[0] = _INTERMEDIATE;
        }
    }
}
