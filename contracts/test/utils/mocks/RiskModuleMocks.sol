// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {RiskStatus} from "../../../src/amm/types/AmmTypes.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPOracle} from "../../../src/oracle/ILPOracle.sol";
import {MarketSpeedLimits, SpeedLimit} from "../../../src/policy/parameter-store/types/ParameterStoreTypes.sol";
import {PriceState} from "../../../src/types/OracleTypes.sol";
import {PledgeCounters} from "../../../src/types/PositionTypes.sol";
import {DebtPriceView} from "./DebtPriceView.sol";
import {RegistryHubMock, RegistrySpokeMock} from "./MarketRegistryAaveMocks.sol";
import {
    RegistryAdapterMock,
    RegistryCollateralizationMock,
    RegistryDebtOracleMock,
    RegistryLPVaultMock,
    RegistryParameterStoreMock,
    RegistryTokenMock
} from "./MarketRegistryMocks.sol";

/// @title RiskHubMock
/// @notice The Aave V4 Hub reads of the MarketRegistry and the RiskModule, backed by settable storage.
contract RiskHubMock is RegistryHubMock {
    // Spokes listed on a Hub asset, for the (Hub, asset) speed window's base (Q-411).
    mapping(uint256 => mapping(address => bool)) public spokeListed;

    function setSpokeListed(
        uint256 assetId,
        address spoke,
        bool on
    ) external {
        spokeListed[assetId][spoke] = on;
    }

    function isSpokeListed(
        uint256 assetId,
        address spoke
    ) external view returns (bool) {
        return spokeListed[assetId][spoke];
    }

    mapping(uint256 => uint256) public addedAssets;
    mapping(uint256 => uint256) public addedShares;
    mapping(uint256 => uint256) public drawnShares;
    mapping(uint256 => address[]) internal _spokes;

    function setActive(
        uint256 assetId,
        address spoke,
        bool active,
        bool halted
    ) external {
        _spokeCfg[assetId][spoke].active = active;
        _spokeCfg[assetId][spoke].halted = halted;
    }

    function setThreshold(
        uint256 assetId,
        address spoke,
        uint24 threshold
    ) external {
        _spokeCfg[assetId][spoke].riskPremiumThreshold = threshold;
    }

    function setFeeReceiver(
        uint256 assetId,
        address receiver
    ) external {
        _assetCfg[assetId].feeReceiver = receiver;
    }

    function setSpokes(
        uint256 assetId,
        address[] calldata spokes
    ) external {
        _spokes[assetId] = spokes;
    }

    function setAdded(
        uint256 assetId,
        uint256 assets,
        uint256 shares
    ) external {
        addedAssets[assetId] = assets;
        addedShares[assetId] = shares;
    }

    function setDrawn(
        uint256 assetId,
        uint256 shares
    ) external {
        drawnShares[assetId] = shares;
    }

    function getAddedAssets(
        uint256 assetId
    ) external view returns (uint256) {
        return addedAssets[assetId];
    }

    function getAddedShares(
        uint256 assetId
    ) external view returns (uint256) {
        return addedShares[assetId];
    }

    function getAssetDrawnShares(
        uint256 assetId
    ) external view returns (uint256) {
        return drawnShares[assetId];
    }

    function getSpokeCount(
        uint256 assetId
    ) external view returns (uint256) {
        return _spokes[assetId].length;
    }

    function getSpokeAddress(
        uint256 assetId,
        uint256 index
    ) external view returns (address) {
        return _spokes[assetId][index];
    }

    function MAX_RISK_PREMIUM_THRESHOLD() external pure returns (uint24) {
        return type(uint24).max;
    }
}

