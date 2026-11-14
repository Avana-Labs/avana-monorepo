// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {AvanaCreate3Factory} from "../../script/deploy/AvanaCreate3Factory.sol";
import {DeployBase} from "../../script/deploy/lib/DeployBase.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

/// @notice Exposes the deploy scripts' release checks.
contract DeployReleaseHarness is DeployBase {
    function isReleaseTag(
        string memory r
    ) external pure returns (bool) {
        return _isReleaseTag(r);
    }

    function isLearningRelease(
        string memory r
    ) external pure returns (bool) {
        return _isLearningRelease(r);
    }

    function checkRelease(
        string memory r,
        uint256 chainId,
        bytes memory head,
        bytes memory tagCommit,
        bytes memory dirty
    ) external pure {
        _checkRelease(r, chainId, head, tagCommit, dirty);
    }

    function requireReleaseCheckout(
        string memory r
    ) external returns (bytes memory head) {
        return _requireReleaseCheckout(r);
    }

    function gitHead() external returns (bytes memory) {
        return _gitCommit("HEAD");
    }

    function setUpRecord(
        AvanaCreate3Factory f,
        address who,
        string memory r
    ) external {
        (create3, deployer, release) = (f, who, r);
    }

    function predict(
        string memory name
    ) external view returns (address) {
        return _predict(name);
    }

    function salt(
        string memory name
    ) external view returns (bytes32) {
        return _salt(name);
    }

    function checkReleaseRecord(
        string memory path,
        bytes memory head
    ) external view {
        _checkReleaseRecord(path, head);
    }
}

