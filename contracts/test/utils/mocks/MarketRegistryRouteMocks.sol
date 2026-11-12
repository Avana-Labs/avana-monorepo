// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IGsm} from "../../../src/interfaces/external/gho/IGsm.sol";
import {IERC1820Registry} from "@openzeppelin/contracts/interfaces/IERC1820Registry.sol";

/// @notice Answers one view with a raw word, or with a revert or an answer of the wrong length.
abstract contract RawAnswer {
    /// @dev 0 a normal answer, 1 revert, 2 one byte short, 3 one word too long (the first word still the answer).
    uint8 internal constant NORMAL = 0;
    uint8 internal constant REVERTS = 1;
    uint8 internal constant SHORT = 2;
    uint8 internal constant LONG = 3;

    function _answer(
        uint8 mode,
        uint256 word
    ) internal pure {
        if (mode == REVERTS) revert("read");
        uint256 size = mode == SHORT ? 31 : mode == LONG ? 64 : 32;
        assembly {
            mstore(0x00, word)
            mstore(0x20, 0)
            return(0x00, size)
        }
    }
}

/// @title RegistryGsmMock
/// @notice A GHO Stability Module as the MarketRegistry's GSM health check reads it (Q-341): `getIsSeized`,
/// `getIsFrozen` and `getExposureCap`, each a settable raw word with its own answer mode.
contract RegistryGsmMock is RawAnswer {
    uint256 public seizedWord;
    uint256 public frozenWord;
    uint256 public capWord = 1e24;
    mapping(bytes4 selector => uint8 mode) public modeOf;

    function setSeized(
        uint256 w
    ) external {
        seizedWord = w;
    }

    function setFrozen(
        uint256 w
    ) external {
        frozenWord = w;
    }

    function setCap(
        uint256 w
    ) external {
        capWord = w;
    }

    function setMode(
        bytes4 selector,
        uint8 mode
    ) external {
        modeOf[selector] = mode;
    }

    fallback() external {
        bytes4 sel = msg.sig;
        uint256 word;
        if (sel == IGsm.getIsSeized.selector) {
            word = seizedWord;
        } else if (sel == IGsm.getIsFrozen.selector) {
            word = frozenWord;
        } else if (sel == IGsm.getExposureCap.selector) {
            word = capWord;
        } else {
            revert("unknown");
        }
        _answer(modeOf[sel], word);
    }
}

/// @title RegistryErc1820Mock
/// @notice The ERC-1820 registry's `getInterfaceImplementer`, etched at the canonical address: an implementer per
/// (account, interface hash), and one answer mode for every read.
contract RegistryErc1820Mock is RawAnswer {
    mapping(address account => mapping(bytes32 interfaceHash => uint256 implementer)) public implementerWord;
    uint8 public mode;

    function setImplementer(
        address account,
        bytes32 interfaceHash,
        uint256 implementer
    ) external {
        implementerWord[account][interfaceHash] = implementer;
    }

    function setMode(
        uint8 m
    ) external {
        mode = m;
    }

    fallback() external {
        if (msg.sig != IERC1820Registry.getInterfaceImplementer.selector) revert("unknown");
        (address account, bytes32 interfaceHash) = abi.decode(msg.data[4:], (address, bytes32));
        _answer(mode, implementerWord[account][interfaceHash]);
    }
}
