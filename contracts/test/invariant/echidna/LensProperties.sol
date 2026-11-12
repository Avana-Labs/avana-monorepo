// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ILensAccount} from "../../../src/lens/lens/ILensAccount.sol";
import {ILensLiquidation} from "../../../src/lens/lens/ILensLiquidation.sol";
import {ILensMarket} from "../../../src/lens/lens/ILensMarket.sol";
import {ILensPreview} from "../../../src/lens/lens/ILensPreview.sol";
import {ILensRisk} from "../../../src/lens/lens/ILensRisk.sol";
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
        address[8] memory m;
        address[8] memory r;
        for (uint256 i = 0; i < 8; ++i) {
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
        address[8] memory m = LENS.MODULES();
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
}
