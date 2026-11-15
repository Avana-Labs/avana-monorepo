// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {Pending} from "../../../src/custody/collateralization/types/Pending.sol";
import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {Lock} from "../../../src/lock/lock/Lock.sol";
import {AaveAdapterStorage} from "../../../src/policy/aave-adapter/AaveAdapterStorage.sol";
import {AaveAdapterImmutables} from "../../../src/policy/aave-adapter/types/AaveAdapterImmutables.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {SpokeDef} from "../../../src/policy/market-registry/types/SpokeDef.sol";
import {RiskModuleMath} from "../../../src/policy/risk-module/RiskModuleMath.sol";
import {PositionProxy} from "../../../src/proxy/position-proxy/PositionProxy.sol";
import {Market} from "../../../src/types/Market.sol";
import {PauseReason} from "../../../src/types/PauseReason.sol";
import {PauseState} from "../../../src/types/PauseState.sol";

// Stand-ins and the shared base of the AaveAdapter path harnesses (`AaveAdapterBorrowProperties` and
// `AaveAdapterWithdrawProperties`). This file declares no `*Properties` contract, so the runners never fuzz it alone.

/// @notice An ERC-20 with open mint and burn (only the harness's entry points are fuzzed) and the vault-token views
/// and proxy registry the AaveAdapter uses, answered for the harness's one market (market 1, integration 7).
contract BorToken {
    address public immutable hub;
    address public immutable spoke;
    uint256 public constant marketId = 1;
    uint32 public constant integrationId = 7;
    uint256 public totalSupply;
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;
    mapping(address proxy => bool valid) public isValidProxy;

    constructor(
        address world
    ) {
        (hub, spoke) = (world, world);
    }

    function addValidProxy(
        address proxy
    ) external {
        isValidProxy[proxy] = true;
    }

    function mint(
        address to,
        uint256 amount
    ) external {
        totalSupply += amount;
        balanceOf[to] += amount;
    }

    function burn(
        address from,
        uint256 amount
    ) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }

    function approve(
        address spender,
        uint256 amount
    ) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(
        address to,
        uint256 amount
    ) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @notice The chain around the AaveAdapter at one address: the CDP Spoke (vault-token reserve 0, USDC reserve 1),
