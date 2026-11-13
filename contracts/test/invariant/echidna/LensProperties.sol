// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILensAccount} from "../../../src/lens/lens/ILensAccount.sol";
import {ILensActions} from "../../../src/lens/lens/ILensActions.sol";
import {ILensFees} from "../../../src/lens/lens/ILensFees.sol";
import {ILensHubAssets} from "../../../src/lens/lens/ILensHubAssets.sol";
import {ILensLiquidation} from "../../../src/lens/lens/ILensLiquidation.sol";
import {ILensMarket} from "../../../src/lens/lens/ILensMarket.sol";
import {ILensPreview} from "../../../src/lens/lens/ILensPreview.sol";
import {ILensRisk} from "../../../src/lens/lens/ILensRisk.sol";
import {ILensSizing} from "../../../src/lens/lens/ILensSizing.sol";
import {ILensSpeed} from "../../../src/lens/lens/ILensSpeed.sol";
import {Lens} from "../../../src/lens/lens/Lens.sol";
import {LensConstants} from "../../../src/lens/lens/LensConstants.sol";

/// @notice A Lens module stand-in: reports the nine core addresses 1 to 9 and answers every other call with its own
/// index and the calldata hash, or reverts with them when told to.
contract LensModuleStub {
    uint256 internal immutable _ID;
    bool internal immutable _REVERTS;

    constructor(
        uint256 id,
        bool reverts
    ) {
        (_ID, _REVERTS) = (id, reverts);
    }

    function COLLATERALIZATION() external pure returns (address) {
        return address(1);
    }

    function PROXY_MANAGER() external pure returns (address) {
        return address(2);
    }

    function ADAPTER() external pure returns (address) {
        return address(3);
    }

    function LOCK() external pure returns (address) {
        return address(4);
    }

    function MARKET_REGISTRY() external pure returns (address) {
        return address(5);
    }

    function PARAMETER_STORE() external pure returns (address) {
        return address(6);
    }

    function RISK_MODULE() external pure returns (address) {
        return address(7);
    }

    function LP_VAULT_SWAP() external pure returns (address) {
        return address(8);
    }

    function PAYOUT_ESCROW() external pure returns (address) {
        return address(9);
    }

    fallback(
        bytes calldata data
    ) external returns (bytes memory) {
        bytes memory answer = abi.encode(_ID, keccak256(data));
        if (_REVERTS) {
            assembly ("memory-safe") {
                revert(add(answer, 0x20), mload(answer))
            }
        }
        return answer;
    }
}

