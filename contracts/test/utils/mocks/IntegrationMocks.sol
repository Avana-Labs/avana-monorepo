// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketStatus} from "../../../src/policy/market-registry/types/MarketStatus.sol";
import {SpokeDef} from "../../../src/policy/market-registry/types/SpokeDef.sol";
import {TokenDef} from "../../../src/policy/market-registry/types/TokenDef.sol";
import {Market} from "../../../src/types/Market.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";
import {RiskStoreMock} from "./RiskModuleMocks.sol";

/// @notice One MarketRegistry stand-in for every reader of the integration world: the AaveAdapter, the RiskModule,
/// LPVaultSwap, the Lens, the ProxyManager and the flash liquidation helper all read the same records, so a market,
/// debt reserve, route, pause state or freeze set here is what each of them sees in the same block.
contract IntegRegistryMock {
    struct Route {
        address route;
        bool usable;
    }

    mapping(uint256 => Market) internal _markets;
    mapping(uint256 => bool) internal _marketKnown;
    mapping(address => uint256[]) internal _spokeMarkets;
    mapping(address => mapping(uint256 => uint256)) public marketOfReserveMap;
    mapping(address => uint256) public marketOfVaultToken;
    uint256 public marketCount;
    mapping(address => SpokeDef) internal _spokes;
    address[] internal _spokeList;
    mapping(address => address) public hubOf;
    mapping(address => PauseState) public pauseStateOf;
    mapping(address => PauseReason) public pauseReasonOf;
    mapping(address => bool) public frozen;
    mapping(address => mapping(uint256 => DebtReserveDef)) internal _debt;
    mapping(address => mapping(uint256 => bool)) internal _debtKnown;
    mapping(address => uint256[]) internal _debtIds;
    mapping(address => uint32) public integrationIdOfMap;
    mapping(address => bool) public recordedHub;
    mapping(bytes32 => Route) internal _routes;
    mapping(bytes32 => uint32) public latched;
    mapping(bytes32 => uint64) public lastBreachAt;
    mapping(uint256 => uint256) public settlementReserve;
    mapping(address => mapping(address => address)) public firstLossReserveOf;
    address public payoutEscrow;
    address public flashSourceAddr;
    bool public implementationStale;
    bool public crossHubLinesEnabled;

    // ─── Setters ───

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
        marketOfVaultToken[m.vaultToken] = marketId;
        if (marketId > marketCount) marketCount = marketId;
    }

    function setMarketStatus(
        uint256 marketId,
        MarketStatus status
    ) external {
        _markets[marketId].status = status;
    }

    function setSpoke(
        address spoke,
        SpokeDef calldata def
    ) external {
        if (_spokes[spoke].hub == address(0)) _spokeList.push(spoke);
        _spokes[spoke] = def;
        hubOf[spoke] = def.hub;
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

    function setRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        address route,
        bool usable
    ) external {
        _routes[keccak256(abi.encode(marketId, token, debtAsset, kind))] = Route(route, usable);
    }

    function setRouteUsable(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind,
        bool usable
    ) external {
        _routes[keccak256(abi.encode(marketId, token, debtAsset, kind))].usable = usable;
    }

    function setLatched(
        bytes32 key,
        uint32 reasons,
        uint64 at
    ) external {
        latched[key] = reasons;
        lastBreachAt[key] = at;
    }

    function setSettlementReserve(
        uint256 marketId,
        uint256 reserveId
    ) external {
        settlementReserve[marketId] = reserveId;
    }

    function setAvanaFirstLossReserve(
        address hub,
        address asset,
        address spoke
    ) external {
        firstLossReserveOf[hub][asset] = spoke;
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

    // ─── Views ───

    function getMarket(
        uint256 marketId
    ) external view returns (Market memory) {
        return _markets[marketId];
    }

    function marketsOfSpoke(
        address spoke
    ) external view returns (uint256[] memory) {
        return _spokeMarkets[spoke];
    }

    function marketOfReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (uint256) {
        return marketOfReserveMap[spoke][reserveId];
    }

    function getSpoke(
        address spoke
    ) external view returns (SpokeDef memory) {
        return _spokes[spoke];
    }

    function getSpokes() external view returns (address[] memory) {
        return _spokeList;
    }

    function pauseState(
        address hub
    ) external view returns (PauseState) {
        return pauseStateOf[hub];
    }

    function pauseReason(
        address hub
    ) external view returns (PauseReason) {
        return pauseReasonOf[hub];
    }

    function isFrozenAddress(
        address account
    ) external view returns (bool) {
        return frozen[account];
    }

    function getDebtReserveIds(
        address spoke
    ) external view returns (uint256[] memory) {
        return _debtIds[spoke];
    }

    function getDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (DebtReserveDef memory) {
        return _debt[spoke][reserveId];
    }

    function isApprovedDebtReserve(
        address spoke,
        uint256 reserveId
    ) external view returns (bool) {
        return _debt[spoke][reserveId].approved;
    }

    function getToken(
        address
    ) external pure returns (TokenDef memory def) {
        return def;
    }

    function getRoute(
        uint256 marketId,
        address token,
        address debtAsset,
        uint8 kind
    ) external view returns (address route, bool usable) {
        Route memory r = _routes[keccak256(abi.encode(marketId, token, debtAsset, kind))];
        (route, usable) = (r.route, r.usable);
    }

    function spokeImplementationStatus(
        address
    ) external view returns (address implementation, bytes32 codeHash, bool current) {
        current = !implementationStale;
        (implementation, codeHash) = (address(0), bytes32(0));
    }

    function marketBreaker(
        uint256 marketId
    ) external view returns (uint32, uint64) {
        bytes32 key = bytes32(marketId);
        return (latched[key], lastBreachAt[key]);
    }

    function debtBreaker(
        address spoke,
        uint256 debtReserveId
    ) external view returns (uint32, uint64) {
        bytes32 key = keccak256(abi.encode(spoke, debtReserveId));
        return (latched[key], lastBreachAt[key]);
    }

    function recordBreach(
        bytes32 key,
        uint32 reasons
    ) external {
        latched[key] |= reasons;
        lastBreachAt[key] = uint64(block.timestamp);
    }

    function creditLine(
        address,
        address
    ) external pure returns (uint256 line, uint256 drawCapSum) {
        (line, drawCapSum) = (1, 0);
    }

    function creditLineCoverage(
        address,
        address
    ) external pure returns (uint256 required, uint256 funded) {
        (required, funded) = (0, 0);
    }

    function integrationIdOf(
        address lpVault
    ) external view returns (uint32) {
        return integrationIdOfMap[lpVault];
    }

    function isRecordedHub(
        address account
    ) external view returns (bool) {
        return recordedHub[account];
    }

    function PAYOUT_ESCROW() external view returns (address) {
        return payoutEscrow;
    }

    function flashSource() external view returns (address) {
        return flashSourceAddr;
    }
}