/// its Hub, the MarketRegistry (market 1, debt reserve 1, the pause state and the address freeze), the
/// VaultTokenFactory, the ProxyManager (deploying the real `PositionProxy`), Collateralization (records credited at
/// the units the harness sets, debt mark) and the RiskModule's borrow-side checks.
/// @dev The Spoke values a vault token (1e18 units) at `price` (8 decimals) with an 80 % collateral factor and USDC
/// at $1, and refuses a borrow or a withdrawal that leaves HF below 1, as Aave does. The RiskModule stand-in's
/// `postHealthCheck` reads that HF and requires `RiskModuleMath.requiredHealthFactor(hardFloor, minHealthFactor)`
/// (the hard floor is 1.10), as `RiskModuleBorrowLogic.postHealthCheck` does at an accepted price equal to the served
/// one; its pre-checks admit every call.
contract BorWorld {
    uint256 internal constant CF = 8000;
    uint256 public constant HARD_FLOOR = 1.1e18;

    BorToken public vt;
    BorToken public usdc;
    address internal adapter;
    /// @dev Creates the proxies, so their ProxyManager (the creator, which `PositionProxy.execute` refuses as a
    /// target) is not this contract, which is also the Spoke they call.
    BorProxyFactory internal immutable PROXIES = new BorProxyFactory();

    uint256 public price = 1000e8;
    PauseState public state;
    PauseReason public reason;
    uint256 public nextCredit;
    uint256 public totalCredited;
    uint256 internal records;
    mapping(address account => bool frozen) public isFrozenAddress;
    mapping(address proxy => uint256 units) public supplied;
    mapping(address proxy => uint256 amount) public debt;
    mapping(address proxy => bool enabled) public collateralOn;
    mapping(address proxy => mapping(bytes32 key => uint256 units)) public creditOf;

    function init(
        BorToken vt_,
        BorToken usdc_
    ) external {
        require(adapter == address(0), "set");
        (vt, usdc, adapter) = (vt_, usdc_, msg.sender);
    }

    // ─── Harness controls ───

    function setPrice(
        uint256 p
    ) external {
        price = p;
    }

    function setPause(
        PauseState s,
        PauseReason r
    ) external {
        (state, reason) = (s, r);
    }

    function setFrozen(
        address account,
        bool frozen
    ) external {
        isFrozenAddress[account] = frozen;
    }

    function setNextCredit(
        uint256 units
    ) external {
        nextCredit = units;
    }

    function accrue(
        address proxy,
        uint256 amount
    ) external {
        debt[proxy] += amount;
    }

    /// @notice Clears an account's debt, as a repay outside the logic under test would.
    function clearDebt(
        address proxy
    ) external {
        debt[proxy] = 0;
    }

    /// @notice A record of `units` credited, minted and supplied as collateral, and `amount` of debt, booked
    /// directly (the pledge and borrow steps are `AaveAdapterBorrowProperties`').
    function seed(
        address proxy,
        bytes32 key,
        uint256 units,
        uint256 amount
    ) external {
        creditOf[proxy][key] += units;
        totalCredited += units;
        supplied[proxy] += units;
        collateralOn[proxy] = true;
        debt[proxy] += amount;
        vt.mint(address(this), units);
    }

    // ─── Spoke ───

    function healthFactor(
        address user
    ) public view returns (uint256) {
        uint256 d = debt[user];
        if (d == 0) return type(uint256).max;
        return supplied[user] * price / 1e18 * CF * 1e14 / (d * 100);
    }

    function getUserAccountData(
        address user
    ) external view returns (IAaveV4Spoke.UserAccountData memory a) {
        a.healthFactor = healthFactor(user);
        a.borrowCount = debt[user] == 0 ? 0 : 1;
        a.activeCollateralCount = collateralOn[user] && supplied[user] != 0 ? 1 : 0;
        a.totalDebtValueRay = debt[user] * 1e2 * 1e27;
    }

    function getReserveId(
        address,
        uint256
    ) external pure returns (uint256) {
        return 0;
    }

    function getReserveCount() external pure returns (uint256) {
        return 2;
    }

    function getReserve(
        uint256 reserveId
    ) external view returns (IAaveV4Spoke.Reserve memory r) {
        r.underlying = reserveId == 1 ? address(usdc) : address(vt);
        r.hub = address(this);
    }

    function getReserveConfig(
        uint256
    ) external pure returns (IAaveV4Spoke.ReserveConfig memory c) {}

    function getUserReserveStatus(
        uint256 reserveId,
        address user
    ) external view returns (bool, bool) {
        return reserveId == 0 ? (collateralOn[user], false) : (false, debt[user] != 0);
    }

    function getUserSuppliedShares(
        uint256 reserveId,
        address user
    ) external view returns (uint256) {
        return reserveId == 0 ? supplied[user] : 0;
    }

    function getUserTotalDebt(
        uint256 reserveId,
        address user
    ) external view returns (uint256) {
        return reserveId == 1 ? debt[user] : 0;
    }

    function setUsingAsCollateral(
        uint256,
        bool on,
        address onBehalfOf
    ) external {
        require(msg.sender == onBehalfOf, "position manager");
        collateralOn[onBehalfOf] = on;
    }

    function supply(
        uint256,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256) {
        require(msg.sender == onBehalfOf, "position manager");
        vt.transferFrom(msg.sender, address(this), amount);
        supplied[onBehalfOf] += amount;
        return (amount, amount);
    }

    function withdraw(
        uint256,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256) {
        require(msg.sender == onBehalfOf, "position manager");
        supplied[onBehalfOf] -= amount;
        require(healthFactor(onBehalfOf) >= 1e18, "HF");
        vt.transfer(msg.sender, amount);
        return (amount, amount);
    }

    function borrow(
        uint256,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256) {
        require(msg.sender == onBehalfOf && collateralOn[onBehalfOf], "position manager");
        debt[onBehalfOf] += amount;
        require(healthFactor(onBehalfOf) >= 1e18, "HF");
        usdc.mint(msg.sender, amount);
        return (amount, amount);
    }

    function repay(
        uint256,
        uint256 amount,
        address onBehalfOf
    ) external returns (uint256, uint256) {
        uint256 pay = amount < debt[onBehalfOf] ? amount : debt[onBehalfOf];
        usdc.transferFrom(msg.sender, address(this), pay);
        debt[onBehalfOf] -= pay;
        return (pay, pay);
    }

    // ─── Hub ───

    function getAssetId(
        address
    ) external pure returns (uint256) {
        return 0;
    }

    function isSpokeListed(
        uint256,
        address account
    ) external view returns (bool) {
        return account == address(this);
    }

    function isUnderlyingListed(
        address account
    ) external view returns (bool) {
        return account == address(usdc) || account == address(vt);
    }

    // ─── MarketRegistry and VaultTokenFactory ───

    function getMarket(
        uint256
    ) external view returns (Market memory m) {
        (m.hub, m.spoke, m.integrationId, m.vaultToken, m.decimals) = (address(this), address(this), 7, address(vt), 18);
    }

    function pauseState(
        address
    ) external view returns (PauseState) {
        return state;
    }

    function pauseReason(
        address
    ) external view returns (PauseReason) {
        return reason;
    }

    function getSpoke(
        address s
    ) external view returns (SpokeDef memory def) {
        def.approved = s == address(this);
        def.hub = address(this);
    }

    function isApprovedDebtReserve(
        address,
        uint256 reserveId
    ) external pure returns (bool) {
        return reserveId == 1;
    }

    function getDebtReserve(
        address,
        uint256
    ) external view returns (DebtReserveDef memory d) {
        (d.reserveId, d.asset, d.decimals, d.fundingHub, d.hubAssetId) = (1, address(usdc), 6, address(this), 1);
        (d.fixedPrice, d.approved) = (true, true);
    }

    function integrationIdOf(
        address
    ) external pure returns (uint32) {
        return 0;
    }

    function PAYOUT_ESCROW() external pure returns (address) {
        return address(0xE5C0);
    }

    function flashSource() external pure returns (address) {
        return address(0xF1A5);
    }

    function isRecordedHub(
        address account
    ) external view returns (bool) {
        return account == address(this);
    }

    function isVaultToken(
        address token
    ) external view returns (bool) {
        return token == address(vt);
    }

    // ─── ProxyManager ───

    function deployProxy(
        address wallet,
        address spoke,
        uint256 marketId
    ) external returns (address) {
        require(msg.sender == adapter, "adapter");
        return PROXIES.deploy(adapter, wallet, spoke, marketId);
    }

    // ─── Collateralization ───

    function pledge(
        address,
        address proxy,
        address,
        bytes32 key,
        bool requireRescue
    ) external returns (uint256 recordId, uint128 credited) {
        // A pledge that must be a rescue top-up is refused: the stand-in books no rescue units.
        require(!requireRescue, "rescue");
        credited = uint128(nextCredit);
        nextCredit = 0;
        creditOf[proxy][key] += credited;
        totalCredited += credited;
        recordId = ++records;
    }

    function release(
        address proxy,
        address,
        bytes32 key,
        uint256 units
    ) external {
        creditOf[proxy][key] -= units;
        totalCredited -= units;
    }

    function markIndebted(
        address
    ) external pure {}

    function markDebtFree(
        address
    ) external pure {}

    function getTotalCredited(
        address
    ) external view returns (uint256) {
        return totalCredited;
    }

    function getPending(
        address
    ) external pure returns (Pending memory p) {}

    // ─── RiskModule borrow-side checks ───

    function preBorrowCheck(
        address,
        uint256,
        uint256
    ) external pure {}

    function preWithdrawCheck(
        address
    ) external pure {}

    function postHealthCheck(
        address proxy,
        uint256 minHealthFactor
    ) external view returns (uint256 hf) {
        hf = healthFactor(proxy);
        uint256 required = RiskModuleMath.requiredHealthFactor(HARD_FLOOR, minHealthFactor);
        require(hf >= required, "HealthFactorTooLow");
    }
}

