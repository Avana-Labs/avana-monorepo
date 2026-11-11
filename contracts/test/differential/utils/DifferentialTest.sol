// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaTest} from "../../utils/AvanaTest.sol";

/// @title DifferentialTest
/// @notice Base of the FFI differential suites (`FOUNDRY_PROFILE=differential`): calls the exact Python reference
/// `test/differential/reference/avana_reference.py` on `contracts/.venv/bin/python` in isolated mode and decodes its
/// ABI-encoded answer.
abstract contract DifferentialTest is AvanaTest {
    string internal constant PYTHON = ".venv/bin/python";
    string internal constant REFERENCE = "test/differential/reference/avana_reference.py";

    /// @notice Runs `function(args...)` in the reference and returns its raw ABI-encoded result.
    function _reference(
        string memory function_,
        uint256[] memory args
    ) internal returns (bytes memory) {
        string[] memory cmd = new string[](4 + args.length);
        cmd[0] = PYTHON;
        cmd[1] = "-I";
        cmd[2] = REFERENCE;
        cmd[3] = function_;
        for (uint256 i; i < args.length; ++i) {
            cmd[4 + i] = vm.toString(args[i]);
        }
        return vm.ffi(cmd);
    }

    function _args(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 d
    ) internal pure returns (uint256[] memory out) {
        out = new uint256[](4);
        (out[0], out[1], out[2], out[3]) = (a, b, c, d);
    }
}
