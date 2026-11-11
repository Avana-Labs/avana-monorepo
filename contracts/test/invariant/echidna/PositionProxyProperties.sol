// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPositionProxy} from "../../../src/proxy/position-proxy/IPositionProxy.sol";
import {PositionProxy} from "../../../src/proxy/position-proxy/PositionProxy.sol";
import {ProxyCallTarget, ProxyCaller} from "../../utils/mocks/ProxyMocks.sol";

/// @title PositionProxyProperties
/// @notice Echidna and Medusa properties of the PositionProxy (2.5). Between transactions its binding and code never
/// change and it holds no ETH. Inside one transaction the Adapter (this harness) makes it call the named target as
/// itself with no ETH; every other caller is refused with `OnlyAdapter`; invalid targets are refused with
/// `InvalidTarget`; revert data passes through, an empty revert becomes `CallFailed`.
/// @dev The harness is the proxy's `ADAPTER`. `adapterCall`, `outsiderCall`, `invalidTarget` and `revertPassthrough`
/// are assertion entry points with finite branching for hevm.
contract PositionProxyProperties {
    address internal constant WALLET = address(0xCA201);
    address internal constant SPOKE = address(0x5B0CE);
    address internal constant CODELESS = address(0xC0DE1E55);
    uint256 internal constant MARKET_ID = 3;

    PositionProxy internal immutable PROXY;
    ProxyCallTarget internal immutable TARGET;
    ProxyCaller internal immutable OUTSIDER;
    bytes32 internal immutable CODE_HASH;

    /// @notice Number of assertion sequences run; written so each call is a transaction.
    uint256 public sequences;

    constructor() {
        PROXY = new PositionProxy(address(this), WALLET, SPOKE, MARKET_ID);
        TARGET = new ProxyCallTarget();
        OUTSIDER = new ProxyCaller();
        CODE_HASH = address(PROXY).codehash;
    }

    // ─── Properties (between transactions) ───

    function property_bindingFixed() external view returns (bool) {
        return PROXY.ADAPTER() == address(this) && PROXY.WALLET() == WALLET && PROXY.SPOKE() == SPOKE
            && PROXY.MARKET_ID() == MARKET_ID;
    }

    function property_codeNeverChanges() external view returns (bool) {
        return address(PROXY).codehash == CODE_HASH;
    }

    function property_holdsNoEth() external view returns (bool) {
        return address(PROXY).balance == 0;
    }

    // ─── Assertion entry points (inside one transaction) ───

    /// @notice The Adapter's call reaches the target as the proxy with no ETH, and the return data comes back.
    function adapterCall(
        uint128 x
    ) external {
        uint256 before = TARGET.calls();
        bytes memory result = PROXY.execute(address(TARGET), abi.encodeCall(ProxyCallTarget.ping, (x)));
        assert(abi.decode(result, (uint256)) == uint256(x) + 1);
        assert(TARGET.lastCaller() == address(PROXY));
        assert(TARGET.lastValue() == 0);
        assert(TARGET.calls() == before + 1);
        ++sequences;
    }

    /// @notice Any other caller is refused with `OnlyAdapter` and the target sees nothing.
    function outsiderCall(
        uint128 x
    ) external {
        uint256 before = TARGET.calls();
        (bool ok, bytes memory ret) =
            OUTSIDER.callExecute(address(PROXY), address(TARGET), abi.encodeCall(ProxyCallTarget.ping, (x)));
        assert(!ok);
        assert(keccak256(ret) == keccak256(abi.encodeWithSelector(IPositionProxy.OnlyAdapter.selector)));
        assert(TARGET.calls() == before);
        ++sequences;
    }

    /// @notice The proxy itself, the zero address and a codeless address are refused with `InvalidTarget(target)`.
    function invalidTarget(
        uint8 which
    ) external {
        address to = CODELESS;
        if (which % 3 == 0) {
            to = address(PROXY);
        } else if (which % 3 == 1) {
            to = address(0);
        }
        try PROXY.execute(to, "") {
            assert(false);
        } catch (bytes memory reason) {
            assert(keccak256(reason) == keccak256(abi.encodeWithSelector(IPositionProxy.InvalidTarget.selector, to)));
        }
        ++sequences;
    }

    /// @notice A revert with data passes through unchanged; an empty revert becomes `CallFailed(target)`.
    function revertPassthrough(
        uint256 code,
        bool empty
    ) external {
        bytes memory data = empty
            ? abi.encodeCall(ProxyCallTarget.failEmpty, ())
            : abi.encodeCall(ProxyCallTarget.failWithError, (code));
        bytes memory expected = empty
            ? abi.encodeWithSelector(IPositionProxy.CallFailed.selector, address(TARGET))
            : abi.encodeWithSelector(ProxyCallTarget.TargetError.selector, code);
        try PROXY.execute(address(TARGET), data) {
            assert(false);
        } catch (bytes memory reason) {
            assert(keccak256(reason) == keccak256(expected));
        }
        ++sequences;
    }
}
