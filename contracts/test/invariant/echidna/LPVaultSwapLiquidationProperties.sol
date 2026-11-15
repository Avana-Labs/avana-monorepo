// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Copyright (c) 2026 Avana Labs

import {IAaveV4Spoke} from "../../../src/interfaces/external/aave/IAaveV4Spoke.sol";
import {ILPVaultSwapLiquidation} from "../../../src/liquidation/lp-vault-swap/ILPVaultSwapLiquidation.sol";
import {LPVaultSwapLiquidationLogic} from "../../../src/liquidation/lp-vault-swap/LPVaultSwapLiquidationLogic.sol";
import {LPVaultSwapImmutables} from "../../../src/liquidation/lp-vault-swap/types/LPVaultSwapImmutables.sol";
import {LiquidationParams} from "../../../src/liquidation/lp-vault-swap/types/LiquidationParams.sol";
import {LiquidationResult} from "../../../src/liquidation/lp-vault-swap/types/LiquidationResult.sol";
import {RouteMode} from "../../../src/liquidation/lp-vault-swap/types/RouteMode.sol";
import {PayoutEscrow} from "../../../src/liquidation/payout-escrow/PayoutEscrow.sol";
import {DebtReserveDef} from "../../../src/policy/market-registry/types/DebtReserveDef.sol";
import {MarketParams} from "../../../src/policy/parameter-store/types/MarketParams.sol";
import {Market} from "../../../src/types/Market.sol";
import {PriceState} from "../../../src/types/PriceState.sol";

