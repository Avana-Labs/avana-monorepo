// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAmmIntegration} from "../../src/amm/IAmmIntegration.sol";
import {IClIntegration} from "../../src/amm/IClIntegration.sol";
import {IClPositionManager} from "../../src/amm/concentrated-liquidity/IClPositionManager.sol";
import {ICollateralizationViews} from "../../src/custody/collateralization/ICollateralizationViews.sol";
import {ILPVault} from "../../src/custody/lp-vault/ILPVault.sol";
import {AvanaTimelock} from "../../src/governance/timelock/AvanaTimelock.sol";
import {GovernedTargets} from "../../src/governance/timelock/types/GovernedTargets.sol";
import {SelectorPair} from "../../src/governance/timelock/types/SelectorPair.sol";
import {PositionShape} from "../../src/types/PositionShape.sol";
import {ShapeKind} from "../../src/types/ShapeKind.sol";
import {IVaultTokenFactory} from "../../src/vault-token/vault-token-factory/IVaultTokenFactory.sol";
import {VaultTokenFactory} from "../../src/vault-token/vault-token-factory/VaultTokenFactory.sol";
import {IVaultToken} from "../../src/vault-token/vault-token/IVaultToken.sol";
import {VaultToken} from "../../src/vault-token/vault-token/VaultToken.sol";
import {CollPoolToken} from "../utils/mocks/CollateralizationMocks.sol";
import {OtherNft} from "../utils/mocks/UniswapV3Mocks.sol";
import {ClLPVaultBase, ClLPVaultSlipstreamHooks, ClLPVaultUniswapHooks} from "./ClLPVault.Base.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @title ClLPVaultIsolationTests
/// @notice What a concentrated-liquidity LPVault holds and answers to, on the production contract with no
/// Collateralization, vault token or registry behind it that could mask a fault: a pushed or sent NFT is only a stray
/// and leaves only through the AvanaTimelock at its normal delay; the LPVault grants no position-manager approval; it
/// has no vault-token code path, reads no pause state, policy or registry and calls no upgradeable contract; it refuses
/// ETH; a vault token bound to it can never reach it; it registers once under its own integration identifier; and a
/// pool token's transfer fee fails none of its checks. Each body runs on the Uniswap v3 and the Slipstream LPVault.
abstract contract ClLPVaultIsolationTests is ClLPVaultBase {
    // ─── Stray NFTs ───

    // TEST-015 verifies: REQ-VAULT-078, REQ-VAULT-093, REQ-VAULT-003, REQ-VAULT-152, ATTACK-006
    // Sources: 5.1 TEST-015 (an NFT sent outside a pledge is not credited and cannot be pledged; onERC721Received
    // accepts only the canonical position manager and records nothing); 2.2 REQ-VAULT-152 (a custody entry exactly for
    // a position held for a pledge)
    /// @notice A pushed NFT is held with no custody entry, cannot be pledged by its sender or as the LPVault's own, and no
    /// custody function accepts it; a pledged one has its entry exactly while held, and none once returned. Only the
    /// canonical position manager may call the receiver hook, and it records nothing.
    /// @dev Kills: a receiver hook that writes `depositorOf`, a pledge path that accepts the LPVault as owner, a custody
    /// entry left after the position leaves, a hook that accepts any ERC-721 contract.
    function test_TEST_015_pushedNftIsOnlyAStray() public {
        Core memory c = _cCore();
        IClIntegration v = _cVault();
        (bytes32 backed,) = _cPledge(MKT_A, bob, 1e12);
        bytes32 key = _cMint(MKT_A, alice, 1e9);
        IERC721 manager = _cManager(key);
        vm.expectEmit(address(v));
        emit StrayReceived(key, alice, alice);
        vm.prank(alice);
        manager.safeTransferFrom(alice, address(v), _cTokenId(key));
        assertEq(manager.ownerOf(_cTokenId(key)), address(v), "the LPVault holds the pushed NFT");
        assertEq(v.depositorOf(key), address(0), "no custody entry for a pushed NFT");
        assertEq(v.marketOfPosition(key), 0);
        assertFalse(v.isInCustody(key));
        vm.expectRevert(NotInCustody.selector);
        v.unitsOf(key);
        assertEq(v.depositorOf(backed), bob, "a pledged NFT has its entry while held");
        assertTrue(v.isInCustody(backed));
        // Nothing turns the stray into a record or moves it as one.
        vm.prank(c.adapter);
        c.lock.acquire();
        vm.startPrank(c.coll);
        vm.expectRevert(NotTokenOwner.selector);
        v.receivePosition(MKT_A, alice, key);
        vm.expectRevert(NotTokenOwner.selector);
        v.receivePosition(MKT_A, address(v), key);
        vm.expectRevert(NotInCustody.selector);
        v.returnPosition(key);
        vm.expectRevert(NotInCustody.selector);
        v.unwind(key, 1, _cZeros(), c.lpVaultSwap);
        vm.expectRevert(NotInCustody.selector);
        v.releaseToDepositor(key, 1, _cZeros());
        vm.expectRevert(NotInCustody.selector);
        v.collectFees(key, alice);
        vm.stopPrank();
        // Custody is taken only through receivePosition from Collateralization inside a Lock session.
        bytes32 other = _cMint(MKT_A, alice, 1e9);
        vm.prank(alice);
        vm.expectRevert(NotCollateralization.selector);
        v.receivePosition(MKT_A, alice, other);
        vm.prank(c.adapter);
        vm.expectRevert(NotCollateralization.selector);
        v.receivePosition(MKT_A, alice, other);
        vm.prank(c.adapter);
        c.lock.release();
        vm.prank(c.coll);
        vm.expectRevert(LockNotHeld.selector);
        v.receivePosition(MKT_A, alice, other);
        assertEq(v.depositorOf(key), address(0), "still no entry for the pushed NFT");
        // The entry of a returned position is gone with it.
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (backed)));
        assertEq(v.depositorOf(backed), address(0), "no entry once the position left");
        assertEq(manager.ownerOf(_cTokenId(backed)), bob);
        // Only the canonical position manager may call the receiver hook.
        OtherNft foreign = new OtherNft();
        foreign.mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(UnsupportedNft.selector);
        foreign.safeTransferFrom(alice, address(v), 1);
        vm.prank(alice);
        vm.expectRevert(UnsupportedNft.selector);
        IClIntegration(address(v)).onERC721Received(alice, alice, _cTokenId(key), "");
    }

    // TEST-015 verifies: REQ-VAULT-165, REQ-VAULT-079, REQ-VAULT-080, REQ-VAULT-122, REQ-VAULT-123, INV-007
    // Sources: 2.2 REQ-VAULT-165 and the failure rows REQ-VAULT-122, REQ-VAULT-123; 2.20 REQ-VAULT-080
    /// @notice `returnStray` runs only for the timelock, only with the Lock free, only to a recipient other than zero
    /// and the LPVault, and only for a position the LPVault holds with no custody entry; it then sends the NFT by
    /// `transferFrom` and emits `StrayReturned`.
    /// @dev Kills: a missing caller, Lock, recipient or stray check, a stray path that can move a pledged NFT, a
    /// return through `safeTransferFrom`.
    function test_TEST_015_returnStrayOnlyThroughTheTimelockForAStray() public {
        Core memory c = _cCore();
        IClIntegration v = _cVault();
        bytes32 stray = _cMint(MKT_A, alice, 1e9);
        (bytes32 pledged,) = _cPledge(MKT_A, bob, 1e9);
        IERC721 manager = _cManager(stray);
        vm.prank(alice);
        manager.transferFrom(alice, address(v), _cTokenId(stray)); // sent without a hook: still a stray
        address[3] memory outsiders = [alice, governanceMultisig, c.coll];
        for (uint256 i = 0; i < outsiders.length; ++i) {
            vm.prank(outsiders[i]);
            vm.expectRevert(NotTimelock.selector);
            v.returnStray(stray, carol);
        }
        vm.startPrank(c.timelock);
        vm.expectRevert(InvalidRecipient.selector);
        v.returnStray(stray, address(0));
        vm.expectRevert(InvalidRecipient.selector);
        v.returnStray(stray, address(v));
        vm.expectRevert(NotStray.selector);
        v.returnStray(pledged, carol);
        vm.expectRevert(NotStray.selector);
        v.returnStray(bytes32(uint256(999_999)), carol); // a token the manager does not know
        vm.stopPrank();
        bytes32 elsewhere = _cMint(MKT_A, carol, 1);
        vm.prank(c.timelock);
        vm.expectRevert(NotStray.selector);
        v.returnStray(elsewhere, alice); // not held by the LPVault
        vm.prank(c.adapter);
        c.lock.acquire();
        vm.prank(c.timelock);
        vm.expectRevert(Locked.selector);
        v.returnStray(stray, carol);
        vm.prank(c.adapter);
        c.lock.release();
        vm.expectCall(
            address(manager),
            abi.encodeWithSelector(IERC721.transferFrom.selector, address(v), carol, _cTokenId(stray)),
            1
        );
        vm.expectCall(address(manager), abi.encodeWithSignature("safeTransferFrom(address,address,uint256)"), 0);
        vm.expectEmit(address(v));
        emit StrayReturned(stray, carol);
        vm.prank(c.timelock);
        v.returnStray(stray, carol);
        assertEq(manager.ownerOf(_cTokenId(stray)), carol);
        assertEq(manager.ownerOf(_cTokenId(pledged)), address(v), "the pledged NFT never moved");
        assertEq(v.depositorOf(pledged), bob);
    }

    // TEST-015 verifies: REQ-VAULT-083, REQ-VAULT-079, ATTACK-006
    // Sources: 2.2 REQ-VAULT-083 (the stray condition at execution); REQ-VAULT-079 (an NFT in custody, credited or at
    // zero units, is never moved by the stray path)
    /// @notice A position pledged after a return was scheduled is refused at execution; a position seized down to zero
    /// units is still in custody and refused; a closed record's NFT sent back later is a stray again.
    /// @dev Kills: a stray condition read at scheduling, a zero-unit position treated as stray.
    function test_TEST_015_strayConditionIsEvaluatedAtExecution() public {
        Core memory c = _cCore();
        IClIntegration v = _cVault();
        (bytes32 key, uint128 units) = _cPledge(MKT_A, alice, 1e9);
        // Seized to zero units: still in custody, never a stray.
        _cAs(c.lpVaultSwap, abi.encodeCall(IAmmIntegration.unwind, (key, units, _cZeros(), c.lpVaultSwap)));
        assertEq(v.unitsOf(key), 0);
        assertEq(v.depositorOf(key), alice);
        vm.prank(c.timelock);
        vm.expectRevert(NotStray.selector);
        v.returnStray(key, bob);
        // Returned, then sent back: a stray again, and returnable.
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (key)));
        (bytes32 again,) = _cPledge(MKT_A, alice, 1e9);
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (again)));
        vm.prank(alice);
        _cManager(again).transferFrom(alice, address(v), _cTokenId(again));
        vm.prank(c.timelock);
        v.returnStray(again, alice);
        // Pledged again before a second return executes: refused at execution.
        vm.prank(alice);
        _cManager(again).approve(address(v), _cTokenId(again));
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.receivePosition, (MKT_A, alice, again)));
        vm.prank(c.timelock);
        vm.expectRevert(NotStray.selector);
        v.returnStray(again, bob);
        assertEq(_cManager(again).ownerOf(_cTokenId(again)), address(v));
    }

    // TEST-166 verifies: REQ-VAULT-081, REQ-VAULT-082, REQ-VAULT-084, REQ-VAULT-165, Q-228
    // Sources: 5.1 TEST-166 (returnStray only for TIMELOCK; at the normal delay it executes right after it; no second
    // timer); 2.2 REQ-VAULT-081 (recipient as scheduled), REQ-VAULT-082, REQ-VAULT-084 (cancel through the timelock)
    /// @notice An LPVault bound to the real AvanaTimelock: the governance multisig cannot call `returnStray` directly; the
    /// operation needs the normal delay and no more, executes for anyone right after it and sends the NFT to the
    /// recipient it names (not the sender); each canceller can cancel a scheduled return; the LPVault has no queue,
    /// timer or cancel of its own.
    /// @dev Kills: a role or multisig caller check in place of the timelock, a delay or queue inside the LPVault, a
    /// recipient inferred from the sender.
    function test_TEST_166_strayReturnRunsAtOneNormalDelay() public {
        AvanaTimelock tl = _cTimelock();
        IClIntegration v = _cVaultWithTimelock(address(tl));
        bytes32 stray = _cMint(MKT_A, alice, 1e9);
        vm.prank(alice);
        _cManager(stray).transferFrom(alice, address(v), _cTokenId(stray));
        bytes memory data = abi.encodeCall(ILPVault.returnStray, (stray, carol));
        vm.prank(governanceMultisig);
        vm.expectRevert(NotTimelock.selector);
        v.returnStray(stray, carol);
        address[] memory targets = new address[](1);
        targets[0] = address(v);
        bytes[] memory payloads = new bytes[](1);
        payloads[0] = data;
        assertEq(tl.requiredDelay(targets, payloads), NORMAL_DELAY, "one normal delay");
        vm.prank(governanceMultisig);
        vm.expectRevert();
        tl.schedule(address(v), 0, data, bytes32(0), bytes32("short"), NORMAL_DELAY - 1);
        // Every canceller can cancel a scheduled return; the NFT stays.
        address[4] memory cancellers = [governanceMultisig, emergencyGuardian, aaveGuardian, aaveGovernanceExecutor];
        for (uint256 i = 0; i < cancellers.length; ++i) {
            bytes32 salt = bytes32(i + 1);
            vm.prank(governanceMultisig);
            tl.schedule(address(v), 0, data, bytes32(0), salt, NORMAL_DELAY);
            bytes32 id = tl.hashOperation(address(v), 0, data, bytes32(0), salt);
            vm.prank(cancellers[i]);
            tl.cancel(id);
            vm.warp(block.timestamp + NORMAL_DELAY);
            vm.prank(attacker);
            vm.expectRevert();
            tl.execute(address(v), 0, data, bytes32(0), salt);
        }
        assertEq(_cManager(stray).ownerOf(_cTokenId(stray)), address(v), "cancelled returns move nothing");
        (bool hasCancel,) = address(v).call(abi.encodeWithSignature("cancel(bytes32)", bytes32(0)));
        (bool hasQueue,) = address(v).call(abi.encodeWithSignature("scheduleReturn(bytes32,address)", stray, carol));
        assertFalse(hasCancel || hasQueue, "no cancel or queue of its own");
        // Scheduled at the normal delay: not a second earlier, then by anyone, to the scheduled recipient.
        vm.prank(governanceMultisig);
        tl.schedule(address(v), 0, data, bytes32(0), bytes32("run"), NORMAL_DELAY);
        vm.warp(block.timestamp + NORMAL_DELAY - 1);
        vm.prank(attacker);
        vm.expectRevert();
        tl.execute(address(v), 0, data, bytes32(0), bytes32("run"));
        vm.warp(block.timestamp + 1);
        vm.expectEmit(address(v));
        emit StrayReturned(stray, carol);
        vm.prank(attacker);
        tl.execute(address(v), 0, data, bytes32(0), bytes32("run"));
        assertEq(_cManager(stray).ownerOf(_cTokenId(stray)), carol, "sent to the recipient governance named");
    }

    /// @notice The AvanaTimelock with the launch roles, normal delay and public execution, and no short-delay or
    /// DAO-only selectors.
    function _cTimelock() internal returns (AvanaTimelock) {
        address[] memory proposers = new address[](2);
        (proposers[0], proposers[1]) = (governanceMultisig, aaveGovernanceExecutor);
        address[] memory executors = new address[](1);
        executors[0] = governanceMultisig;
        address[] memory cancellers = new address[](2);
        (cancellers[0], cancellers[1]) = (emergencyGuardian, aaveGuardian);
        address[] memory daoCancellers = new address[](1);
        daoCancellers[0] = aaveGovernanceExecutor;
        return new AvanaTimelock(
            proposers,
            executors,
            cancellers,
            daoCancellers,
            NORMAL_DELAY,
            true,
            new SelectorPair[](0),
            new SelectorPair[](0),
            GovernedTargets(makeAddr("parameterStore"), makeAddr("marketRegistryTarget"), makeAddr("lpVaultSwapTarget"))
        );
    }

    // ─── Approvals ───

    // TEST-021 verifies: REQ-AMM-V3-004, REQ-VAULT-097, REQ-VAULT-004, ATTACK-008
    // Sources: 5.1 TEST-021; 2.20 REQ-AMM-V3-004 (the LPVault makes every state-changing manager call on a pledged NFT
    // and never approves, burns or safe-transfers it out)
    /// @notice Across a pledge, a fee collection, a partial removal, a seizure and the return, the LPVault calls neither
    /// `approve`, `setApprovalForAll`, `burn` nor `safeTransferFrom`; an approval set before the pledge is cleared and the
    /// previous owner's operator can move neither the NFT, its liquidity nor its fees; the LPVault has no ERC-1271.
    /// @dev Kills: any approval or operator grant, a burn or a hook-running transfer out of custody.
    function test_TEST_021_noApprovalsAndNoOperatorRights() public {
        Core memory c = _cCore();
        IClIntegration v = _cVault();
        bytes32 key = _cMint(MKT_A, alice, 1e12);
        uint256 id = _cTokenId(key);
        address manager = address(_cManager(key));
        vm.prank(alice);
        IERC721(manager).setApprovalForAll(bob, true);
        vm.expectCall(manager, abi.encodeWithSelector(IERC721.approve.selector), 0);
        vm.expectCall(manager, abi.encodeWithSelector(IERC721.setApprovalForAll.selector), 0);
        vm.expectCall(manager, abi.encodeWithSignature("burn(uint256)"), 0);
        vm.expectCall(manager, abi.encodeWithSignature("safeTransferFrom(address,address,uint256)"), 0);
        vm.expectCall(manager, abi.encodeWithSignature("safeTransferFrom(address,address,uint256,bytes)"), 0);
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.receivePosition, (MKT_A, alice, key)));
        assertEq(IERC721(manager).getApproved(id), address(0), "the pre-pledge approval is cleared");
        _cManager(key).accrue(id, 3, 4);
        // Neither the previous owner nor its operator can move the NFT, its liquidity or its fees.
        address[2] memory others = [alice, bob];
        for (uint256 i = 0; i < 2; ++i) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, others[i], id));
            IERC721(manager).transferFrom(address(v), others[i], id);
            vm.prank(others[i]);
            vm.expectRevert();
            IClPositionManager(manager)
                .decreaseLiquidity(IClPositionManager.DecreaseLiquidityParams(id, 1, 0, 0, block.timestamp));
            vm.prank(others[i]);
            vm.expectRevert();
            IClPositionManager(manager).collect(IClPositionManager.CollectParams(id, others[i], 1, 1));
        }
        uint128 units = v.unitsOf(key);
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.collectFees, (key, alice)));
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.releaseToDepositor, (key, units / 4, _cZeros())));
        _cAs(c.lpVaultSwap, abi.encodeCall(IAmmIntegration.unwind, (key, units / 4, _cZeros(), c.lpVaultSwap)));
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (key)));
        assertEq(IERC721(manager).ownerOf(id), alice);
        (bool ok,) = address(v).call(abi.encodeWithSignature("isValidSignature(bytes32,bytes)", bytes32(0), ""));
        assertFalse(ok, "no ERC-1271");
        assertTrue(_hasSelectorConstant(address(v).code, IClPositionManager.decreaseLiquidity.selector), "scan works");
        assertFalse(_hasSelectorConstant(address(v).code, IERC721.setApprovalForAll.selector), "no operator grant");
    }

    // ─── Vault tokens, gates and upgradeable contracts ───

    // TEST-162 verifies: REQ-VAULT-005, REQ-VAULT-098, REQ-VAULT-039, REQ-VAULT-040, REQ-VAULT-041, REQ-VAULT-045, REQ-VAULT-096
    // Sources: 2.2 REQ-VAULT-005 (no pause, reads no gate), REQ-VAULT-039 to REQ-VAULT-045 and REQ-VAULT-096 (no
    // vault-token code path), REQ-VAULT-098 (calls no upgradeable Avana contract, instructions only from
    // Collateralization); 5.1 TEST-162 (with the MarketRegistry reverting, fee collection and the exits succeed)
    /// @notice With a vault token bound to the LPVault and the MarketRegistry address reverting on every call, a pledge,
    /// a fee collection, a partial removal, a seizure, a reconcile removal and the return all succeed, and in all of them
    /// the LPVault touches no vault token, factory, registry, Aave address, AaveAdapter, LPVaultSwap, timelock or
    /// Collateralization; every call into it comes from Collateralization. Every custody function refuses every other
    /// caller, it has no pause, and its code holds no vault-token mint, burn, transfer or approve selector.
    /// @dev Kills: a vault-token call, a pause or freeze read, a registry or oracle read, or a call to an upgradeable
    /// contract added to the LPVault's custody, removal or fee paths.
    function test_TEST_162_lpVaultTouchesNoVaultTokenGateOrUpgradeableContract() public {
        (VaultTokenFactory factory, VaultToken token) = _cListToken();
        _cBreakRegistry();
        vm.expectCall(_cCore().registry, "", 0);
        vm.startStateDiffRecording();
        _isolatedLifecycle();
        _assertIsolated(vm.stopAndReturnStateDiff(), address(factory), token);
        assertEq(token.balanceOf(address(_cVault())), 0, "no vault token at the LPVault");
        assertEq(token.totalSupply(), 0, "the lifecycle minted and burned no vault token");
        _assertOnlyCollateralizationInstructs();
        address v = address(_cVault());
        (bool hasPause,) = v.call(abi.encodeWithSignature("pause()"));
        (bool hasPaused,) = v.call(abi.encodeWithSignature("paused()"));
        (bool hasState,) = v.call(abi.encodeWithSignature("pauseState(address)", address(0)));
        assertFalse(hasPause || hasPaused || hasState, "no pause of its own");
        bytes memory code = v.code;
        // The scan finds the calls the LPVault does make, so an absent selector is a real absence.
        assertTrue(_hasSelectorConstant(code, IClPositionManager.collect.selector), "scan sees the manager's collect");
        assertTrue(_hasSelectorConstant(code, IClPositionManager.transferFrom.selector), "scan sees transferFrom");
        assertFalse(_hasSelectorConstant(code, IVaultToken.mint.selector), "no vault-token mint");
        assertFalse(_hasSelectorConstant(code, IVaultToken.burn.selector), "no vault-token burn");
        assertFalse(_hasSelectorConstant(code, IVaultToken.addValidProxy.selector), "no proxy registration");
        assertFalse(_hasSelectorConstant(code, bytes4(keccak256("transfer(address,uint256)"))), "no ERC-20 transfer");
        assertFalse(_hasSelectorConstant(code, bytes4(keccak256("approve(address,uint256)"))), "no approve");
    }

    /// @dev A pledge, a fee collection, a partial removal, a seizure, a reconcile removal and the return.
    function _isolatedLifecycle() private {
        Core memory c = _cCore();
        (bytes32 key, uint128 units) = _cPledge(MKT_A, alice, 1e12);
        _cManager(key).accrue(_cTokenId(key), 5, 6);
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.collectFees, (key, alice)));
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.releaseToDepositor, (key, units / 4, _cZeros())));
        _cAs(c.lpVaultSwap, abi.encodeCall(IAmmIntegration.unwind, (key, units / 4, _cZeros(), c.lpVaultSwap)));
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.unwind, (key, units / 8, _cZeros(), c.coll)));
        _cAs(c.adapter, abi.encodeCall(IAmmIntegration.returnPosition, (key)));
    }

    /// @dev The LPVault touched none of the denied accounts, and every call into it came from Collateralization.
    function _assertIsolated(
        VmSafe.AccountAccess[] memory accesses,
        address factory,
        VaultToken token
    ) private view {
        Core memory c = _cCore();
        address v = address(_cVault());
        address[10] memory denied = [
            address(token),
            factory,
            c.registry,
            c.adapter,
            c.lpVaultSwap,
            c.timelock,
            c.coll,
            token.hub(),
            token.spoke(),
            token.lpOracle()
        ];
        uint256 vaultCalls = 0;
        for (uint256 i = 0; i < accesses.length; ++i) {
            if (accesses[i].accessor == v) {
                for (uint256 j = 0; j < denied.length; ++j) {
                    assertTrue(
                        accesses[i].account != denied[j], string.concat("LPVault touched ", vm.toString(denied[j]))
                    );
                }
            }
            if (accesses[i].account == v && accesses[i].kind == VmSafe.AccountAccessKind.Call) {
                ++vaultCalls;
                assertEq(accesses[i].accessor, c.coll, "every call into the LPVault is Collateralization's");
            }
        }
        assertEq(vaultCalls, 6, "pledge, fees, removal, seizure, reconcile and return reached the LPVault");
    }

    /// @dev Every custody function refuses every caller but Collateralization, whoever holds the Lock.
    function _assertOnlyCollateralizationInstructs() private {
        Core memory c = _cCore();
        (bytes32 other,) = _cPledge(MKT_A, bob, 1e12);
        bytes32 fresh = _cMint(MKT_A, carol, 1e9);
        address[5] memory callers = [c.adapter, c.lpVaultSwap, c.registry, c.timelock, attacker];
        bytes[5] memory calls = [
            abi.encodeCall(IAmmIntegration.returnPosition, (other)),
            abi.encodeCall(IAmmIntegration.unwind, (other, 1, _cZeros(), c.lpVaultSwap)),
            abi.encodeCall(IAmmIntegration.releaseToDepositor, (other, 1, _cZeros())),
            abi.encodeCall(IAmmIntegration.collectFees, (other, bob)),
            abi.encodeCall(IAmmIntegration.receivePosition, (MKT_A, carol, fresh))
        ];
        address[2] memory holders = [c.adapter, c.lpVaultSwap];
        for (uint256 h = 0; h < 2; ++h) {
            for (uint256 i = 0; i < callers.length; ++i) {
                for (uint256 j = 0; j < calls.length; ++j) {
                    (bool ok, bytes memory err) = _cTry(holders[h], callers[i], calls[j]);
                    assertFalse(ok, "only Collateralization instructs the LPVault");
                    assertEq(bytes4(err), NotCollateralization.selector);
                }
            }
        }
    }

    // TEST-189 verifies: REQ-VAULT-044, REQ-VAULT-045, REQ-VAULT-039, REQ-VTOKEN-006
    // Sources: 2.2 REQ-VAULT-044 (the LPVault is not an allowed recipient of any vault token; a transfer or mint to it
    // reverts)
    /// @notice A vault token deployed by the real VaultTokenFactory for a market of this LPVault refuses the LPVault as
    /// mint recipient, as proxy and as transfer destination, from a registered proxy and from the Hub.
    /// @dev Kills: the LPVault becoming an allowed recipient, a registrable proxy or a transfer destination.
    function test_TEST_189_noVaultTokenCanReachTheLPVault() public {
        Core memory c = _cCore();
        address lpv = address(_cVault());
        (, VaultToken token) = _cListToken();
        assertEq(token.integration(), lpv, "the token is bound to this LPVault");
        assertFalse(token.isAllowedRecipient(lpv), "not an allowed recipient");
        address proxy = makeAddr("proxy");
        vm.startPrank(c.adapter);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedRecipient.selector, lpv));
        token.mint(lpv, 1);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.ReservedAddress.selector, lpv));
        token.addValidProxy(lpv);
        token.addValidProxy(proxy);
        token.mint(proxy, 10);
        vm.stopPrank();
        vm.prank(proxy);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, proxy, lpv));
        token.transfer(lpv, 1);
        address hub = token.hub();
        vm.prank(proxy);
        token.transfer(hub, 4);
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSelector(IVaultToken.UnauthorizedTransfer.selector, hub, lpv));
        token.transfer(lpv, 1);
        assertEq(token.balanceOf(lpv), 0, "the LPVault holds no vault token");
    }

    // TEST-024 verifies: REQ-VAULT-174, REQ-AMM-CORE-001
    // Sources: 2.2 REQ-VAULT-174 (one LPVault per AMM protocol and generation, registered write-once under its
    // INTEGRATION_ID)
    /// @notice The production LPVault registers in the real VaultTokenFactory only under its own `INTEGRATION_ID`; the
    /// entry is written once: a second LPVault of the same protocol under that identifier, or this LPVault under another
    /// identifier, is refused, and the registered address does not change.
    /// @dev Kills: an overwritable integration entry, an LPVault registered under a foreign identifier or twice.
    function test_TEST_024_lpVaultRegistersOnceUnderItsIntegrationId() public {
        Core memory c = _cCore();
        IClIntegration v = _cVault();
        uint32 id = v.INTEGRATION_ID();
        VaultTokenFactory factory = _cFactory();
        vm.prank(c.timelock);
        vm.expectRevert(IVaultTokenFactory.InvalidIntegration.selector);
        factory.registerIntegration(id + 1, address(v)); // not its own identifier
        vm.prank(c.adapter);
        vm.expectRevert(IVaultTokenFactory.NotTimelock.selector);
        factory.registerIntegration(id, address(v));
        vm.prank(c.timelock);
        factory.registerIntegration(id, address(v));
        assertEq(factory.lpVaultOf(id), address(v));
        IClIntegration twin = _cVaultWithTimelock(c.timelock);
        vm.startPrank(c.timelock);
        vm.expectRevert(IVaultTokenFactory.InvalidIntegration.selector);
        factory.registerIntegration(id, address(twin)); // the identifier is taken
        vm.expectRevert(IVaultTokenFactory.InvalidIntegration.selector);
        factory.registerIntegration(id, address(v)); // registered once
        vm.expectRevert(IVaultTokenFactory.InvalidIntegration.selector);
        factory.registerIntegration(id + 7, address(v)); // once per LPVault
        vm.stopPrank();
        assertEq(factory.lpVaultOf(id), address(v), "the entry never changes");
        assertEq(factory.lpVaultOf(id + 7), address(0));
    }

    // ─── ETH and transfer fees ───

    // TEST-080 verifies: REQ-VAULT-175, REQ-VAULT-085
    // Sources: 2.2 REQ-VAULT-175 (an LPVault whose AMM protocol pays no native ETH accepts none: its receive reverts in
    // every case)
    /// @notice ETH sent to the LPVault is refused with the Lock free and held, from a wallet, the position manager and
    /// the pool, with and without calldata; a pledged position is unchanged.
    /// @dev Kills: a `receive` or payable fallback on an LPVault of a protocol that pays ERC-20 tokens only.
    function test_TEST_080_lpVaultRefusesEth() public {
        Core memory c = _cCore();
        address v = address(_cVault());
        (bytes32 key, uint128 units) = _cPledge(MKT_A, alice, 1e12);
        address[3] memory senders = [attacker, address(_cManager(key)), address(_cPool(MKT_A))];
        for (uint256 locked = 0; locked < 2; ++locked) {
            if (locked == 1) {
                vm.prank(c.adapter);
                c.lock.acquire();
            }
            for (uint256 i = 0; i < senders.length; ++i) {
                vm.deal(senders[i], 2);
                vm.prank(senders[i]);
                (bool plain,) = v.call{value: 1}("");
                vm.prank(senders[i]);
                (bool withData,) = v.call{value: 1}(hex"deadbeef");
                assertFalse(plain || withData, "the LPVault accepts no ETH");
            }
            if (locked == 1) {
                vm.prank(c.adapter);
                c.lock.release();
            }
        }
        assertEq(v.balance, 0);
        assertEq(_cVault().unitsOf(key), units);
        assertEq(_cVault().depositorOf(key), alice);
    }

    // TEST-221 verifies: REQ-VAULT-164, REQ-VAULT-154
    // Sources: 2.2 REQ-VAULT-164 (a pool token that charges a transfer fee on a payout fails no LPVault check: the
    // LPVault reports the AMM protocol's amounts and the recipient measures what it received)
    /// @notice On a market whose token0 switched on a 1% transfer fee after listing, a seizure, a partial removal with
    /// per-token minimums equal to the removed amounts, and a fee collection all succeed; each reports the position
    /// manager's amounts while the recipient receives 1% less of token0.
    /// @dev Kills: an LPVault check on received balances, which a transfer fee would fail.
    function test_TEST_221_transferFeeOnAPayoutFailsNoLPVaultCheck() public {
        _cBindMarketC(address(new CollPoolToken("FEE0", 6)), address(new CollPoolToken("FEE1", 6)));
        (bytes32 key, uint128 units) = _cPledge(MKT_C, alice, 1e12);
        CollPoolToken(_cPool(MKT_C).token0()).setFeeBps(100);
        uint256[] memory got = _feeSeize(key, units / 4);
        _feeRelease(key, units / 4, got);
        _feeCollect(key);
        assertEq(CollPoolToken(_cPool(MKT_C).token0()).balanceOf(address(_cVault())), 0, "nothing rests at the LPVault");
        assertEq(_cVault().depositorOf(key), alice);
    }

    /// @dev A seizure to LPVaultSwap: the manager's amounts reported, 1% of token0 kept by the token.
    function _feeSeize(
        bytes32 key,
        uint128 units
    ) private returns (uint256[] memory got) {
        Core memory c = _cCore();
        CollPoolToken t0 = CollPoolToken(_cPool(MKT_C).token0());
        CollPoolToken t1 = CollPoolToken(_cPool(MKT_C).token1());
        uint256 before0 = t0.balanceOf(c.lpVaultSwap);
        uint256 before1 = t1.balanceOf(c.lpVaultSwap);
        got = abi.decode(
            _cAs(c.lpVaultSwap, abi.encodeCall(IAmmIntegration.unwind, (key, units, _cZeros(), c.lpVaultSwap))),
            (uint256[])
        );
        assertGt(got[0], 0);
        assertEq(t0.balanceOf(c.lpVaultSwap) - before0, got[0] - got[0] / 100, "the recipient bears the fee");
        assertEq(t1.balanceOf(c.lpVaultSwap) - before1, got[1]);
    }

    /// @dev A partial removal with per-token minimums equal to the manager's amounts still passes: the check is on the
    /// reported amounts, not on what arrived.
    function _feeRelease(
        bytes32 key,
        uint128 units,
        uint256[] memory mins
    ) private {
        CollPoolToken t0 = CollPoolToken(_cPool(MKT_C).token0());
        uint256 a0 = t0.balanceOf(alice);
        uint256[] memory part = abi.decode(
            _cAs(_cCore().adapter, abi.encodeCall(IAmmIntegration.releaseToDepositor, (key, units, mins))), (uint256[])
        );
        assertEq(part[0], mins[0], "reported: the manager's amount");
        assertEq(t0.balanceOf(alice) - a0, part[0] - part[0] / 100);
    }

    /// @dev Fee collection reports what the manager collected; the depositor receives it net of the fee.
    function _feeCollect(
        bytes32 key
    ) private {
        CollPoolToken t0 = CollPoolToken(_cPool(MKT_C).token0());
        _cManager(key).accrue(_cTokenId(key), 1000, 1000);
        uint256 a0 = t0.balanceOf(alice);
        uint256[] memory fees =
            abi.decode(_cAs(_cCore().adapter, abi.encodeCall(IAmmIntegration.collectFees, (key, alice))), (uint256[]));
        assertEq(fees[0], 1000, "reported: what the manager collected");
        assertEq(t0.balanceOf(alice) - a0, 990, "the depositor receives the amount net of the fee");
    }

    // ─── Helpers ───

    /// @notice The real VaultTokenFactory on the fixture's named core addresses, with Collateralization's three binding
    /// views and its Lock answered for the factory's core check.
    function _cFactory() internal returns (VaultTokenFactory factory) {
        Core memory c = _cCore();
        factory = new VaultTokenFactory(c.adapter, c.lpVaultSwap, c.coll, c.timelock, c.registry);
        vm.mockCall(
            c.coll, abi.encodeCall(ICollateralizationViews.VAULT_TOKEN_FACTORY, ()), abi.encode(address(factory))
        );
        vm.mockCall(c.coll, abi.encodeCall(ICollateralizationViews.ADAPTER, ()), abi.encode(c.adapter));
        vm.mockCall(c.coll, abi.encodeCall(ICollateralizationViews.LP_VAULT_SWAP, ()), abi.encode(c.lpVaultSwap));
        vm.mockCall(c.coll, abi.encodeCall(ICollateralizationViews.LOCK, ()), abi.encode(address(c.lock)));
    }

    /// @notice The LPVault registered in the real factory and the vault token of market 1 deployed by it.
    function _cListToken() internal returns (VaultTokenFactory factory, VaultToken token) {
        Core memory c = _cCore();
        IClIntegration v = _cVault();
        factory = _cFactory();
        vm.startPrank(c.timelock);
        factory.registerIntegration(v.INTEGRATION_ID(), address(v));
        address t = factory.deployVaultToken(
            v.INTEGRATION_ID(),
            address(_cPool(MKT_A)),
            bytes32(0),
            PositionShape(ShapeKind.TickRange, MKT_A_LOWER, MKT_A_UPPER),
            makeAddr("hub"),
            makeAddr("cdpSpoke"),
            MKT_A,
            makeAddr("lpOracle"),
            9,
            "Avana USDC/USDT",
            "avUSDC-USDT"
        );
        vm.stopPrank();
        token = VaultToken(t);
    }

    /// @notice Whether `code` holds `selector` as a `PUSH4` or left-aligned `PUSH32` constant, the forms an external call
    /// to that function compiles to.
    function _hasSelectorConstant(
        bytes memory code,
        bytes4 selector
    ) internal pure returns (bool) {
        for (uint256 i = 0; i + 33 <= code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op == 0x63 && bytes4(_word(code, i + 1)) == selector) return true;
            if (op == 0x7f && _word(code, i + 1) == bytes32(selector)) return true;
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f; // skip push data
        }
        return false;
    }

    function _word(
        bytes memory code,
        uint256 at
    ) private pure returns (bytes32 w) {
        assembly {
            w := mload(add(add(code, 32), at))
        }
    }
}

/// @notice `ClLPVaultIsolationTests` on the Uniswap v3 LPVault.
/// forge-config: default.isolate = false
contract UniswapV3IntegrationIsolationUnitTest is ClLPVaultUniswapHooks, ClLPVaultIsolationTests {}

/// @notice `ClLPVaultIsolationTests` on the Slipstream LPVault.
/// forge-config: default.isolate = false
contract SlipstreamIntegrationIsolationUnitTest is ClLPVaultSlipstreamHooks, ClLPVaultIsolationTests {}