/// @title RiskSpokeMock
/// @notice The Aave V4 Spoke reads of the MarketRegistry and the RiskModule: reserves and per-account state.
contract RiskSpokeMock is RegistrySpokeMock {
    uint256 public reserveCount;
    mapping(address => IAaveV4Spoke.UserAccountData) internal _account;
    mapping(address => mapping(uint256 => bool)) public collateralOf;
    mapping(address => mapping(uint256 => bool)) public borrowingOf;
    mapping(address => mapping(uint256 => uint256)) public suppliedShares;
    mapping(address => mapping(uint256 => uint32)) public userKey;
    mapping(address => mapping(uint256 => bool)) internal _userKeySet;

    function setReserveCount(
        uint256 n
    ) external {
        reserveCount = n;
    }

    function setDynamicAt(
        uint256 id,
        uint32 key,
        IAaveV4Spoke.DynamicReserveConfig memory d
    ) external {
        _dynamic[id][key] = d;
    }

    function setLatestKey(
        uint256 id,
        uint32 key
    ) external {
        _reserves[id].dynamicConfigKey = key;
    }

    function setCollateralRisk(
        uint256 id,
        uint24 risk
    ) external {
        _reserves[id].collateralRisk = risk;
    }

    function setImplSlot(
        bytes32 v
    ) external {
        implSlotValue = v;
    }

    function setAccount(
        address user,
        uint256 hf,
        uint256 debtRay,
        uint256 borrowCount
    ) external {
        _account[user].healthFactor = hf;
        _account[user].totalDebtValueRay = debtRay;
        _account[user].borrowCount = borrowCount;
    }

    function setStatus(
        address user,
        uint256 id,
        bool collateral,
        bool borrowing
    ) external {
        collateralOf[user][id] = collateral;
        borrowingOf[user][id] = borrowing;
    }

    function setSupplied(
        address user,
        uint256 id,
        uint256 shares
    ) external {
        suppliedShares[user][id] = shares;
    }

    function setUserKey(
        address user,
        uint256 id,
        uint32 key
    ) external {
        userKey[user][id] = key;
        _userKeySet[user][id] = true;
    }

    function getReserveCount() external view returns (uint256) {
        return reserveCount;
    }

    function getUserReserveStatus(
        uint256 id,
        address user
    ) external view returns (bool, bool) {
        return (collateralOf[user][id], borrowingOf[user][id]);
    }

    function getUserAccountData(
        address user
    ) external view returns (IAaveV4Spoke.UserAccountData memory a) {
        a = _account[user];
        if (a.borrowCount == 0 && a.healthFactor == 0) a.healthFactor = type(uint256).max;
    }

    function getUserSuppliedShares(
        uint256 id,
        address user
    ) external view returns (uint256) {
        return suppliedShares[user][id];
    }

    function getUserPosition(
        uint256 id,
        address user
    ) external view returns (IAaveV4Spoke.UserPosition memory p) {
        p.dynamicConfigKey = _userKeySet[user][id] ? userKey[user][id] : _reserves[id].dynamicConfigKey;
    }
}

/// @title RiskTokenMock
/// @notice A pool token or debt asset with settable decimals, `paused()` and Tether's fee rate.
contract RiskTokenMock is RegistryTokenMock {
    bool internal _paused;
    bool public pausedReverts;

    constructor(
        uint8 d
    ) RegistryTokenMock(d) {}

    function setPaused(
        bool p,
        bool rev
    ) external {
        _paused = p;
        pausedReverts = rev;
    }

    function paused() external view returns (bool) {
        require(!pausedReverts, "paused");
        return _paused;
    }
}