/// @notice One ParameterStore stand-in for the integration world: the RiskModule's views (`RiskStoreMock`) plus the
/// settlement values LPVaultSwap reads and the sizing values the Lens reads, at the launch values of 2.11.
contract IntegStoreMock is RiskStoreMock {
    mapping(address => uint256) public floorRoundingAllowance;
    mapping(address => uint32) internal _liquidationAge;
    uint16 public avanaFeeShareBps = 2000;
    uint16 public maxShortfallBps = 1000;
    address public feeRecipient;
    uint256 public graceHealthFactor = 0.95e18;
    uint32 public defaultLiquidationAge = 88_200;

    function setSlippage(
        uint256 marketId,
        uint16 bps
    ) external {
        _params[marketId].slippageAllowanceBps = bps;
    }

    function setFloorRoundingAllowance(
        address asset,
        uint256 value
    ) external {
        floorRoundingAllowance[asset] = value;
    }

    function setFeeRecipient(
        address v
    ) external {
        feeRecipient = v;
    }

    function setGraceHealthFactor(
        uint256 v
    ) external {
        graceHealthFactor = v;
    }

    function setLiquidationPriceMaxAge(
        address feed,
        uint32 age
    ) external {
        _liquidationAge[feed] = age;
    }

    function liquidationPriceMaxAge(
        address feed
    ) external view returns (uint32) {
        uint32 age = _liquidationAge[feed];
        return age == 0 ? defaultLiquidationAge : age;
    }
}
