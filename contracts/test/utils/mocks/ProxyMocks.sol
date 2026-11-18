// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IPositionProxy} from "../../../src/proxy/position-proxy/IPositionProxy.sol";
import {IProxyManager} from "../../../src/proxy/proxy-manager/IProxyManager.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title ProxyCallTarget
/// @notice Callee for `PositionProxy.execute`: records who called it, with what value and calldata, returns data the
/// test chose, and reverts with a custom error, a string, raw bytes or no data.
contract ProxyCallTarget {
    error TargetError(uint256 code);

    address public lastCaller;
    uint256 public lastValue;
    bytes public lastData;
    uint256 public calls;

    function ping(
        uint256 x
    ) external returns (uint256) {
        _record();
        return x + 1;
    }

    function echo(
        bytes calldata payload
    ) external returns (bytes memory) {
        _record();
        return payload;
    }

    function failWithError(
        uint256 code
    ) external pure {
        revert TargetError(code);
    }

    function failWithString() external pure {
        revert("target refused");
    }

    function failWithRaw(
        bytes calldata raw
    ) external pure {
        bytes memory data = raw;
        assembly ("memory-safe") {
            revert(add(data, 32), mload(data))
        }
    }

    function failEmpty() external pure {
        revert();
    }

    fallback() external {
        _record();
    }

    function _record() internal {
        lastCaller = msg.sender;
        lastValue = msg.value;
        lastData = msg.data;
        ++calls;
    }
}

/// @title ProxyPingTarget
/// @notice A lean callee for the symbolic PositionProxy harness: `ping` records only the caller, the value and the call
/// count, and two functions revert with a custom error or no data.
/// @dev `ProxyCallTarget` also stores the whole calldata in a `bytes` slot; with a symbolic argument hevm carried that
/// symbolic write through the proxy's return path and reached the CI job's 14 GB memory cap (security-slow run
/// 43653574421). The harness checks none of that calldata, so this target leaves it out.
contract ProxyPingTarget {
    error TargetError(uint256 code);

    address public lastCaller;
    uint256 public lastValue;
    uint256 public calls;

    function ping(
        uint256 x
    ) external payable returns (uint256) {
        lastCaller = msg.sender;
        lastValue = msg.value;
        ++calls;
        return x + 1;
    }

    function failWithError(
        uint256 code
    ) external pure {
        revert TargetError(code);
    }

    function failEmpty() external pure {
        revert();
    }
}

/// @title ProxyReentrantTarget
/// @notice Callee that calls back into the proxy that called it, as a hostile Spoke or token would.
contract ProxyReentrantTarget {
    function reenter(
        address target,
        bytes calldata data
    ) external returns (bytes memory) {
        return IPositionProxy(msg.sender).execute(target, data);
    }
}

/// @title StubRegistryMock
/// @notice A MarketRegistry address with code for the ProxyManager's `MARKET_REGISTRY` immutable; the ProxyManager
/// reads nothing from it.
contract StubRegistryMock {}

/// @title ProxyTestToken
/// @notice Plain 18-decimal ERC-20 with an open mint, for the vault-token and debt-asset calls a proxy makes.
contract ProxyTestToken is ERC20 {
    constructor() ERC20("Proxy Test Token", "PTT") {}

    function mint(
        address to,
        uint256 amount
    ) external {
        _mint(to, amount);
    }
}

/// @title TokenPuller
/// @notice Stands in for the Spoke's `supply` and `repay`: pulls an approved amount from the caller.
contract TokenPuller {
    function pull(
        ERC20 token,
        uint256 amount
    ) external returns (uint256) {
        bool ok = token.transferFrom(msg.sender, address(this), amount);
        require(ok, "pull failed");
        return amount;
    }
}

/// @title ProxyCaller
/// @notice A caller that is not the Adapter: forwards `execute` and `deployProxy` and returns the outcome instead of
/// reverting, for the property harnesses.
contract ProxyCaller {
    function callExecute(
        address proxy,
        address target,
        bytes calldata data
    ) external returns (bool ok, bytes memory ret) {
        (ok, ret) = proxy.call(abi.encodeCall(IPositionProxy.execute, (target, data)));
    }

    function callDeploy(
        address manager,
        address wallet,
        address spoke,
        uint256 marketId
    ) external returns (bool ok, bytes memory ret) {
        (ok, ret) = manager.call(abi.encodeCall(IProxyManager.deployProxy, (wallet, spoke, marketId)));
    }
}