/// @title RiskStoreMock
/// @notice The ParameterStore views of the MarketRegistry and the RiskModule, backed by settable storage.
contract RiskStoreMock is RegistryParameterStoreMock {
    mapping(address => uint16) public tokenCollateralFactorBps;
    mapping(address => mapping(address => uint256)) public tokenUsdCap;
    mapping(address => uint32) public borrowPriceMaxAge;
    mapping(address => mapping(address => uint256)) public deficitMax;

    function setTokenCf(
        address token,
        uint16 cf
    ) external {
        tokenCollateralFactorBps[token] = cf;
    }

    function setTokenCap(
        address hub,
        address token,
        uint256 cap
    ) external {
        tokenUsdCap[hub][token] = cap;
    }

    function setBorrowAge(
        address feed,
        uint32 age
    ) external {
        borrowPriceMaxAge[feed] = age;
    }

    function setDeficitMax(
        address hub,
        address asset,
        uint256 v
    ) external {
        deficitMax[hub][asset] = v;
    }

    function setMinPledge(
        uint256 id,
        uint256 v
    ) external {
        _params[id].minPledgeUsd = v;
    }

    function setCaps(
        uint256 id,
        uint256 cap,
        uint256 slice,
        uint256 floorUsd
    ) external {
        marketUsdCap[id] = cap;
        topUpSliceUsd[id] = slice;
        stressFloorUsd[id] = floorUsd;
    }

    function minPledgeUsd(
        uint256 id
    ) external view returns (uint256) {
        return _params[id].minPledgeUsd;
    }

    // Speed limits (Q-411): unset scopes read as open (one-hour window, 100 %, no bound) so tests of other gates are not
    // throttled; a test that sets a value gets exactly that value, all zero included.
    mapping(uint256 => MarketSpeedLimits) internal _marketSpeed;
    mapping(uint256 => bool) internal _marketSpeedSet;
    mapping(address => mapping(address => SpeedLimit)) internal _debtSpeed;
    mapping(address => mapping(address => bool)) internal _debtSpeedSet;

    function setMarketSpeed(
        uint256 marketId,
        MarketSpeedLimits memory v
    ) external {
        _marketSpeed[marketId] = v;
        _marketSpeedSet[marketId] = true;
    }

    function setDebtSpeed(
        address hub,
        address asset,
        SpeedLimit memory v
    ) external {
        _debtSpeed[hub][asset] = v;
        _debtSpeedSet[hub][asset] = true;
    }

    function marketSpeedLimits(
        uint256 marketId
    ) external view returns (MarketSpeedLimits memory v) {
        if (_marketSpeedSet[marketId]) return _marketSpeed[marketId];
        uint96 big = type(uint96).max;
        v = MarketSpeedLimits(3600, 10_000, 10_000, big, big, big, big);
    }

    function debtSpeedLimit(
        address hub,
        address asset
    ) external view returns (SpeedLimit memory v) {
        if (_debtSpeedSet[hub][asset]) return _debtSpeed[hub][asset];
        v = SpeedLimit(10_000, 3600, type(uint96).max, type(uint96).max);
    }
}

/// @title RiskSwapMock
/// @notice LPVaultSwap's active keeper count.
contract RiskSwapMock {
    uint256 public activeKeeperCount = 1;

    function setKeepers(
        uint256 n
    ) external {
        activeKeeperCount = n;
    }
}

/// @notice Per-token part of a `RiskLPOracleMock` report.
struct RiskTokenReport {
    address token;
    uint32 reasons;
    uint256 quote;
    address[2] legFeeds;
    uint64[2] legUpdatedAt;
}

/// @notice The price report a `RiskLPOracleMock` serves its stateless views from.
struct RiskPriceReport {
    PriceState state;
    uint256 reasons;
    int256 answer;
    int256 freshAnswer;
    bool borrowAllowed;
    RiskTokenReport[] tokens;
}

