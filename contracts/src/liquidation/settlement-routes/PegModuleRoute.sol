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
/// @notice Swap route type 0 (`PegModule`, 2.12): a token into the debt asset through the peg module of the pair. A GSM
/// route (Ethereum, backup slot of a GHO debt reserve only) turns USDC or USDT into GHO through the token's static
/// aToken and its GSM; a LitePSM route turns DAI, or USDS through the DAI/USDS converter, into USDC.
/// @dev GSM legs: (1) approve the static aToken for exactly the input and `deposit(amount, route)`; (2) approve the GSM
/// for exactly the shares minted and `sellAsset(shares, LP_VAULT_SWAP)`, which pays GHO to LPVaultSwap; (3) unsold
/// shares and any input the vault did not take go back to LPVaultSwap. LitePSM legs: (1) for USDS, approve the converter
/// for exactly the input and `usdsToDai(route, amount)`; (2) `gemAmt = RouteMath.litePsmGemAmt(dai, tout, c)`, approve
/// the LitePSM for exactly the DAI held and `buyGem(LP_VAULT_SWAP, gemAmt)`; (3) the DAI below one gem unit goes back
/// to LPVaultSwap. A seized or frozen GSM, a full exposure cap, a paused static aToken or a halted LitePSM makes the call
/// revert (the module reverts, or `gemAmt = 0` leaves no output and `MinOutNotMet` follows); LPVaultSwap then uses the
/// other slot. The module pays LPVaultSwap directly; `minOut` is checked on LPVaultSwap's balance delta.
/// @custom:spec REQ-ROUTE-002, REQ-ROUTE-003, REQ-ROUTE-009, REQ-ROUTE-010, REQ-ROUTE-011, REQ-ROUTE-012, REQ-ROUTE-016, REQ-ROUTE-026, REQ-ROUTE-042, Q-062, Q-084, Q-250, Q-341
contract PegModuleRoute is SwapRouteBase, IPegModuleRoute {
    /// @notice Route type of `PegModule`.
    uint8 internal constant ROUTE_TYPE = 0;

    /// @dev Peg module kind.
    PegModuleKind private immutable _KIND;

    /// @dev The GSM or the LitePSM.
    address private immutable _MODULE;

    /// @dev The static aToken (GSM) or the DAI/USDS converter (USDS input); zero for a LitePSM route with DAI input.
    address private immutable _WRAPPER;

    /// @dev Token held between legs: the static aToken (GSM) or DAI (USDS input); zero for DAI input.
    address private immutable _INTERMEDIATE;

    /// @dev LitePSM `to18ConversionFactor`, `10^(18 − decimals(TOKEN_OUT))`; 0 for a GSM route.
    uint256 private immutable _GEM_CONVERSION;

    /// @notice Fixes the route; reverts `InvalidRouteConfig` on any failed check of `SwapRouteBase` or of the legs
    /// (`PegModuleStep`): for a GSM route, the static aToken's `asset()` is the input token, the GSM's
    /// `UNDERLYING_ASSET()` is the static aToken and its `GHO_TOKEN()` the output token, and the input has no
    /// transfer-fee switch (the static aToken supplies the amount it pulled to the Aave Pool, so a fee would revert the
    /// deposit); for a LitePSM route, the LitePSM's `gem()` is the output token, its `dai()` is the DAI the route spends
    /// (the input, or the intermediate after the converter), its `to18ConversionFactor()` is `10^(18 − decimals)`, and a
    /// converter's `usds()` and `dai()` are the input and the intermediate. A contract that does not answer a read fails
    /// the check.
    /// @param config Shared constructor arguments.
    /// @param step The peg-module legs.
    /// @custom:spec REQ-ROUTE-008, REQ-ROUTE-011, REQ-ROUTE-012, REQ-ROUTE-045
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
        // The tokens, the module and the wrapper are distinct; a LitePSM route's DAI differs from all of them (a GSM's
        // static aToken is both the wrapper and the intermediate by design).
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
    /// @custom:spec REQ-ROUTE-002, REQ-ROUTE-005
    function routeType() external pure override returns (uint8 typeId) {
        typeId = ROUTE_TYPE;
    }

    /// @inheritdoc IPegModuleRoute
    /// @custom:spec REQ-ROUTE-002, REQ-ROUTE-005, Q-341
    function pegModule() external view override returns (PegModuleKind kind, address module) {
        (kind, module) = (_KIND, _MODULE);
    }

    /// @inheritdoc ISettlementRoute
    /// @dev GSM: `[staticAToken, gsm]`; LitePSM with USDS input: `[converter, litePsm]`; with DAI input: `[litePsm]`.
    /// @custom:spec REQ-ROUTE-003, REQ-ROUTE-005
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
    /// @dev A GSM route's input, which the static aToken pulls and supplies to the Aave Pool in full; none for a
    /// LitePSM route (DAI and USDS have no transfer-fee switch, and the converter and the LitePSM pull what they pay for).
    /// @custom:spec REQ-ROUTE-003, REQ-ROUTE-005, REQ-ROUTE-008
    function exactAmountInputs() external view override returns (address[] memory tokens) {
        if (_KIND == PegModuleKind.Gsm) {
            tokens = new address[](1);
            tokens[0] = _TOKEN_IN;
        } else {
            tokens = new address[](0);
        }
    }

    /// @custom:spec REQ-ROUTE-008, REQ-ROUTE-010, REQ-ROUTE-011, REQ-ROUTE-012
    function _runLegs(
        uint256 amount
    ) internal override {
        if (_KIND == PegModuleKind.Gsm) {
            uint256 sharesBefore = _balance(_WRAPPER);
            _approve(_TOKEN_IN, _WRAPPER, amount);
            // Shares are measured as the route's balance rise, never taken from the vault's return value (REQ-ROUTE-011,
            // REQ-ROUTE-015).
            // forge-lint: disable-next-line(unused-return)
            IERC4626(_WRAPPER).deposit(amount, address(this));
            _approve(_TOKEN_IN, _WRAPPER, 0);
            uint256 shares = _rise(_WRAPPER, sharesBefore);
            // No shares: no sale, and the final check reverts `MinOutNotMet(0, minOut)`.
            if (shares != 0) {
                _approve(_WRAPPER, _MODULE, shares);
                // The GHO output is LPVaultSwap's measured balance rise and unsold shares are the route's measured
                // residue (REQ-ROUTE-009, REQ-ROUTE-011), so the GSM's returned amounts are not used.
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
            // No gem unit affordable (or a halted LitePSM): no call, and the final check reverts `MinOutNotMet(0, minOut)`
            // (REQ-ROUTE-012).
            if (gemAmt != 0) {
                _approve(dai, _MODULE, daiAmount);
                // The USDC output is LPVaultSwap's measured balance rise and unspent DAI is the route's measured residue
                // (REQ-ROUTE-009, REQ-ROUTE-015), so the DAI cost the LitePSM returns is not used.
                // forge-lint: disable-next-line(unused-return)
                ILitePsm(_MODULE).buyGem(_LP_VAULT_SWAP, gemAmt);
                _approve(dai, _MODULE, 0);
            }
        }
    }

    /// @notice The GSM checks of the constructor: the static aToken wraps the input, the GSM sells that static aToken
    /// for the output token, and the input has no transfer-fee switch (REQ-ROUTE-008, REQ-ROUTE-011, REQ-ROUTE-045).
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

    /// @notice The LitePSM checks of the constructor: the converter and DAI named together or neither, the output's
    /// decimals at most 18, the LitePSM's gem, DAI and conversion factor, and the converter's tokens (REQ-ROUTE-012,
    /// REQ-ROUTE-045).
    /// @return valid Every check passed.
    /// @return gemConversion `10^(18 − decimals(TOKEN_OUT))`, used only when `valid` is true.
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

    /// @notice Whether `target` answers the address read `data` with `expected`.
    function _answers(
        address target,
        bytes memory data,
        address expected
    ) private view returns (bool) {
        (bool ok, address value) = RouteReads.addressOf(target, data);
        return ok && value == expected;
    }

    /// @custom:spec REQ-ROUTE-003
    function _intermediates() internal view override returns (address[] memory tokens) {
        if (_INTERMEDIATE == address(0)) {
            tokens = new address[](0);
        } else {
            tokens = new address[](1);
            tokens[0] = _INTERMEDIATE;
        }
    }
}