/// @notice The proxy-creating part of the ProxyManager stand-in. A `PositionProxy` records its creator as the
/// ProxyManager and never calls it; with `BorWorld` as the creator every proxy call to the Spoke stand-in (also
/// `BorWorld`) reverted `InvalidTarget`.
contract BorProxyFactory {
    function deploy(
        address adapter,
        address wallet,
        address spoke,
        uint256 marketId
    ) external returns (address) {
        return address(new PositionProxy(adapter, wallet, spoke, marketId));
    }
}

/// @notice A borrower wallet or a third-party payer: an account only the harness drives.
contract BorActor {
    address internal immutable OWNER = msg.sender;

    function exec(
        address target,
        bytes calldata data
    ) external returns (bool ok, bytes memory ret) {
        require(msg.sender == OWNER, "owner");
        (ok, ret) = target.call(data);
    }
}

/// @notice The shared part of the AaveAdapter path harnesses: the harness stands at the AaveAdapter's address with
/// the Adapter's ERC-7201 storage, as the `AaveAdapter` router does, and its `fallback` forwards the selectors a
/// derived harness serves (`_logicFor`) by delegatecall to the production logic contract, with the calldata unchanged.
/// It deploys `BorWorld`, the real `Lock` (members: this harness and an LPVaultSwap address), the vault token, USDC,
/// three wallets and a third-party payer; it holds the booked debt and credit per account and the common entry points
/// and properties.
abstract contract AaveAdapterPathHarness is AaveAdapterStorage {
    uint256 internal constant MARKET = 1;
    uint256 internal constant DEBT_RESERVE = 1;
    uint32 internal constant INTEGRATION = 7;
    uint256 internal constant MAX_KEYS = 4;
    uint256 internal constant HARD_FLOOR = 1.1e18;

    uint256 internal constant BAD_HEALTH = 1;
    uint256 internal constant BAD_FORWARD = 2;
    uint256 internal constant BAD_GATE = 4;
    uint256 internal constant BAD_REPAY = 8;
    uint256 internal constant BAD_SUPPLY = 16;

    BorWorld internal immutable W;
    BorToken internal immutable VT;
    BorToken internal immutable USDC;
    BorActor internal immutable WALLET0;
    BorActor internal immutable WALLET1;
    BorActor internal immutable WALLET2;
    BorActor internal immutable PAYER;

    /// @dev Set while the constructor builds the Adapter immutables; read by the derived constructors.
    BorWorld internal _world;
    Lock internal _lock;

    /// @notice Debt the harness booked per account: borrowed (or seeded) plus accrued less what repays spent.
    uint256[3] public booked;
    /// @notice Credited units the harness booked per account.
    uint256[3] public credited;
    bytes32[MAX_KEYS][3] internal keys;
    uint256 internal keyNonce;
    /// @notice Bit set of broken properties (the `BAD_` constants); never reset.
    uint256 public violations;
    /// @notice Calls and completed calls per action entry point, in the order the derived harness documents.
    uint256[4] public tried;
    uint256[4] public done;
    bytes4 public lastFailure;

    constructor() AaveAdapterStorage(_immutables()) {
        W = _world;
        VT = new BorToken(address(_world));
        USDC = new BorToken(address(_world));
        _world.init(VT, USDC);
        WALLET0 = new BorActor();
        WALLET1 = new BorActor();
        WALLET2 = new BorActor();
        PAYER = new BorActor();
    }

    /// @dev The Adapter immutables every logic contract of the harness is built with.
    function _adapterImmutables() internal view returns (AaveAdapterImmutables memory) {
        address world = address(_world);
        return AaveAdapterImmutables({
            proxyManager: world,
            collateralization: world,
            riskModule: world,
            marketRegistry: world,
            parameterStore: world,
            lpVaultSwap: address(0x5A1),
            lock: address(_lock),
            vaultTokenFactory: world,
            timelock: address(this)
        });
    }

    function _immutables() private returns (AaveAdapterImmutables memory) {
        _world = new BorWorld();
        _lock = new Lock(address(this), address(0x5A1));
        return _adapterImmutables();
    }

    /// @dev The logic contract serving selector `s`, or zero.
    function _logicFor(
        bytes4 s
    ) internal view virtual returns (address);

    /// @notice The Adapter selectors this harness serves, forwarded to their logic contract by delegatecall.
    fallback() external {
        address logic = _logicFor(msg.sig);
        require(logic != address(0), "selector");
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), logic, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // ─── Helpers ───

    function _index(
        uint8 who
    ) internal pure returns (uint256 i) {
        i = who & 3;
        if (i == 3) i = 0;
    }

    function _wallet(
        uint256 i
    ) internal view returns (BorActor) {
        if (i == 0) return WALLET0;
        if (i == 1) return WALLET1;
        return WALLET2;
    }

    function _proxyOf(
        uint256 i
    ) internal view returns (address) {
        return _s().proxyOf[address(_wallet(i))][MARKET];
    }

    /// @dev Records `bit` when `good` is false, then asserts it, so property mode, assertion mode and Medusa all see
    /// a violation.
    function _ensure(
        uint256 bit,
        bool good
    ) internal {
        if (!good) violations |= bit;
        assert(good);
    }

    /// @dev `RiskModuleMath.requiredHealthFactor` with the stand-in's hard floor.
    function _required(
        uint256 minHf
    ) internal pure returns (uint256) {
        return RiskModuleMath.requiredHealthFactor(HARD_FLOOR, minHf);
    }

    /// @dev `minHealthFactor` 0, 1.2, 1.5 or 1.
    function _minHf(
        uint8 m
    ) internal pure returns (uint256) {
        uint256 k = m & 3;
        return k == 0 ? 0 : (k == 1 ? 1.2e18 : (k == 2 ? 1.5e18 : 1e18));
    }

    /// @dev Calls this harness (the Adapter) as wallet or payer `a`; keeps the selector of a refusal.
    function _call(
        BorActor a,
        bytes memory data
    ) internal returns (bool ok) {
        bytes memory ret;
        (ok, ret) = a.exec(address(this), data);
        if (!ok && ret.length >= 4) lastFailure = bytes4(ret);
    }

    // ─── Common entry points ───

    /// @notice The vault token's price moves to 70 %, 90 %, 97 %, 103 %, 110 % or 130 % of its current value, or
    /// back to $1,000 (`move`).
    function movePrice(
        uint8 move
    ) external {
        uint256 k = move & 7;
        uint256 p = W.price();
        uint256 bps = k == 0 ? 7000 : (k == 1 ? 9000 : (k == 2 ? 9700 : (k == 3 ? 10_300 : (k == 4 ? 11_000 : 13_000))));
        p = k >= 6 ? 1000e8 : p * bps / 1e4;
        W.setPrice(p == 0 ? 1 : p);
    }

    /// @notice Interest of 0.5 %, 2 %, 5 % or 10 % on account `who`'s debt (`rate`).
    function accrue(
        uint8 who,
        uint8 rate
    ) external {
        uint256 i = _index(who);
        address p = _proxyOf(i);
        if (p == address(0)) return;
        uint256 k = rate & 3;
        uint256 amount = W.debt(p) * (k == 0 ? 50 : (k == 1 ? 200 : (k == 2 ? 500 : 1000))) / 1e4;
        W.accrue(p, amount);
        booked[i] += amount;
    }

    /// @notice The Hub's application pause state (None, Frozen, Paused General, Paused MintPathSuspect) and the
    /// freeze of wallet `who`.
    function setStops(
        uint8 pause,
        uint8 who,
        bool frozen
    ) external {
        uint256 k = pause & 3;
        if (k == 0) W.setPause(PauseState.None, PauseReason.General);
        else if (k == 1) W.setPause(PauseState.Frozen, PauseReason.General);
        else if (k == 2) W.setPause(PauseState.Paused, PauseReason.General);
        else W.setPause(PauseState.Paused, PauseReason.MintPathSuspect);
        W.setFrozen(address(_wallet(_index(who))), frozen);
    }

    // ─── Common properties ───

    /// @notice INV-025: every borrow and every withdrawal with debt left HF at least max(1, hard floor, minHF).
    function property_healthAfterEveryGatedAction() external view returns (bool) {
        return violations & BAD_HEALTH == 0;
    }

    /// @notice Each account's debt on the Spoke is what it borrowed (or was seeded with) and accrued less what its
    /// repays spent.
    function property_debtMatchesSpoke() external view returns (bool) {
        for (uint256 i = 0; i < 3; ++i) {
            address p = _proxyOf(i);
            if (p != address(0) && W.debt(p) != booked[i]) return false;
        }
        return true;
    }

    /// @notice INV-003, INV-008: each proxy's supplied units are its credited units, and the vault token's supply,
    /// the Spoke's balance and Collateralization's credited total are their sum.
    function property_supplyMatchesCredit() external view returns (bool) {
        if (violations & BAD_SUPPLY != 0) return false;
        uint256 sum = 0;
        for (uint256 i = 0; i < 3; ++i) {
            address p = _proxyOf(i);
            if (p == address(0)) continue;
            if (W.supplied(p) != credited[i]) return false;
            sum += credited[i];
        }
        return VT.totalSupply() == sum && VT.balanceOf(address(W)) == sum && W.totalCredited() == sum;
    }

    /// @notice INV-021: the Adapter and every proxy hold no token and leave no allowance to the Spoke.
    function property_noTokensLeftBehind() external view returns (bool) {
        if (VT.balanceOf(address(this)) != 0 || USDC.balanceOf(address(this)) != 0) return false;
        for (uint256 i = 0; i < 3; ++i) {
            address p = _proxyOf(i);
            if (p == address(0)) continue;
            if (VT.balanceOf(p) != 0 || USDC.balanceOf(p) != 0) return false;
            if (VT.allowance(p, address(W)) != 0 || USDC.allowance(p, address(W)) != 0) return false;
        }
        return true;
    }

    /// @notice The Lock is free and the repay-with-collateral session empty between transactions.
    function property_lockFreeAndSessionEmpty() external view returns (bool) {
        (address proxy,,,,,, uint256 steps) = _session();
        return !_lock.isLocked() && proxy == address(0) && steps == 0;
    }
}