/// @title RiskLPOracleMock
/// @notice An LPOracle for the MarketRegistry and the RiskModule: seed and binding, a settable price-state report, the
/// accepted price and a poke counter.
contract RiskLPOracleMock {
    uint8 public decimals = 8;
    uint256 public marketId;
    address public integration;
    uint256 public pokes;
    uint256 public accepted = 2e8;
    bool public pokeReverts;
    /// @notice The legs' borrow age limit; 0 leaves the legs' ages out of `borrowFresh`.
    uint64 public legMaxAge;
    RiskPriceReport internal _pv;

    constructor(
        uint256 id,
        address amm
    ) {
        marketId = id;
        integration = amm;
        _pv.state = PriceState.Live;
        _pv.answer = 2e8;
        _pv.borrowAllowed = true;
    }

    function setPrices(
        uint256 acceptedPrice,
        int256 served
    ) external {
        accepted = acceptedPrice;
        _pv.answer = served;
    }

    /// @notice The report's fresh price (0 reads as a failed market's).
    function setFresh(
        int256 fresh
    ) external {
        _pv.freshAnswer = fresh;
    }

    function setState(
        PriceState s,
        uint256 reasons,
        bool borrowAllowed
    ) external {
        _pv.state = s;
        _pv.reasons = reasons;
        _pv.borrowAllowed = borrowAllowed;
    }

    /// @notice As the LPOracle reads each leg's round age against its borrow limit: a leg older than `age` fails
    /// `borrowFresh`.
    function setLegMaxAge(
        uint64 age
    ) external {
        legMaxAge = age;
    }

    function setPokeReverts(
        bool r
    ) external {
        pokeReverts = r;
    }

    /// @dev Replaces the per-token report: `n` tokens, one leg each.
    function setTokens(
        address[] calldata tokens,
        address[] calldata feeds,
        uint64[] calldata updatedAt,
        uint256[] calldata quotes,
        uint32[] calldata reasons
    ) external {
        delete _pv.tokens;
        for (uint256 i = 0; i < tokens.length; ++i) {
            RiskTokenReport storage t = _pv.tokens.push();
            t.token = tokens[i];
            t.legFeeds[0] = feeds[i];
            t.legUpdatedAt[0] = updatedAt[i];
            t.quote = quotes[i];
            t.reasons = reasons[i];
        }
    }

    function latestAnswer() external view returns (int256) {
        return _pv.answer;
    }

    function lastAcceptedPrice() external view returns (uint256, uint64) {
        return (accepted, uint64(block.timestamp));
    }

    function poke() public virtual returns (PriceState) {
        require(!pokeReverts, "poke");
        ++pokes;
        return _pv.state;
    }

    /// @notice The stateless oracle's report: fresh to borrow while Live and allowed, to liquidate while Live or
    /// Drifting.
    function getPriceStatus() external view returns (ILPOracle.PriceStatus memory s) {
        s.answer = _pv.answer;
        s.updatedAt = uint64(block.timestamp);
        s.borrowFresh = _pv.state == PriceState.Live && _pv.borrowAllowed && _legsFresh();
        s.liquidationFresh = _pv.state == PriceState.Live || _pv.state == PriceState.Drifting;
    }

    function _legsFresh() internal view returns (bool) {
        if (legMaxAge == 0) return true;
        for (uint256 i = 0; i < _pv.tokens.length; ++i) {
            uint64 at = _pv.tokens[i].legUpdatedAt[0];
            if (at > block.timestamp || block.timestamp - at > legMaxAge) return false;
        }
        return true;
    }

    function getTokenPrices() external view returns (uint256[] memory prices, uint64 updatedAt) {
        prices = new uint256[](_pv.tokens.length);
        for (uint256 i = 0; i < prices.length; ++i) {
            prices[i] = _pv.tokens[i].quote;
        }
        updatedAt = uint64(block.timestamp);
    }
}

/// @title RiskDebtOracleMock
/// @notice A DebtOracle for the MarketRegistry and the RiskModule: identity, a settable report and a poke counter.
contract RiskDebtOracleMock is RegistryDebtOracleMock {
    uint256 public pokes;
    uint32 public borrowPriceMaxAge = 88_200;
    DebtPriceView internal _dv;

    constructor(
        address asset,
        address registry,
        address store
    ) RegistryDebtOracleMock(asset, registry, store) {
        _dv.state = PriceState.Live;
        _dv.borrowAllowed = true;
        _dv.servedUpdatedAt = uint64(block.timestamp);
    }

    function setReport(
        PriceState s,
        uint64 servedUpdatedAt,
        bool borrowAllowed
    ) external {
        _dv.state = s;
        _dv.servedUpdatedAt = servedUpdatedAt;
        _dv.borrowAllowed = borrowAllowed;
    }

    function getPriceState() external view returns (DebtPriceView memory) {
        return _dv;
    }

    function poke() external returns (PriceState) {
        ++pokes;
        return _dv.state;
    }

    /// @notice The debt source as a Chainlink feed: a current round while the report is Live, allowed and within
    /// `borrowPriceMaxAge`, otherwise a round at time 0.
    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        bool fresh = _dv.state == PriceState.Live && _dv.borrowAllowed && _dv.servedUpdatedAt <= block.timestamp
            && block.timestamp - _dv.servedUpdatedAt <= borrowPriceMaxAge;
        uint256 at = fresh ? block.timestamp : 0;
        return (0, latestAnswer, at, at, 0);
    }
}

