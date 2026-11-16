// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DeployBase} from "./DeployBase.sol";

interface IOCR2Admin {
    function setConfig(
        address[] memory signers,
        address[] memory transmitters,
        uint8 f,
        bytes memory onchainConfig,
        uint64 offchainConfigVersion,
        bytes memory offchainConfig
    ) external;
    function latestConfigDetails() external view returns (uint32 configCount, uint32 blockNumber, bytes32 configDigest);
    function transmit(
        bytes32[3] calldata reportContext,
        bytes calldata report,
        bytes32[] calldata rs,
        bytes32[] calldata ss,
        bytes32 rawVs
    ) external;
    function addAccess(
        address user
    ) external;
}

/// @title WorldFeeds
/// @notice Chainlink price feeds on a test network, from Chainlink's own code: an `AccessControlledOCR2Aggregator`
/// (libocr 199a6f1, contract2/) behind an `EACAggregatorProxy` (chainlink v2.10.0, contracts/src/v0.6), one per feed,
/// each configured with four local oracles (f = 1) and seeded with a first report the oracles sign. Prices move only by
/// signed OCR2 reports (`transmit`), so round IDs, `updatedAt` and staleness behave as on a live feed.
/// @dev The four oracles are the addresses in `AVANA_OCR_ORACLES` (comma-separated); each is its own signer and
/// transmitter. No key enters the script: the reports are signed with `vm.sign(oracle, digest)` and sent with
/// `vm.broadcast(oracle)` by the encrypted Foundry keystores the run loads (`--keystore`, `--password-file`). On anvil
/// `script/deploy/step.sh` adds them from `AVANA_OCR_KEYSTORE_DIR`, which `script/e2e/e2e-local.sh` generates for each
/// fresh deployment; elsewhere they are part of `AVANA_SIGNER_FLAGS`. The aggregator's read access is granted to its
/// proxy only, as on a live feed. `script/e2e/scenarios/ocr2.ts` transmits later reports with the same keystores.
abstract contract WorldFeeds is DeployBase {
    string internal constant OCR_OUT = "out-chainlink-ocr2";
    string internal constant PROXY_OUT = "out-chainlink-proxy";
    uint8 internal constant OCR_F = 1;
    uint256 internal constant OCR_ORACLES = 4;

    address[] internal ocrOracles;
    address internal linkToken;
    uint40 internal epochAndRound;

    /// @notice Oracle addresses; funds the transmitters with gas on anvil.
    function _ocrSetup(
        string memory network,
        address link
    ) internal {
        bool local = _isLocalChain(block.chainid);
        ocrOracles = vm.envAddress("AVANA_OCR_ORACLES", ",");
        require(ocrOracles.length == OCR_ORACLES, "AVANA_OCR_ORACLES must name four oracles");
        for (uint256 i = 0; i < OCR_ORACLES; ++i) {
            if (local) {
                string memory method = "anvil_setBalance";
                vm.rpc(method, string.concat('["', vm.toString(ocrOracles[i]), '","0x3635C9ADC5DEA00000"]'));
            }
        }
        linkToken = link;
    }

    /// @notice One feed: the aggregator, its oracle configuration, the proxy, and a first signed report at `answer`.
    function _deployFeed(
        string memory description,
        int256 answer,
        int192 minAnswer,
        int192 maxAnswer
    ) internal returns (address proxy, address aggregator) {
        aggregator = _deploy(
            string.concat("OCR2Aggregator ", description),
            bytes.concat(
                _artifactIn(OCR_OUT, "AccessControlledOCR2Aggregator.sol", "AccessControlledOCR2Aggregator"),
                abi.encode(linkToken, minAnswer, maxAnswer, address(0), address(0), uint8(8), description)
            )
        );
        IOCR2Admin(aggregator)
            .setConfig(ocrOracles, ocrOracles, OCR_F, abi.encodePacked(uint8(1), minAnswer, maxAnswer), 1, "");
        proxy = _deploy(
            string.concat("EACAggregatorProxy ", description),
            bytes.concat(
                _artifactIn(PROXY_OUT, "EACAggregatorProxy.sol", "EACAggregatorProxy"),
                abi.encode(aggregator, address(0))
            )
        );
        IOCR2Admin(aggregator).addAccess(proxy);
        _transmit(aggregator, answer);
    }

    /// @notice A report whose three observations all equal `answer`, signed by f + 1 oracles and sent by oracle 0.
    function _transmit(
        address aggregator,
        int256 answer
    ) internal {
        (,, bytes32 digest) = IOCR2Admin(aggregator).latestConfigDetails();
        int192[] memory obs = new int192[](3);
        (obs[0], obs[1], obs[2]) = (int192(answer), int192(answer), int192(answer));
        bytes memory report = abi.encode(uint32(block.timestamp), bytes32(uint256(0x000102) << 232), obs, int192(0));
        ++epochAndRound;
        bytes32[3] memory ctx = [digest, bytes32(uint256(epochAndRound)), bytes32(0)];
        bytes32 h = keccak256(abi.encode(keccak256(report), ctx));
        bytes32[] memory rs = new bytes32[](OCR_F + 1);
        bytes32[] memory ss = new bytes32[](OCR_F + 1);
        bytes32 rawVs;
        for (uint256 i = 0; i <= OCR_F; ++i) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(ocrOracles[i], h);
            (rs[i], ss[i]) = (r, s);
            rawVs |= bytes32(uint256(v - 27) << (248 - 8 * i));
        }
        vm.stopBroadcast();
        vm.broadcast(ocrOracles[0]);
        // The aggregator books its gas reimbursement from `uint32(gasleft())`, so the call gets a real transaction's
        // gas, not the script simulation's whole budget (above 2^32 it reverts "leftGas cannot exceed initialGas").
        IOCR2Admin(aggregator).transmit{gas: 1_000_000}(ctx, report, rs, ss, rawVs);
        vm.startBroadcast(deployer);
    }
}
