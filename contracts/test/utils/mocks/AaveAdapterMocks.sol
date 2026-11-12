// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {ICollateralizationViews} from "../../../src/custody/collateralization/ICollateralizationViews.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../../src/policy/market-registry/types/MarketStatus.sol";
import {SpokeDef} from "../../../src/policy/market-registry/types/SpokeDef.sol";
import {TokenDef} from "../../../src/policy/market-registry/types/TokenDef.sol";
import {IRiskModuleErrors} from "../../../src/policy/risk-module/IRiskModuleErrors.sol";
import {IPositionProxy} from "../../../src/proxy/position-proxy/IPositionProxy.sol";
import {Market} from "../../../src/types/Market.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

/// @notice UUPS stand-in that lets the fixture deploy the Adapter's ERC-1967 proxy first, so the Lock, Collateralization,
/// the VaultTokenFactory and the ProxyManager can be built with its final address before the real implementation.
contract AdapterPlaceholder is UUPSUpgradeable {
    function _authorizeUpgrade(
        address
    ) internal override {}
}

/// @notice MarketRegistry stand-in with the views the AaveAdapter and the ProxyManager read. `setBroken(true)` makes
/// every view revert, standing in for a faulty or hostile registry implementation; `reads` counts every view call.
contract AdapterRegistryMock {
    error RegistryBroken();

    mapping(uint256 => Market) internal _markets;
    mapping(address => SpokeDef) internal _spokes;
    mapping(address => PauseState) public pauseStateOf;
    mapping(address => PauseReason) public pauseReasonOf;
    mapping(address => bool) public frozen;
    mapping(address => mapping(uint256 => DebtReserveDef)) internal _debt;
    mapping(address => uint32) public integrationIdOfMap;
    mapping(address => bool) public recordedHub;
    address public payoutEscrow;
    address public flashSourceAddr;
    bool public broken;

    function setBroken(
        bool on
    ) external {
        broken = on;
    }

    function setMarket(
        uint256 marketId,
        Market calldata m
    ) external {
        if (!_marketKnown[marketId]) {
            _marketKnown[marketId] = true;
            _spokeMarkets[m.spoke].push(marketId);
        }
        _markets[marketId] = m;
        marketOfReserveMap[m.spoke][m.reserveId] = marketId;
    }

    // ─── Views the RiskModule reads (an Adapter-only test never sets them) ───

    mapping(uint256 => bool) internal _marketKnown;
    mapping(address => uint256[]) internal _spokeMarkets;
    mapping(address => mapping(uint256 => uint256)) public marketOfReserveMap;
    mapping(address => mapping(uint256 => bool)) internal _debtKnown;
    mapping(address => uint256[]) internal _debtIds;
    mapping(bytes32 => bool) public routeDown;
    mapping(bytes32 => uint32) public latched;
    mapping(bytes32 => uint64) public lastBreachAt;
    bool public implementationStale;
    bool public crossHubEnabled;

    function setMarketStatus(
        uint256 marketId,
        MarketStatus status
    ) external {
        _markets[marketId].status = status;
    }

    function setMarketOracle(
        uint256 marketId,
        address lpOracle,
        address integration
    ) external {
        _markets[marketId].lpOracle = lpOracle;
        _markets[marketId].integration = integration;
    }

    function setRouteDown(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        bool down
    ) external {
        routeDown[keccak256(abi.encode(marketId, token, debtAsset, kind))] = down;
    }

    function setLatched(
        bytes32 key,
        uint32 reasons,
        uint64 at
    ) external {
        latched[key] = reasons;
        lastBreachAt[key] = at;
    }

    function setImplementationStale(
        bool on
    ) external {
        implementationStale = on;
    }

    function marketsOfSpoke(
        address spoke
    ) external view returns (uint256[] memory) {
        _ok();
        return _spokeMarkets[spoke];
    }

    function marketOfReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (uint256) {
        _ok();
        return marketOfReserveMap[spoke][reserveId];
    }

    function getDebtReserveIds(
        address spoke
    ) external view returns (uint256[] memory) {
        _ok();
        return _debtIds[spoke];
    }

    function getToken(
        address
    ) external view returns (TokenDef memory def) {
        _ok();
        return def;
    }

    function getRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view returns (address route, bool usable) {
        _ok();
        usable = !routeDown[keccak256(abi.encode(marketId, token, debtAsset, kind))];
        route = usable ? address(this) : address(0);
    }

    function spokeImplementationStatus(
        address
    ) external view returns (address implementation, bytes32 codeHash, bool current) {
        _ok();
        current = !implementationStale;
        (implementation, codeHash) = (address(0), bytes32(0));
    }

    function marketBreaker(
        uint256 marketId
    ) external view returns (uint32, uint64) {
        _ok();
        bytes32 key = bytes32(marketId);
        return (latched[key], lastBreachAt[key]);
    }

    function debtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32, uint64) {
        _ok();
        bytes32 key = keccak256(abi.encode(spoke, debtReserveId));
        return (latched[key], lastBreachAt[key]);
    }

    function recordBreach(
        bytes32 key,
        uint32 reasons
    ) external {
        _ok();
        latched[key] |= reasons;
        lastBreachAt[key] = uint64(block.timestamp);
    }

    function crossHubLinesEnabled() external view returns (bool) {
        _ok();
        return crossHubEnabled;
    }

    function creditLine(
        address,
        address
    ) external view returns (uint256 line, uint256 drawCapSum) {
        _ok();
        (line, drawCapSum) = (1, 0);
    }

    function creditLineCoverage(
        address,
        address
    ) external view returns (uint256 required, uint256 funded) {
        _ok();
        (required, funded) = (0, 0);
    }

    function setMarketSpoke(
        uint256 marketId,
        address spoke
    ) external {
        _markets[marketId].spoke = spoke;
    }

    function setMarketIntegration(
        uint256 marketId,
        uint32 integrationId
    ) external {
        _markets[marketId].integrationId = integrationId;
    }

    function setMarketVaultToken(
        uint256 marketId,
        address vaultToken
    ) external {
        _markets[marketId].vaultToken = vaultToken;
    }

    function setMarketHub(
        uint256 marketId,
        address hub
    ) external {
        _markets[marketId].hub = hub;
    }

    function setSpoke(
        address spoke,
        SpokeDef calldata def
    ) external {
        _spokes[spoke] = def;
    }

    function setPause(
        address hub,
        PauseState state,
        PauseReason reason
    ) external {
        pauseStateOf[hub] = state;
        pauseReasonOf[hub] = reason;
    }

    function setFrozen(
        address account,
        bool on
    ) external {
        frozen[account] = on;
    }

    function setDebtReserve(
        address spoke,
        uint256 reserveId,
        DebtReserveDef calldata def
    ) external {
        if (!_debtKnown[spoke][reserveId]) {
            _debtKnown[spoke][reserveId] = true;
            _debtIds[spoke].push(reserveId);
        }
        _debt[spoke][reserveId] = def;
    }

    function setIntegrationId(
        address lpVault,
        uint32 id
    ) external {
        integrationIdOfMap[lpVault] = id;
    }

    function setRecordedHub(
        address hub,
        bool on
    ) external {
        recordedHub[hub] = on;
    }

    function setPayoutEscrow(
        address escrow
    ) external {
        payoutEscrow = escrow;
    }

    function setFlashSource(
        address source
    ) external {
        flashSourceAddr = source;
    }

    // ─── Views the Adapter reads ───

    function getMarket(
        uint256 marketId
    ) external view returns (Market memory) {
        _ok();
        return _markets[marketId];
    }

    function getSpoke(
        address spoke
    ) external view returns (SpokeDef memory) {
        _ok();
        return _spokes[spoke];
    }

    function pauseState(
        address hub
    ) external view returns (PauseState) {
        _ok();
        return pauseStateOf[hub];
    }

    function pauseReason(
        address hub
    ) external view returns (PauseReason) {
        _ok();
        return pauseReasonOf[hub];
    }

    function isFrozenAddress(
        address account
    ) external view returns (bool) {
        _ok();
        return frozen[account];
    }

    function isApprovedDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (bool) {
        _ok();
        return _debt[spoke][reserveId].approved;
    }

    function getDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (DebtReserveDef memory) {
        _ok();
        return _debt[spoke][reserveId];
    }

    function integrationIdOf(
        address lpVault
    ) external view returns (uint32) {
        _ok();
        return integrationIdOfMap[lpVault];
    }

    function isRecordedHub(
        address account
    ) external view returns (bool) {
        _ok();
        return recordedHub[account];
    }

    function PAYOUT_ESCROW() external view returns (address) {
        _ok();
        return payoutEscrow;
    }

    function flashSource() external view returns (address) {
        _ok();
        return flashSourceAddr;
    }

    function _ok() internal view {
        if (broken) revert RegistryBroken();
    }
}