/// @title RiskLPVaultMock
/// @notice The AMM integration as the MarketRegistry and the RiskModule see it: binding, depth, owner and validation.
contract RiskLPVaultMock is RegistryLPVaultMock {
    uint256 public depth = 2e13;
    bool public depthAvailable = true;
    mapping(bytes32 => address) public ownerOf;
    mapping(bytes32 => uint128) public unitsOf;
    bytes4 public validateError;
    bool public validateRevertsEmpty;

    error ShapeMismatch();

    constructor(
        uint32 id,
        address collateralization,
        address lock
    ) RegistryLPVaultMock(id, collateralization, lock) {}

    function setDepth(
        uint256 d,
        bool available
    ) external {
        depth = d;
        depthAvailable = available;
    }

    function setPosition(
        bytes32 key,
        address owner,
        uint128 units
    ) external {
        ownerOf[key] = owner;
        unitsOf[key] = units;
    }

    function setValidateError(
        bytes4 err
    ) external {
        validateError = err;
    }

    /// @dev Makes `validatePosition` revert with no return data (no selector).
    function setValidateRevertsEmpty(
        bool r
    ) external {
        validateRevertsEmpty = r;
    }

    function riskStatus(
        uint256,
        uint32
    ) external view returns (RiskStatus memory s) {
        s.depthUnits = depth;
        s.depthAvailable = depthAvailable;
    }

    function positionOwner(
        bytes32 key
    ) external view returns (address) {
        return ownerOf[key];
    }

    function validatePosition(
        uint256,
        address,
        bytes32 key
    ) external view returns (uint128) {
        if (validateRevertsEmpty) revert();
        if (validateError != bytes4(0)) revert ShapeMismatch();
        return unitsOf[key];
    }
}

/// @title RiskCollateralizationMock
/// @notice Collateralization views the RiskModule reads: rescue units, pool units, counters and record counts.
contract RiskCollateralizationMock is RegistryCollateralizationMock {
    mapping(address => uint256) public rescueOf;
    mapping(address => uint256) public openRecords;
    PledgeCounters internal _counters;

    constructor(
        address lock
    ) RegistryCollateralizationMock(lock) {}

    function setRescue(
        address proxy,
        uint256 units
    ) external {
        rescueOf[proxy] = units;
    }

    function setOpenRecords(
        address proxy,
        uint256 n
    ) external {
        openRecords[proxy] = n;
    }

    function setCounters(
        PledgeCounters calldata k
    ) external {
        _counters = k;
    }

    function getAccountRescueUnits(
        address proxy,
        address
    ) external view returns (uint256) {
        return rescueOf[proxy];
    }

    function getCounters(
        address,
        address
    ) external view returns (PledgeCounters memory) {
        return _counters;
    }

    function getOpenRecordCount(
        address proxy,
        address
    ) external view returns (uint256) {
        return openRecords[proxy];
    }
}

/// @title RiskAdapterMock
/// @notice The AaveAdapter's proxy resolution read by `previewPledge`.
contract RiskAdapterMock is RegistryAdapterMock {
    mapping(address => mapping(uint256 => address)) public proxyOf;
    mapping(address => mapping(uint256 => address)) public predicted;

    function setProxy(
        address wallet,
        uint256 marketId,
        address proxy,
        bool deployed
    ) external {
        if (deployed) proxyOf[wallet][marketId] = proxy;
        predicted[wallet][marketId] = proxy;
    }

    function predictProxy(
        address wallet,
        uint256 marketId
    ) external view returns (address) {
        return predicted[wallet][marketId];
    }
}
