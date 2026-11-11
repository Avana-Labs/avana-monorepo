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

/// @title FreezeRegistryMock
/// @notice The MarketRegistry's address freeze only: `isFrozenAddress` reads a set the test writes, counts its reads,
/// and can be told to revert.
contract FreezeRegistryMock {
    error RegistryDown();

    mapping(address => bool) public frozen;
    bool public down;

    function setFrozen(
        address account,
        bool value
    ) external {
        frozen[account] = value;
    }

    function setDown(
        bool value
    ) external {
        down = value;
    }

    function isFrozenAddress(
        address account
    ) external view returns (bool) {
        if (down) revert RegistryDown();
        return frozen[account];
    }
}

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