/// @notice The RiskModule surface the AaveAdapter calls. `postHealthCheck` reads the real Spoke's health factor (and,
/// like the reviewed RiskModule, Collateralization's `getAccountRescueUnits`, which answers the Adapter's Lock) and
/// requires `hf >= max(1e18, hardFloor, minHealthFactor)`; `setBroken(true)` makes every function revert (a faulty or
/// hostile RiskModule); `refuse` makes the pre-checks revert with a RiskModule error. Every call is counted.
contract AdapterRiskModuleMock {
    error RiskModuleBroken();

    address public immutable SPOKE;
    address public immutable COLLATERALIZATION;
    address public vaultToken;
    bool public broken;
    bool public refuse;
    bool public approveAll;
    uint256 public hardFloor;
    uint256 public preBorrowCalls;
    uint256 public preWithdrawCalls;
    address public lastProxy;
    uint256 public lastDebtReserveId;
    uint256 public lastAmount;
    uint256 public minRemaining;

    constructor(
        address spoke,
        address collateralization
    ) {
        SPOKE = spoke;
        COLLATERALIZATION = collateralization;
    }

    function setVaultToken(
        address vt
    ) external {
        vaultToken = vt;
    }

    function setBroken(
        bool on
    ) external {
        broken = on;
    }

    function setRefuse(
        bool on
    ) external {
        refuse = on;
    }

    function setApproveAll(
        bool on
    ) external {
        approveAll = on;
    }

    function setHardFloor(
        uint256 floor
    ) external {
        hardFloor = floor;
    }

    function setMinRemaining(
        uint256 units
    ) external {
        minRemaining = units;
    }

    function preBorrowCheck(
        address proxy,
        uint256 debtReserveId,
        uint256 amount
    ) external {
        if (broken) revert RiskModuleBroken();
        if (refuse) revert IRiskModuleErrors.SequencerDown();
        ++preBorrowCalls;
        lastProxy = proxy;
        lastDebtReserveId = debtReserveId;
        lastAmount = amount;
    }

    function preWithdrawCheck(
        address proxy
    ) external {
        if (broken) revert RiskModuleBroken();
        if (refuse) revert IRiskModuleErrors.SequencerDown();
        ++preWithdrawCalls;
        lastProxy = proxy;
    }

    function postHealthCheck(
        address proxy,
        uint256 minHealthFactor
    ) external view returns (uint256 healthFactor) {
        if (broken) revert RiskModuleBroken();
        if (vaultToken != address(0)) {
            // The reviewed RiskModule reads the account's rescue units here, under the Adapter's Lock.
            ICollateralizationViews(COLLATERALIZATION).getAccountRescueUnits(proxy, vaultToken);
        }
        healthFactor = IAaveV4Spoke(SPOKE).getUserAccountData(proxy).healthFactor;
        if (approveAll) return healthFactor;
        uint256 required = 1e18;
        if (hardFloor > required) required = hardFloor;
        if (minHealthFactor > required) required = minHealthFactor;
        if (healthFactor < required) revert IRiskModuleErrors.HealthFactorTooLow(healthFactor, required);
    }

    function checkRemainingRecord(
        uint256,
        uint128 remainingUnits
    ) external view {
        if (broken) revert RiskModuleBroken();
        if (!approveAll && remainingUnits < minRemaining) {
            revert IRiskModuleErrors.RecordBelowMinPledge(remainingUnits, minRemaining);
        }
    }
}

