// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DeployBase} from "./lib/DeployBase.sol";
import {KeeperTopUpInput} from "./lib/DeployTypes.sol";
import {console2} from "forge-std/console2.sol";

/// @title FundKeepers
/// @notice Step 11: the keeper top-up wallet (`KEEPER_TOPUP_WALLET`, else the config's `keeperTopUp.wallet`) refills
/// every keeper signer (the config's `keepers` and each operator helper's `signer`) that holds less than
/// `keeperTopUp.minBalanceWei`, back to `keeperTopUp.targetBalanceWei`, one plain transfer each. It is the rule the
/// removed AvanaGasVault applied: the wallet holds the chain's keeper gas, and a signer is refilled only once it falls
/// below its minimum. The step is safe to rerun at any time (a signer at or above its minimum gets nothing), so the
/// operator runs it after the listing and again whenever a signer runs low (script/README.md, Keeper gas).
/// @dev Broadcast as the wallet: on anvil an unlocked sender, elsewhere its encrypted Foundry keystore. The wallet must
/// hold the whole refill, or the step stops before sending anything. On anvil a config without a wallet funds nothing.
contract FundKeepers is DeployBase {
    function run() external {
        string memory network = _network();
        KeeperTopUpInput memory t = _requireKeeperTopUp(network);
        if (t.wallet == address(0)) {
            console2.log("no keeper top-up wallet in the config: nothing to fund");
            return;
        }
        address[] memory signers = _keeperSigners(network);
        uint256[] memory amounts = new uint256[](signers.length);
        uint256 total;
        for (uint256 i = 0; i < signers.length; ++i) {
            uint256 balance = signers[i].balance;
            if (balance < t.minBalanceWei) amounts[i] = t.targetBalanceWei - balance;
            total += amounts[i];
        }
        if (total == 0) {
            console2.log("every keeper signer holds at least keeperTopUp.minBalanceWei: nothing to send");
            return;
        }
        require(
            t.wallet.balance >= total,
            string.concat(
                "KEEPER_TOPUP_WALLET ",
                vm.toString(t.wallet),
                " holds ",
                vm.toString(t.wallet.balance),
                " wei; the keeper signers need ",
                vm.toString(total),
                " wei: fund the wallet first"
            )
        );
        vm.startBroadcast(t.wallet);
        for (uint256 i = 0; i < signers.length; ++i) {
            if (amounts[i] == 0) continue;
            (bool ok,) = payable(signers[i]).call{value: amounts[i]}("");
            require(ok, string.concat("keeper signer ", vm.toString(signers[i]), " refused the top-up"));
            console2.log("topped up", signers[i], amounts[i]);
        }
        vm.stopBroadcast();
        console2.log("keeper top-up wallet", t.wallet, "sent", total);
    }
}