/// @title LensProperties
/// @notice The Lens entry point's routing: every view reaches exactly the module of its interface piece with the
/// caller's calldata unchanged, the module's answer or revert data comes back unchanged, and the entry point holds no
/// state.
contract LensProperties {
    Lens internal immutable LENS;
    Lens internal immutable REVERTING;

    constructor() {
        address[9] memory m;
        address[9] memory r;
        for (uint256 i = 0; i < 9; ++i) {
            m[i] = address(new LensModuleStub(i, false));
            r[i] = address(new LensModuleStub(i, true));
        }
        LENS = new Lens(m);
        REVERTING = new Lens(r);
    }

    /// @notice The constants keep their spec values.
    function property_constants() external pure returns (bool) {
        return LensConstants.LENS_MAX_PAGE == 200 && LensConstants.LENS_DUST_MARGIN_BPS == 500
            && LensConstants.BORROW_MAX_MARGIN_BPS == 50 && LensConstants.REPAY_ALL_MARGIN_BPS == 10
            && LensConstants.RECOMMENDED_HEALTH_FACTOR == 1.1e18;
    }

    /// @notice The entry point reports the modules' core addresses and the modules in order.
    function property_coreAndModules() external view returns (bool) {
        address[9] memory m = LENS.MODULES();
        return LENS.COLLATERALIZATION() == address(1) && LENS.ADAPTER() == address(3)
            && LENS.PAYOUT_ESCROW() == address(9) && m[0] != m[5] && m[0] != address(0);
    }

    /// @notice Routing: view `which` (one of six representatives, one per module) with argument `x` answers from the
    /// expected module with the calldata unchanged, and a reverting module's data comes back unchanged.
    function checkRoute(
        uint8 which,
        uint256 x
    ) external view {
        bytes memory data;
        uint256 expected;
        if (which % 6 == 0) {
            (data, expected) = (abi.encodeCall(ILensAccount.getAccount, (address(uint160(x)), x)), 0);
        } else if (which % 6 == 1) {
            (data, expected) = (abi.encodeCall(ILensMarket.checkBacking, (address(uint160(x)))), 1);
        } else if (which % 6 == 2) {
            (data, expected) = (abi.encodeCall(ILensLiquidation.getPriceState, (address(uint160(x)))), 2);
        } else if (which % 6 == 3) {
            (data, expected) = (abi.encodeCall(ILensLiquidation.previewLiquidation, (address(uint160(x)), x, x)), 3);
        } else if (which % 6 == 4) {
            (data, expected) = (abi.encodeCall(ILensRisk.getBreakerStatus, (x)), 4);
        } else {
            (data, expected) = (abi.encodeCall(ILensPreview.quoteRepayAll, (address(uint160(x)), x, x, x)), 5);
        }
        (bool ok, bytes memory ret) = address(LENS).staticcall(data);
        assert(ok);
        assert(keccak256(ret) == keccak256(abi.encode(expected, keccak256(data))));
        (ok, ret) = address(REVERTING).staticcall(data);
        assert(!ok);
        assert(keccak256(ret) == keccak256(abi.encode(expected, keccak256(data))));
    }

    /// @notice Routing of the views added for the app pages: fees to `LensMarketsModule`, after-action previews and the
    /// removal sizing to `LensPositionsModule`, the deleverage sizing to `LensPriceModule`, the close-account preview to
    /// `LensAccountModule`, the Hub-asset view to `LensRiskModule` and the speed views to `LensSpeedModule`, with the
    /// calldata and the answer unchanged.
    function checkRouteAdded(
        uint8 which,
        uint256 x
    ) external view {
        address a = address(uint160(x));
        bytes memory data;
        uint256 expected;
        uint8 w = which % 8;
        if (w == 0) {
            (data, expected) = (abi.encodeCall(ILensFees.getPositionFees, (x, bytes32(x))), 6);
        } else if (w == 1) {
            (data, expected) = (abi.encodeCall(ILensActions.previewBorrowAfter, (a, x, x, x)), 7);
        } else if (w == 2) {
            (data, expected) = (abi.encodeCall(ILensSizing.previewMaxWithdraw, (a, x, x)), 7);
        } else if (w == 3) {
            (data, expected) = (abi.encodeCall(ILensSizing.previewDeleverageTo, (a, x, bytes32(x), x, x)), 2);
        } else if (w == 4) {
            (data, expected) = (abi.encodeCall(ILensSizing.previewCloseAccount, (a, x, x)), 0);
        } else if (w == 5) {
            (data, expected) = (abi.encodeCall(ILensHubAssets.getHubAsset, (a, x)), 4);
        } else if (w == 6) {
            (data, expected) = (abi.encodeCall(ILensSpeed.getBorrowSpeed, (x, x)), 8);
        } else {
            (data, expected) = (abi.encodeCall(ILensSpeed.getPledgeSpeed, (x)), 8);
        }
        (bool ok, bytes memory ret) = address(LENS).staticcall(data);
        assert(ok);
        assert(keccak256(ret) == keccak256(abi.encode(expected, keccak256(data))));
        (ok, ret) = address(REVERTING).staticcall(data);
        assert(!ok);
        assert(keccak256(ret) == keccak256(abi.encode(expected, keccak256(data))));
    }
}