/// @notice The ParameterStore's sequencer read.
contract AdapterParameterStoreMock {
    address public feed;
    uint32 public grace;

    function setSequencer(
        address f,
        uint32 g
    ) external {
        feed = f;
        grace = g;
    }

    function sequencer() external view returns (address, uint32) {
        return (feed, grace);
    }
}

/// @notice Chainlink L2 sequencer-uptime feed: `answer` 0 up, 1 down; `mode` 1 reverts, 2 answers a short buffer,
/// 3 answers a long one.
contract AdapterSequencerFeed {
    int256 public answer;
    uint256 public startedAt;
    uint8 public mode;

    function set(
        int256 a,
        uint256 s
    ) external {
        answer = a;
        startedAt = s;
    }

    function setMode(
        uint8 m
    ) external {
        mode = m;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (mode == 1) revert("feed down");
        if (mode == 2) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                mstore(0, 0)
                return(0, 64)
            }
        }
        if (mode == 3) {
            // solhint-disable-next-line no-inline-assembly
            assembly {
                mstore(0, 1)
                return(0, 192)
            }
        }
        return (1, answer, startedAt, startedAt, 1);
    }
}

/// @notice Code placed at a proxy's predicted address before it exists (reachable only through the address collision
/// REQ-PROXY-055 assumes away): it borrows or supplies on the Spoke as that address, then is removed.
contract AdapterSquatter {
    function supplyAs(
        address spoke,
        address token,
        uint256 reserveId,
        uint256 amount
    ) external {
        (bool ok,) = token.call(abi.encodeWithSignature("approve(address,uint256)", spoke, amount));
        require(ok, "approve");
        IAaveV4Spoke(spoke).supply(reserveId, amount, address(this));
    }

    function enableAs(
        address spoke,
        uint256 reserveId
    ) external {
        IAaveV4Spoke(spoke).setUsingAsCollateral(reserveId, true, address(this));
    }

    function borrowAs(
        address spoke,
        uint256 reserveId,
        uint256 amount
    ) external {
        IAaveV4Spoke(spoke).borrow(reserveId, amount, address(this));
    }
}

/// @notice A token-hook re-entrant caller: tries a call on `target` when invoked.
contract AdapterReenterer {
    address public target;
    bytes public data;
    bytes public lastError;
    bool public attempted;

    function arm(
        address t,
        bytes calldata d
    ) external {
        target = t;
        data = d;
    }

    function fire() external {
        attempted = true;
        (bool ok, bytes memory err) = target.call(data);
        require(!ok, "reentry succeeded");
        lastError = err;
    }

    function proxyExecute(
        address proxy,
        address t,
        bytes calldata d
    ) external returns (bytes memory) {
        return IPositionProxy(proxy).execute(t, d);
    }
}