/// @notice The release check of the deploy scripts (`DeployInputs._loadInputs`, `03_DeployAvana`): `AVANA_RELEASE` is
/// a tag `vX.Y.Z[-pre]`; off anvil it is not a learning tag, HEAD is that tag's commit and the deployed sources are
/// unchanged; a release record of the release workflow, when given, names the same release, commit and addresses.
contract DeployReleaseTest is Test {
    DeployReleaseHarness internal h;
    bytes internal constant HEAD = hex"807e2c8000000000000000000000000000000001";
    bytes internal constant OTHER = hex"807e2c8000000000000000000000000000000002";

    function setUp() public {
        h = new DeployReleaseHarness();
    }

    function test_releaseTagFormat() public view {
        string[7] memory good =
            ["v0.1.0", "v1.2.3", "v0.1.0-alpha.1", "v0.1.0-local", "v10.20.30-rc.1.2", "v0.0.0-0", "v2.0.0-beta"];
        for (uint256 i = 0; i < good.length; ++i) {
            assertTrue(h.isReleaseTag(good[i]), good[i]);
        }
        string[16] memory bad = [
            "",
            "0.1.0",
            "v0.1",
            "v0.1.0.1",
            "v0.1.0-",
            "v0.1.0-Alpha",
            "v0.1.0-alpha_1",
            "v0.1.0+build",
            "V0.1.0",
            "v.1.0",
            "v0..0",
            "v0.1.0 ",
            " v0.1.0",
            "v0.1.0-alpha-1",
            "va.b.c",
            "v1.2."
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            assertFalse(h.isReleaseTag(bad[i]), bad[i]);
        }
    }

    function test_learningTags() public view {
        assertTrue(h.isLearningRelease("v0.1.0-local"));
        assertTrue(h.isLearningRelease("v0.1.0-test.2"));
        assertTrue(h.isLearningRelease("v0.1.0-learn"));
        assertTrue(h.isLearningRelease("v0.1.0-testnet.1"));
        assertFalse(h.isLearningRelease("v0.1.0"));
        assertFalse(h.isLearningRelease("v0.1.0-alpha.1"));
        assertFalse(h.isLearningRelease("v0.1.0-rc.local"));
    }

    function test_anvilAcceptsAnyTagWithoutGit() public view {
        h.checkRelease("v0.1.0-local", 31_337, "", "", "");
        h.checkRelease("v0.2.0", 31_337, "", "", " M src/x.sol");
    }

    function test_badFormatRefusedEverywhere() public {
        vm.expectRevert(bytes("AVANA_RELEASE local is not a release tag vX.Y.Z or vX.Y.Z-<pre-release>"));
        h.checkRelease("local", 31_337, "", "", "");
        vm.expectRevert(bytes("AVANA_RELEASE 0.1.0 is not a release tag vX.Y.Z or vX.Y.Z-<pre-release>"));
        h.checkRelease("0.1.0", 1, HEAD, HEAD, "");
    }

    function test_offAnvilRefusesLearningTag() public {
        vm.expectRevert(bytes("AVANA_RELEASE v0.1.0-local is a learning tag, for anvil only"));
        h.checkRelease("v0.1.0-local", 1, HEAD, HEAD, "");
        vm.expectRevert(bytes("AVANA_RELEASE v0.1.0-learn is a learning tag, for anvil only"));
        h.checkRelease("v0.1.0-learn", 8453, HEAD, HEAD, "");
        vm.expectRevert(bytes("AVANA_RELEASE v0.1.0-test.1 is a learning tag, for anvil only"));
        h.checkRelease("v0.1.0-test.1", 11_155_111, HEAD, HEAD, "");
    }

    function test_offAnvilRequiresTheTag() public {
        vm.expectRevert(bytes("no git tag v0.2.0 in this checkout"));
        h.checkRelease("v0.2.0", 1, HEAD, "", "");
    }

    function test_offAnvilRequiresHeadAtTheTag() public {
        vm.expectRevert(
            bytes(
                string.concat(
                    "HEAD ", vm.toString(HEAD), " is not v0.2.0 (", vm.toString(OTHER), "): check out the release tag"
                )
            )
        );
        h.checkRelease("v0.2.0", 1, HEAD, OTHER, "");
    }

    function test_offAnvilRefusesChangedSources() public {
        vm.expectRevert(bytes("uncommitted changes to the deployed sources:\n M src/x.sol"));
        h.checkRelease("v0.2.0", 1, HEAD, HEAD, " M src/x.sol");
    }

    function test_offAnvilAcceptsTheTaggedCheckout() public view {
        h.checkRelease("v0.2.0", 1, HEAD, HEAD, "");
        h.checkRelease("v0.2.0-rc.1", 8453, HEAD, HEAD, "");
    }

    /// Off anvil the check reads git: without `--ffi` it fails closed, and with it this checkout is not at `v99.0.0`.
    function test_offAnvilCheckoutCheckFailsClosed() public {
        vm.chainId(1);
        vm.expectRevert();
        h.requireReleaseCheckout("v99.0.0");
    }

    function test_anvilCheckoutCheckReadsNoGit() public {
        vm.chainId(31_337);
        assertEq(h.requireReleaseCheckout("v0.1.0-local").length, 0);
    }

    /// With `--ffi` (FOUNDRY_FFI=true): HEAD is read as the 20-byte commit.
    function test_gitHeadIsTheCommit() public {
        string[] memory probe = new string[](2);
        (probe[0], probe[1]) = ("git", "--version");
        try vm.tryFfi(probe) returns (Vm.FfiResult memory) {}
        catch {
            vm.skip(true, "ffi is off; test_offAnvilCheckoutCheckFailsClosed covers that case");
        }
        assertEq(h.gitHead().length, 20);
    }

    // ─── Release record ───

    string internal constant RECORD_DIR = "deployments-local/release-record-test";

    function _record(
        AvanaCreate3Factory f,
        address who,
        string memory r,
        string memory commit,
        address timelock
    ) internal returns (string memory) {
        return _write(
            string.concat(
                '{"release":"',
                r,
                '","commit":"',
                commit,
                '","create3Factory":"',
                vm.toString(address(f)),
                '","deployer":"',
                vm.toString(who),
                '","salts":[{"name":"AvanaTimelock","salt":"',
                vm.toString(h.salt("AvanaTimelock")),
                '","address":"',
                vm.toString(timelock),
                '"}]}'
            )
        );
    }

    /// A record built without a deployer: salts only, no addresses.
    function _recordNoDeployer(
        AvanaCreate3Factory f,
        bytes32 timelockSalt
    ) internal returns (string memory) {
        return _write(
            string.concat(
                '{"release":"v0.2.0","commit":"807e2c8000000000000000000000000000000001","create3Factory":"',
                vm.toString(address(f)),
                '","deployer":null,"salts":[{"name":"AvanaTimelock","salt":"',
                vm.toString(timelockSalt),
                '","address":null}]}'
            )
        );
    }

    function _write(
        string memory json
    ) internal returns (string memory path) {
        vm.createDir(string.concat(vm.projectRoot(), "/", RECORD_DIR), true);
        path = string.concat(RECORD_DIR, "/release.json");
        vm.writeFile(string.concat(vm.projectRoot(), "/", path), json);
    }

    function test_releaseRecord() public {
        AvanaCreate3Factory f = new AvanaCreate3Factory();
        address who = makeAddr("deployer");
        h.setUpRecord(f, who, "v0.2.0");
        address timelock = h.predict("AvanaTimelock");
        string memory commit = "807e2c8000000000000000000000000000000001";

        h.checkReleaseRecord(_record(f, who, "v0.2.0", commit, timelock), HEAD);
        // On anvil (no HEAD read) the commit is not compared.
        h.checkReleaseRecord(_record(f, who, "v0.2.0", commit, timelock), "");

        string memory p = _record(f, who, "v0.3.0", commit, timelock);
        vm.expectRevert(bytes("release record is for v0.3.0, not v0.2.0"));
        h.checkReleaseRecord(p, HEAD);

        p = _record(f, who, "v0.2.0", commit, timelock);
        vm.expectRevert(bytes(string.concat("release record commit 0x", commit, " is not HEAD ", vm.toString(OTHER))));
        h.checkReleaseRecord(p, OTHER);

        p = _record(f, makeAddr("someone else"), "v0.2.0", commit, timelock);
        vm.expectRevert(
            bytes(
                string.concat(
                    "release record predicts for deployer ",
                    vm.toString(makeAddr("someone else")),
                    ", not ",
                    vm.toString(who)
                )
            )
        );
        h.checkReleaseRecord(p, HEAD);

        p = _record(f, who, "v0.2.0", commit, address(0xBEEF));
        vm.expectRevert(
            bytes(
                string.concat(
                    "release record puts AvanaTimelock at ",
                    vm.toString(address(0xBEEF)),
                    "; this run predicts ",
                    vm.toString(timelock)
                )
            )
        );
        h.checkReleaseRecord(p, HEAD);

        AvanaCreate3Factory other = new AvanaCreate3Factory();
        p = _record(other, who, "v0.2.0", commit, timelock);
        vm.expectRevert(
            bytes(
                string.concat(
                    "release record names CREATE3 factory ",
                    vm.toString(address(other)),
                    ", not ",
                    vm.toString(address(f))
                )
            )
        );
        h.checkReleaseRecord(p, HEAD);

        h.checkReleaseRecord(_recordNoDeployer(f, h.salt("AvanaTimelock")), HEAD);
        p = _recordNoDeployer(f, bytes32(uint256(1)));
        vm.expectRevert(
            bytes(
                string.concat(
                    "release record salt of AvanaTimelock is ",
                    vm.toString(bytes32(uint256(1))),
                    "; this run's is ",
                    vm.toString(h.salt("AvanaTimelock"))
                )
            )
        );
        h.checkReleaseRecord(p, HEAD);

        vm.removeFile(string.concat(vm.projectRoot(), "/", p));
    }
}