/// @notice An ERC-20 with open mint and burn (only the harness's entry points are fuzzed), a per-recipient block that
/// makes a transfer to that address revert (so a payout goes to the PayoutEscrow), and the four vault-token views
/// LPVaultSwap reads (`hub`, `spoke`, `marketId`, `isValidProxy`), answered for the one market of the harness.
contract LiqToken {
    uint8 public immutable decimals;
    address public immutable hub;
    address public immutable spoke;
    uint256 public constant marketId = 1;
    uint256 public totalSupply;
    mapping(address account => uint256 amount) public balanceOf;
    mapping(address owner => mapping(address spender => uint256 amount)) public allowance;
    mapping(address account => bool refused) public blocked;

    constructor(
        uint8 d,
        address world
    ) {
        (decimals, hub, spoke) = (d, world, world);
    }

    function isValidProxy(
        address proxy
    ) external pure returns (bool) {
        return proxy != address(0);
    }

    function setBlocked(
        address account,
        bool refused
    ) external {
        blocked[account] = refused;
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
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(
        address from,
        address to,
        uint256 amount
    ) private {
        require(!blocked[to], "blocked");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// @notice The rest of the chain LPVaultSwap calls in a liquidation, at one address: the CDP Spoke and its Aave
/// oracle, the Hub, the MarketRegistry (market 1, debt reserve 1, two routes per token), the ParameterStore, the
/// market's LPOracle, Collateralization (seizure and settlement) and the AaveAdapter (`burnSeized`, `walletOf`).
/// @dev Market 1: vault token `VT` (18 decimals) over a pool of USDC (6 decimals, also the debt asset) and `X`
/// (18 decimals); one vault token (1e18 units) holds 100 USDC and 9 X, so its price is `100 + 9 × px` dollars. The
/// Spoke values collateral at that price with a collateral factor of 80 % and debt at $1; `liquidationCall` follows
/// Aave V4's shape: it repays at most `debtToCover`, at most the debt and at most the amount that restores the target
/// health factor (1.05), seizes the repaid value times the bonus (`bonus`, 105 %) rounded down, takes the whole
/// collateral and books the rest of the debt as a deficit when the collateral does not cover it. A seized vault token
/// settles into its pool tokens at the composition above.
contract LiqWorld {
    uint256 internal constant CF = 8000;
    uint256 internal constant TARGET_HF = 1.05e18;
    uint256 internal constant USDC_PER_VT = 100e6;
    uint256 internal constant X_PER_VT = 9e18;

    LiqToken public usdc;
    LiqToken public x;
    LiqToken public vt;
    address public feeRecipient;
    address[2] internal routes;
    bool[2] internal usable;

    /// @notice Price of one X, 8 decimals.
    uint256 public px = 100e8;
    uint256 public bonus = 10_500;
    uint256 public deficit;
    uint256 public totalUnits;
    mapping(address proxy => uint256 units) public units;
    mapping(address proxy => uint256 amount) public debt;
    mapping(address proxy => address wallet) public walletOf;
    mapping(address account => bool frozen) public isFrozenAddress;
    /// @notice Lock: the one member that takes it here (the harness, at LPVaultSwap's address) and its holder.
    address public LP_VAULT_SWAP;
    address public holder;

    function init(
        LiqToken usdc_,
        LiqToken x_,
        LiqToken vt_,
        address primary,
        address backup,
        address fee
    ) external {
        require(address(usdc) == address(0), "set");
        (usdc, x, vt, feeRecipient, LP_VAULT_SWAP) = (usdc_, x_, vt_, fee, msg.sender);
        routes = [primary, backup];
        usable = [true, true];
    }

    // ─── Harness controls ───

    function open(
        address proxy,
        address wallet,
        uint256 u,
        uint256 d
    ) external {
        units[proxy] += u;
        debt[proxy] += d;
        totalUnits += u;
        walletOf[proxy] = wallet;
        vt.mint(address(this), u);
    }

    function setPx(
        uint256 p
    ) external {
        px = p;
    }

    function setFrozen(
        address account,
        bool frozen
    ) external {
        isFrozenAddress[account] = frozen;
    }

    function setUsable(
        uint8 kind,
        bool ok
    ) external {
        usable[kind] = ok;
    }

    // ─── Prices ───

    /// @notice Price of one vault token, 8 decimals.
    function pc() public view returns (uint256) {
        return 100e8 + 9 * px;
    }

    /// @notice Aave oracle: reserve 0 is the vault token, reserve 1 USDC at $1.
    function getReservePrice(
        uint256 reserveId
    ) external view returns (uint256) {
        return reserveId == 0 ? pc() : 1e8;
    }

    function ORACLE() external view returns (address) {
        return address(this);
    }

    // ─── Spoke ───

    function healthFactor(
        address user
    ) public view returns (uint256) {
        uint256 d = debt[user];
        if (d == 0) return type(uint256).max;
        // Collateral and debt in 8-decimal dollars; HF = collateral × CF / debt, 18 decimals.
        return units[user] * pc() / 1e18 * CF * 1e14 / (d * 100);
    }

    function getUserAccountData(
        address user
    ) external view returns (IAaveV4Spoke.UserAccountData memory a) {
        a.healthFactor = healthFactor(user);
        a.borrowCount = debt[user] == 0 ? 0 : 1;
        a.activeCollateralCount = units[user] == 0 ? 0 : 1;
    }

    function getLiquidationBonus(
        uint256,
        address,
        uint256
    ) external view returns (uint256) {
        return bonus;
    }

    function getUserPosition(
        uint256,
        address
    ) external pure returns (IAaveV4Spoke.UserPosition memory p) {}

    function getDynamicReserveConfig(
        uint256,
        uint32
    ) external view returns (IAaveV4Spoke.DynamicReserveConfig memory c) {
        c.collateralFactor = uint16(CF);
        c.maxLiquidationBonus = uint32(bonus);
    }

    /// @notice Repays `min(debtToCover, debt, restore amount)` from the caller and sends it the seized vault tokens.
    function liquidationCall(
        uint256,
        uint256,
        address user,
        uint256 debtToCover,
        bool
    ) external {
        uint256 d = debt[user];
        uint256 u = units[user];
        require(d != 0 && healthFactor(user) < 1e18, "healthy");
        uint256 p = pc();
        uint256 repay = d;
        // Restore amount: (TARGET_HF × debt − collateral × CF) / (TARGET_HF − bonus × CF), in dollars, rounded up.
        uint256 lhs = TARGET_HF * d * 100;
        uint256 rhs = u * p / 1e18 * CF * 1e14;
        uint256 den = bonus * CF * 1e10;
        if (TARGET_HF > den && lhs > rhs) {
            uint256 restore = (lhs - rhs) / (TARGET_HF - den) / 100 + 1;
            if (restore < repay) repay = restore;
        }
        if (debtToCover < repay) repay = debtToCover;
        uint256 seize = repay * bonus * 1e16 / p;
        if (seize >= u) {
            seize = u;
            repay = u * p / 1e18 * 1e4 / bonus / 100;
            if (repay > d) repay = d;
        }
        require(repay != 0 && seize != 0, "dust");
        usdc.transferFrom(msg.sender, address(this), repay);
        units[user] = u - seize;
        totalUnits -= seize;
        vt.transfer(msg.sender, seize);
        d -= repay;
        if (units[user] == 0 && d != 0) {
            deficit += d;
            d = 0;
        }
        debt[user] = d;
    }

    // ─── Lock (LPVaultSwap's side of the two-member Lock) ───

    function acquire() external {
        require(msg.sender == LP_VAULT_SWAP && holder == address(0), "LockHeld");
        holder = msg.sender;
    }

    function release() external {
        require(msg.sender == holder, "NotHolder");
        holder = address(0);
    }

    function isLocked() external view returns (bool) {
        return holder != address(0);
    }

    // ─── Hub ───

    function getAddedAssets(
        uint256
    ) external pure returns (uint256) {
        return 1;
    }

    function getAddedShares(
        uint256
    ) external pure returns (uint256) {
        return 1;
    }

    // ─── MarketRegistry ───

    function getMarket(
        uint256
    ) external view returns (Market memory m) {
        m.hub = address(this);
        m.spoke = address(this);
        m.tokens = new address[](2);
        (m.tokens[0], m.tokens[1]) = (address(usdc), address(x));
        m.tokenDecimals = new uint8[](2);
        (m.tokenDecimals[0], m.tokenDecimals[1]) = (6, 18);
        m.vaultToken = address(vt);
        m.decimals = 18;
        m.lpOracle = address(this);
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
        d.reserveId = 1;
        d.asset = address(usdc);
        d.decimals = 6;
        d.fundingHub = address(this);
        d.fixedPrice = true;
        d.approved = true;
    }

    function getRoute(
        uint256,
        address,
        address,
        uint8 kind
    ) external view returns (address, bool) {
        return (routes[kind], usable[kind]);
    }

    // ─── ParameterStore ───

    function graceHealthFactor() external pure returns (uint256) {
        return 0.95e18;
    }

    function getMarketParams(
        uint256
    ) external pure returns (MarketParams memory p) {
        p.slippageAllowanceBps = 150;
    }

    function floorRoundingAllowance(
        address
    ) external pure returns (uint256) {
        return 10;
    }

    function maxShortfallBps() external pure returns (uint16) {
        return 100;
    }

    function avanaFeeShareBps() external pure returns (uint16) {
        return 2000;
    }

    // ─── LPOracle (Live, no leg feeds) ───

    function poke() external pure returns (PriceState) {
        return PriceState.Live;
    }

    /// @notice `getPriceState()`: a Live `PriceStateView` with every field zero and no token report, written as its
    /// ABI encoding (the offset word, 25 head words with the `tokens` offset 0x320 in the sixth, the empty array).
    function getPriceState() external pure {
        assembly ("memory-safe") {
            let p := mload(0x40)
            calldatacopy(p, calldatasize(), 864)
            mstore(p, 0x20)
            mstore(add(p, 0xc0), 0x320)
            return(p, 864)
        }
    }

    function latestAnswer() external view returns (int256) {
        return int256(pc());
    }

    function getTokenPrices() external view returns (uint256[] memory prices, uint64, PriceState) {
        prices = new uint256[](2);
        (prices[0], prices[1]) = (1e8, px);
        return (prices, uint64(block.timestamp), PriceState.Live);
    }

    // ─── Collateralization and AaveAdapter ───

    function beginSeizure(
        address,
        address
    ) external {}

    function markDebtFree(
        address
    ) external {}

    function settleSeizure(
        address,
        address,
        uint256 u,
        uint256[] calldata mins
    ) external returns (uint256[] memory amounts) {
        amounts = new uint256[](2);
        (amounts[0], amounts[1]) = (u * USDC_PER_VT / 1e18, u * X_PER_VT / 1e18);
        require(amounts[0] >= mins[0] && amounts[1] >= mins[1], "min");
        usdc.mint(msg.sender, amounts[0]);
        x.mint(msg.sender, amounts[1]);
    }

    function burnSeized(
        uint256,
        address,
        uint256 u
    ) external {
        vt.burn(msg.sender, u);
    }
}

/// @notice A swap route of X into USDC at the World's price less `slip` bps; `dead` fails it before any transfer.
contract LiqRoute {
    LiqWorld internal immutable W;
    uint256 public slip;
    bool public dead;
    uint256 public totalOut;

    constructor(
        LiqWorld w
    ) {
        W = w;
    }

    function set(
        uint256 s,
        bool d
    ) external {
        (slip, dead) = (s, d);
    }

    function intermediates() external view returns (address[] memory im) {
        require(!dead, "dead");
        return im;
    }

    function swap(
        uint256 amountIn,
        uint256 minOut
    ) external returns (uint256 out) {
        W.x().transferFrom(msg.sender, address(this), amountIn);
        out = amountIn * W.px() / 1e20 * (1e4 - slip) / 1e4;
        require(out >= minOut, "minOut");
        W.usdc().mint(msg.sender, out);
        totalOut += out;
    }
}

/// @notice A keeper, borrower wallet or fee recipient: an account only the harness drives.
contract LiqActor {
    address internal immutable OWNER = msg.sender;

    function exec(
        address target,
        bytes calldata data
    ) external returns (bool ok, bytes memory ret) {
        require(msg.sender == OWNER, "owner");
        (ok, ret) = target.call(data);
    }
}

/// @title LPVaultSwapLiquidationProperties
/// @notice Echidna and Medusa properties of the liquidation path (2.11, 2.18): the production
/// `LPVaultSwapLiquidationLogic` run by delegatecall from this harness, which stands at LPVaultSwap's address as the
/// implementation does, with the real `PayoutEscrow`, over `LiqWorld` (Spoke, Aave oracle, Hub, MarketRegistry,
/// ParameterStore, LPOracle, Collateralization, AaveAdapter and Lock stand-ins) and two `LiqRoute`s. Three
/// borrowers hold positions; price moves put them at health factors 0.70–0.99, keepers liquidate them over the primary
/// or the backup route, with or without a shortfall top-up, and blocked recipients send payouts to the escrow.
/// Between transactions: every completed liquidation conserved the settlement asset (INV-035) and matched the measured
/// balance changes; LPVaultSwap holds no token and no allowance (INV-021, INV-037); the escrow's credits sum to its
/// totals within its balance (INV-061); the caller's net gain never exceeded the keeper reward or the oracle gain, and a
/// frozen caller never completed one (INV-030); the Spoke's debt and supply match what LPVaultSwap measured
/// (INV-014); a liquidation the Spoke capped left the account at HF ≥ 1 or debt-free; the Lock is free.
/// @dev The LPVaultSwap router with its three logic contracts, the real Lock, the PayoutEscrow and the stand-ins exceed
/// the 49,152-byte initcode limit, so this harness takes the router's place: `fallback` forwards `liquidate` calldata
/// to the logic contract unchanged, as `LPVaultSwap._delegate` does, and the logic reads no LPVaultSwap storage.
/// Aave V4 is a stand-in (`LiqWorld`): the real Spoke, Hub and oracles run in the Foundry invariant suites
/// (`FullStack.invariant.t.sol`, `Integration.invariant.t.sol`). Entry points take small selectors mapped to concrete
/// cases with `if` branches; the amounts come from the harness state.
contract LPVaultSwapLiquidationProperties {
    uint256 internal constant MARKET = 1;
    uint256 internal constant DEBT_RESERVE = 1;
    uint256 internal constant CF = 8000;

    uint256 internal constant BAD_CONSERVATION = 1;
    uint256 internal constant BAD_MEASURE = 2;
    uint256 internal constant BAD_GAIN = 4;
    uint256 internal constant BAD_FROZEN = 8;
    uint256 internal constant BAD_SPOKE = 16;
    uint256 internal constant BAD_RESTORE = 32;
    uint256 internal constant BAD_REVERT = 64;
    uint256 internal constant BAD_CLAIM = 128;

    LiqWorld internal immutable W;
    LiqToken internal immutable USDC;
    LiqToken internal immutable XT;
    LiqToken internal immutable VT;
    LiqRoute internal immutable PRIMARY;
    LiqRoute internal immutable BACKUP;
    PayoutEscrow internal immutable ESCROW;
    address internal immutable LOGIC;
    LiqActor internal immutable KEEPER;
    LiqActor internal immutable KEEPER2;
    LiqActor internal immutable FROZEN;
    LiqActor internal immutable FEE;
    LiqActor internal immutable WALLET0;
    LiqActor internal immutable WALLET1;
    LiqActor internal immutable WALLET2;

    /// @notice Debt the harness booked per account: opened debt less every `debtRepaid` LPVaultSwap measured, and 0
    /// once the Spoke cleared the rest as a deficit.
    uint256[3] public booked;
    /// @notice Bit set of broken properties (the `BAD_` constants); never reset.
    uint256 public violations;
    uint256 public liquidationsTried;
    uint256 public liquidationsDone;
    /// @notice Calls with no liquidatable account (no liquidation attempted).
    uint256 public liquidationsSkipped;
    /// @notice Expected refusals: a frozen caller.
    uint256 public liquidationsRefused;
    uint256 public claimsDone;
    bytes4 public lastFailure;

    constructor() {
        W = new LiqWorld();
        USDC = new LiqToken(6, address(W));
        XT = new LiqToken(18, address(W));
        VT = new LiqToken(18, address(W));
        PRIMARY = new LiqRoute(W);
        BACKUP = new LiqRoute(W);
        KEEPER = new LiqActor();
        KEEPER2 = new LiqActor();
        FROZEN = new LiqActor();
        FEE = new LiqActor();
        WALLET0 = new LiqActor();
        WALLET1 = new LiqActor();
        WALLET2 = new LiqActor();
        W.init(USDC, XT, VT, address(PRIMARY), address(BACKUP), address(FEE));
        W.setFrozen(address(FROZEN), true);
        ESCROW = new PayoutEscrow(address(this), address(W));
        LOGIC = address(
            new LPVaultSwapLiquidationLogic(
                LPVaultSwapImmutables({
                    lock: address(W),
                    aaveAdapter: address(W),
                    collateralization: address(W),
                    marketRegistry: address(W),
                    parameterStore: address(W),
                    payoutEscrow: address(ESCROW),
                    keeperFloor: 1
                })
            )
        );
        // Two accounts at HF 1.5 and 1.1; X then falls so the second is at HF 0.95 and liquidatable.
        _open(0, 100e18, 15_000);
        _open(1, 20e18, 11_000);
        _setHealth(1, 9500);
    }

    /// @notice LPVaultSwap's `liquidate`, forwarded to the logic contract by delegatecall with its calldata unchanged.
    fallback() external {
        require(msg.sig == ILPVaultSwapLiquidation.liquidate.selector, "selector");
        address logic = LOGIC;
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), logic, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // ─── Accounts ───

    function _proxy(
        uint256 i
    ) internal pure returns (address) {
        return address(uint160(0xB000 + i));
    }

    function _wallet(
        uint256 i
    ) internal view returns (LiqActor) {
        if (i == 0) return WALLET0;
        if (i == 1) return WALLET1;
        return WALLET2;
    }

    /// @dev Adds `u` vault-token units and the debt that puts this addition at `hfBps` / 10⁴ at the current price.
    function _open(
        uint256 i,
        uint256 u,
        uint256 hfBps
    ) internal {
        uint256 d = u * W.pc() / 1e18 * CF / (hfBps * 100);
        if (d == 0) return;
        W.open(_proxy(i), address(_wallet(i)), u, d);
        booked[i] += d;
    }

    /// @dev Sets X's price so account `i` is at `hfBps` / 10⁴ (X never below 1e-8 dollars).
    function _setHealth(
        uint256 i,
        uint256 hfBps
    ) internal {
        address p = _proxy(i);
        uint256 u = W.units(p);
        if (u == 0) return;
        // Vault-token price giving HF = units × pc × CF / (debt × 10⁴): pc = HF × debt / (units × CF).
        uint256 target = W.debt(p) * 100 * hfBps * 1e18 / (u * CF);
        W.setPx(target > 100e8 + 9 ? (target - 100e8) / 9 : 1);
    }

    function _liquidatable(
        uint256 i
    ) internal view returns (bool) {
        return W.healthFactor(_proxy(i)) < 1e18;
    }

    /// @dev Account `which` (0–2) when it is liquidatable, else the first liquidatable one; 3 when none is.
    function _target(
        uint8 which
    ) internal view returns (uint256 i) {
        uint256 w = which & 3;
        if (w < 3 && _liquidatable(w)) return w;
        for (i = 0; i < 3; ++i) {
            if (_liquidatable(i)) return i;
        }
    }

    // ─── Entry points ───

    /// @notice A new or larger position: `size` picks 1, 10, 50 or 200 vault tokens, `health` the HF of the addition
    /// (1.1, 1.2, 1.5 or 2.0) at the current price.
    function open(
        uint8 who,
        uint8 size,
        uint8 health
    ) external {
        uint256 i = who & 3;
        if (i == 3) i = 2;
        uint256 s = size & 3;
        uint256 h = health & 3;
        uint256 u = s == 0 ? 1e18 : (s == 1 ? 10e18 : (s == 2 ? 50e18 : 200e18));
        uint256 hf = h == 0 ? 11_000 : (h == 1 ? 12_000 : (h == 2 ? 15_000 : 20_000));
        _open(i, u, hf);
    }

    /// @notice X moves so account `who` (or the first one with debt) is at HF 0.70, 0.85, 0.90, 0.95, 0.99, 1.02, 1.2
    /// or 1.6; every other account moves with it.
    function movePrice(
        uint8 who,
        uint8 target
    ) external {
        uint256 i = who & 3;
        if (i == 3 || W.debt(_proxy(i)) == 0) {
            for (i = 0; i < 3 && W.debt(_proxy(i)) == 0; ++i) {}
            if (i == 3) return;
        }
        uint256 t = target & 7;
        uint256 hf = t == 0
            ? 7000
            : (t == 1
                    ? 8500
                    : (t == 2
                            ? 9000
                            : (t == 3 ? 9500 : (t == 4 ? 9900 : (t == 5 ? 10_200 : (t == 6 ? 12_000 : 16_000))))));
        _setHealth(i, hf);
    }

    struct Snap {
        uint256 keeper;
        uint256 world;
        uint256 fee;
        uint256 wallet;
        uint256 escrowFee;
        uint256 escrowWallet;
        uint256 routesOut;
        uint256 units;
        uint256 supply;
        uint256 debt;
        uint256 deficit;
        uint256 hf;
        uint256 escrowTotal;
    }

    function _snap(
        LiqActor k,
        uint256 i
    ) internal view returns (Snap memory s) {
        address p = _proxy(i);
        address wallet = address(_wallet(i));
        s.keeper = USDC.balanceOf(address(k));
        s.world = USDC.balanceOf(address(W));
        s.fee = USDC.balanceOf(address(FEE));
        s.wallet = USDC.balanceOf(wallet);
        s.escrowFee = ESCROW.claimable(address(USDC), address(FEE));
        s.escrowWallet = ESCROW.claimable(address(USDC), wallet);
        s.routesOut = PRIMARY.totalOut() + BACKUP.totalOut();
        s.units = W.units(p);
        s.supply = VT.totalSupply();
        s.debt = W.debt(p);
        s.deficit = W.deficit();
        s.hf = W.healthFactor(p);
        s.escrowTotal = ESCROW.totalClaimable(address(USDC));
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

    /// @dev Route set-up of plan `r` (0–7): returns the route mode, the caller's `maxShortfall` in USDC base units per
    /// 10⁴ of the debt, and whether the borrower wallet and the fee recipient refuse transfers.
    function _routes(
        uint256 r
    ) internal returns (RouteMode mode, uint256 shortfallBps, bool blockRecipients) {
        mode = RouteMode.PrimaryThenBackup;
        if (r == 0 || r == 4 || r == 6) {
            PRIMARY.set(20, false);
        } else if (r == 1) {
            PRIMARY.set(100, false);
        } else if (r == 2) {
            PRIMARY.set(0, true);
            BACKUP.set(50, false);
        } else if (r == 3) {
            mode = RouteMode.BackupOnly;
            BACKUP.set(80, false);
        } else if (r == 5) {
            // Below the 150 bps floor; the caller tops up the shortfall within 5 % of the debt.
            PRIMARY.set(220, false);
            BACKUP.set(220, false);
            shortfallBps = 500;
        } else {
            PRIMARY.set(0, false);
        }
        blockRecipients = r == 4;
    }

    /// @notice A liquidation of account `who` (or the first liquidatable one) by a keeper. `plan` bits 0–1: debt to
    /// cover (a quarter, half, all or twice the debt); bits 2–4: routes and recipients (primary at 20 or 100 bps,
    /// a dead primary with the backup at 50 bps, backup only at 80 bps, a blocked borrower wallet and fee recipient,
    /// both routes at 220 bps with a shortfall top-up, the frozen caller, a second keeper at 0 bps).
    function liquidate(
        uint8 who,
        uint8 plan
    ) external {
        ++liquidationsTried;
        uint256 i = _target(who);
        if (i == 3) {
            ++liquidationsSkipped;
            return;
        }
        Run memory run = _prepare(i, plan);
        Snap memory s0 = _snap(run.k, i);
        (bool ok, bytes memory ret) =
            run.k.exec(address(this), abi.encodeCall(ILPVaultSwapLiquidation.liquidate, (run.lp)));
        Snap memory s1 = _snap(run.k, i);
        run.k.exec(address(USDC), abi.encodeCall(LiqToken.approve, (address(this), 0)));
        USDC.setBlocked(address(_wallet(i)), false);
        USDC.setBlocked(address(FEE), false);

        if (!ok) {
            if (run.frozen) ++liquidationsRefused;
            else if (ret.length >= 4) lastFailure = bytes4(ret);
            // A refused liquidation moves nothing.
            bool moved = s1.keeper != s0.keeper || s1.world != s0.world || s1.units != s0.units || s1.debt != s0.debt
                || s1.supply != s0.supply || s1.escrowTotal != s0.escrowTotal;
            _ensure(BAD_REVERT, !moved);
            return;
        }
        ++liquidationsDone;
        _ensure(BAD_FROZEN, !run.frozen);
        _checkResult(abi.decode(ret, (LiquidationResult)), s0, s1, i, run.lp);
    }

    /// @dev One liquidation's caller and parameters.
    struct Run {
        LiqActor k;
        bool frozen;
        LiquidationParams lp;
    }

    /// @dev Routes, recipients, caller and funding of plan `plan` for account `i`.
    function _prepare(
        uint256 i,
        uint8 plan
    ) internal returns (Run memory run) {
        uint256 d = W.debt(_proxy(i));
        uint256 c = plan & 3;
        uint256 r = (plan >> 2) & 7;
        (RouteMode mode, uint256 shortfallBps, bool blockRecipients) = _routes(r);
        run.k = r == 6 ? FROZEN : (r == 7 ? KEEPER2 : KEEPER);
        run.frozen = r == 6;
        LiquidationParams memory lp = run.lp;
        (lp.proxy, lp.marketId, lp.debtReserveId) = (_proxy(i), MARKET, DEBT_RESERVE);
        lp.debtToCover = c == 0 ? d / 4 + 1 : (c == 1 ? d / 2 + 1 : (c == 2 ? d : 2 * d));
        (lp.routeMode, lp.deadline, lp.maxShortfall) = (mode, block.timestamp, d * shortfallBps / 1e4);
        USDC.setBlocked(address(_wallet(i)), blockRecipients);
        USDC.setBlocked(address(FEE), blockRecipients);
        uint256 funds = lp.debtToCover + lp.maxShortfall;
        USDC.mint(address(run.k), funds);
        run.k.exec(address(USDC), abi.encodeCall(LiqToken.approve, (address(this), funds)));
    }

    /// @dev The checks of one completed liquidation.
    function _checkResult(
        LiquidationResult memory res,
        Snap memory s0,
        Snap memory s1,
        uint256 i,
        LiquidationParams memory lp
    ) internal {
        // INV-035: Kf + R + shortfall == D + A + B + keeperOut, from the report and from the balances.
        bool good = res.callerFunds + res.recovered + res.shortfall
            == res.debtRepaid + res.avanaFee + res.borrowerSurplus + res.keeperOut;
        _ensure(BAD_CONSERVATION, good);
        good = res.callerFunds == lp.debtToCover && res.shortfall <= lp.maxShortfall
            && s1.keeper + res.callerFunds + res.shortfall == s0.keeper + res.keeperOut
            && s1.world - s0.world == res.debtRepaid && s1.routesOut - s0.routesOut + res.amountsOut[0] == res.recovered
            && s1.fee + s1.escrowFee - s0.fee - s0.escrowFee == res.avanaFee
            && s1.wallet + s1.escrowWallet - s0.wallet - s0.escrowWallet == res.borrowerSurplus
            && USDC.balanceOf(address(this)) == 0 && XT.balanceOf(address(this)) == 0
            && VT.balanceOf(address(this)) == 0;
        _ensure(BAD_MEASURE, good);
        // INV-030 with 2.11: the caller nets at most the keeper reward, which is at most the oracle gain G = V − D.
        // V = mulDiv(c, Pc × 10^6, 10^18 × Pdebt) with Pdebt = 1e8 (SettlementMath.seizedValue), exact here.
        uint256 v = res.unitsSeized * W.pc() / 1e20;
        good = res.keeperOut <= res.callerFunds + res.shortfall + res.keeperReward
            && res.keeperReward + res.debtRepaid <= (v > res.debtRepaid ? v : res.debtRepaid);
        _ensure(BAD_GAIN, good);
        // The Spoke booked what LPVaultSwap measured: the debt fell by D (or the rest became a deficit), the supply
        // and the account's supplied units fell by the units seized, and the account was liquidatable before.
        bool cleared = s1.debt == 0 && s1.deficit > s0.deficit;
        good = s0.hf < 1e18 && s1.units + res.unitsSeized == s0.units && s1.supply + res.unitsSeized == s0.supply
            && (s1.debt + res.debtRepaid == s0.debt || cleared);
        _ensure(BAD_SPOKE, good);
        // The Spoke repays less than the caller funded only at the restore amount or the whole collateral.
        good = res.debtRepaid == res.callerFunds || W.healthFactor(_proxy(i)) >= 1e18 || s1.debt == 0;
        _ensure(BAD_RESTORE, good);
        booked[i] = cleared ? 0 : booked[i] - res.debtRepaid;
    }

    function _actor(
        uint256 a
    ) internal view returns (LiqActor) {
        if (a == 0) return WALLET0;
        if (a == 1) return WALLET1;
        if (a == 2) return WALLET2;
        if (a == 3) return FEE;
        if (a == 4) return KEEPER;
        if (a == 5) return KEEPER2;
        return FROZEN;
    }

    /// @notice An escrow claim by a borrower wallet, the fee recipient or a keeper (`who`), of USDC or of X (`tokenX`);
    /// does nothing when that account has no credit.
    function claim(
        uint8 who,
        bool tokenX
    ) external {
        LiqActor a = _actor(who & 7);
        LiqToken t = tokenX ? XT : USDC;
        uint256 amount = ESCROW.claimable(address(t), address(a));
        if (amount == 0) return;
        uint256 total = ESCROW.totalClaimable(address(t));
        uint256 before = t.balanceOf(address(a));
        (bool ok,) = a.exec(address(ESCROW), abi.encodeCall(PayoutEscrow.claim, (address(t), address(a))));
        bool good = ok && t.balanceOf(address(a)) == before + amount && ESCROW.claimable(address(t), address(a)) == 0
            && ESCROW.totalClaimable(address(t)) == total - amount;
        _ensure(BAD_CLAIM, good);
        ++claimsDone;
    }

    // ─── Properties ───

    /// @notice INV-035: every completed liquidation conserved the settlement asset.
    function property_settlementConserved() external view returns (bool) {
        return violations & BAD_CONSERVATION == 0;
    }

    /// @notice Every report matched the balances it describes: the caller's funding and payout, the Spoke's
    /// repayment, the route output plus the released debt asset, the fee and the borrower's surplus (paid or escrowed).
    function property_reportMatchesBalances() external view returns (bool) {
        return violations & BAD_MEASURE == 0;
    }

    /// @notice INV-021, INV-037: LPVaultSwap holds no token and no allowance between transactions.
    function property_lpVaultSwapHoldsNothing() external view returns (bool) {
        address self = address(this);
        address[5] memory spenders = [address(W), address(PRIMARY), address(BACKUP), address(ESCROW), address(VT)];
        for (uint256 k = 0; k < 5; ++k) {
            if (
                USDC.allowance(self, spenders[k]) != 0 || XT.allowance(self, spenders[k]) != 0
                    || VT.allowance(self, spenders[k]) != 0
            ) return false;
        }
        return USDC.balanceOf(self) == 0 && XT.balanceOf(self) == 0 && VT.balanceOf(self) == 0;
    }

    /// @notice INV-061: for USDC and X, the escrow's total equals the sum of its credits over every account that can
    /// hold one and is covered by its balance; every claim paid exactly the credit.
    function property_escrowCreditsSum() external view returns (bool) {
        LiqToken[2] memory tokens = [USDC, XT];
        for (uint256 t = 0; t < 2; ++t) {
            uint256 sum = 0;
            for (uint256 a = 0; a < 7; ++a) {
                sum += ESCROW.claimable(address(tokens[t]), address(_actor(a)));
            }
            uint256 total = ESCROW.totalClaimable(address(tokens[t]));
            if (sum != total || tokens[t].balanceOf(address(ESCROW)) < total) return false;
        }
        return violations & BAD_CLAIM == 0;
    }

    /// @notice INV-030 with 2.11: no caller netted more than the keeper reward, itself within the oracle gain.
    function property_callerGainWithinBonus() external view returns (bool) {
        return violations & BAD_GAIN == 0;
    }

    /// @notice INV-030: a frozen caller never completed a liquidation; a refused one moved nothing.
    function property_refusalsMoveNothing() external view returns (bool) {
        return violations & (BAD_FROZEN | BAD_REVERT) == 0;
    }

    /// @notice INV-014: the Spoke's debt and supply follow what LPVaultSwap measured; each account's debt is its
    /// opened debt less the repayments, and the vault token's supply is the Spoke's supplied units.
    function property_spokeMatchesSettlement() external view returns (bool) {
        if (violations & BAD_SPOKE != 0) return false;
        uint256 sum = 0;
        for (uint256 i = 0; i < 3; ++i) {
            if (W.debt(_proxy(i)) != booked[i]) return false;
            sum += W.units(_proxy(i));
        }
        return VT.totalSupply() == sum && VT.balanceOf(address(W)) == sum && sum == W.totalUnits();
    }

    /// @notice A liquidation the Spoke capped below the caller's funding left the account at HF ≥ 1 or debt-free.
    function property_cappedLiquidationRestores() external view returns (bool) {
        return violations & BAD_RESTORE == 0;
    }

    /// @notice The Lock is free between transactions.
    function property_lockFree() external view returns (bool) {
        return !W.isLocked();
    }
}
