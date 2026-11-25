/*
 * LPVault (src/LPVault.sol, design design/vault.md) on the Uniswap v3 AMM part (NfpmLPVault and
 * src/integrations/UniswapV3Integration.sol), the real contract: the concentrated-liquidity case, where the
 * floor credit of FloorCreditMath is below the liquidity. Position key = bytes32(tokenId) of the NonfungiblePositionManager
 * (NFPM). The Uniswap v2 part, with its per-pledge LP record, is LPVaultV2.spec.
 *
 *   pledgeRecordsThePosition          a pledge writes exactly the record of the position it takes: the account, the
 *                                     market, the NFT's liquidity and its floor credit on the NFT's ticks in the
 *                                     market's band; it takes the NFT from `from` into the LPVault and raises the
 *                                     market's credit by the credit
 *   creditWithinFloorCredit           a record's credit never exceeds the floor credit of its liquidity on its ticks
 *                                     in its market's band, through every function (top-ups add the floor credit of
 *                                     the new liquidity alone, removals cap what is left at the floor of what is
 *                                     left). With recordLiquidityWithinNft and FloorCreditMath.spec (the credit is
 *                                     monotone in the liquidity and worth at most the position at every price in the
 *                                     band), and LPOracle.spec (the oracle never prices a band unit above its exact
 *                                     value), the credit is never above the position's value at the oracle price
 *   recordLiquidityWithinNft (inv.)   a pledged record never counts more liquidity than its NFT holds
 *   liquidityMovesOnlyWithRecord      liquidity goes into or out of an NFT only for a pledged record, and the record's
 *                                     liquidity moves by exactly the liquidity added less the liquidity removed
 *   pledgedNftHeldByVault (inv.)      the LPVault holds the NFT of every pledged record
 *   nftMovesOnlyWithRecord            an NFT changes owner only in a pledge that creates its record (into the LPVault)
 *                                     or a release that deletes it (out of the LPVault)
 *
 * Prover limit: the Prover's pointer analysis fails on `release` and `collectFees` (the copy of a record's two held fees,
 * `uint256[2] memory`), so their external calls are unresolved there. `release`'s NFT transfer is therefore not
 * modelled: nftMovesOnlyWithRecord holds for `release` without seeing the transfer, and that the NFT goes to the
 * recipient is checked by test/unit/LPVault.unit.t.sol `test_release_returnsTheNftAndClosesTheRecord` instead. Reading
 * the two fees into locals resolves nothing: `release` then fails to compile (stack too deep).
 *
 * Supporting invariants: pledgedMarketListed (a record's market is listed, so its band is fixed),
 * marketTokensNotTheNfpm.
 *
 * Summaries, and why each is sound:
 *  - NFPM (also the ERC-721): ghosts per token ID for the position's tokens, fee, ticks, liquidity and owner.
 *    `positions` reads them; the ticks and tokens never change (Uniswap v3 fixes them at mint); `increaseLiquidity`
 *    adds some liquidity and returns it (anyone may call it on any NFT, so other callers only add); `decreaseLiquidity`
 *    needs the caller to own the NFT (`isAuthorizedForToken`) and removes at most the NFT's liquidity; `collect` pays
 *    some amounts; `ownerOf` reads the owner ghost; `transferFrom` on the NFPM moves the NFT from its owner (`from`
 *    must own it, as ERC721 checks; approvals are not modelled, so more transfers succeed than in the real token).
 *  - The factory's `getPool` is a ghost function of the position's tokens and fee, so two reads agree; pool reads
 *    (`token0`, `token1`, `fee`, `tickSpacing`, `factory`, `slot0`, fee growth, `ticks`) and token calls are NONDET:
 *    they change no LPVault storage. The pool's `token0`/`token1` never return the NFPM: a market's tokens are Aave
 *    reserves of the price Spoke (RiskModule listing check), and the NFPM is an ERC-721, not a reserve. Token
 *    `transferFrom` (same sighash as the ERC-721's) is the ERC-721 model only on the NFPM.
 *  - `FloorCreditMath.credit` reverts outside its band (FloorCreditMath.spec `creditRevertsOutsideTheBand`) and is
 *    otherwise the ghost function `fc` of its arguments. The two facts the credit rule needs are required at its own
 *    terms, as instances of proven rules over the library's formula (FloorCreditMath.spec; the bytecode is checked
 *    against that formula by the Halmos check `check_creditMatchesReference`): `creditSuperadditive`
 *    (fc(x) + fc(y) <= fc(x + y)) and `creditMonotoneInLiquidity`.
 *  - OpenZeppelin `Math.mulDiv` is floor(x * y / den) and its Ceil form the ceiling, as in LPVaultV2.spec.
 *  - `_payFees` (token transfers of held fees) is NONDET. The AccessManager's decision is the ghost AuthorityModel
 *    (setup/AuthorityModel.spec), bound at `AuthorityUtils.canCallWithDelay`; `consumeScheduledOp` is NONDET.
 */

import "setup/AuthorityModel.spec";

methods {
    function getPosition(bytes32) external returns (ILPVault.Position) envfree;
    function getMarket(uint256) external returns (ILPVault.Market) envfree;
    function NFPM() external returns (address) envfree;
    function pledge(address, address, uint256, bytes32) external returns (uint128);
    function addLiquidity(bytes32, address, uint256, uint256, uint256, uint256) external returns (uint128, uint128, uint256, uint256);
    function removeLiquidity(bytes32, uint128, uint256, uint256, address) external returns (uint128, uint256, uint256);
    function release(bytes32, address) external returns (uint128);
    function unwind(bytes32, uint128, uint256, uint256, address) external returns (uint128, uint128, uint256, uint256);

    // The AccessManager decision, bound at AccessManaged's own helper, as in LPVaultV2.spec.
    function AuthorityUtils.canCallWithDelay(address, address caller, address target, bytes4 selector) internal
        returns (bool, uint32) => authorityCanCall(caller, target, selector);
    function _.consumeScheduledOp(address, bytes) external => NONDET;

    // NFPM and its ERC-721
    function _.positions(uint256 id) external => nfpmPosition(id) expect (INfpmPositions.NfpmPositionData);
    function _.increaseLiquidity(INonfungiblePositionManager.IncreaseLiquidityParams p) external
        => nfpmIncrease(p.tokenId) expect (uint128, uint256, uint256);
    function _.decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams p) external with (env e)
        => nfpmDecrease(e.msg.sender, p.tokenId, p.liquidity) expect (uint256, uint256);
    function _.collect(INonfungiblePositionManager.CollectParams) external => NONDET;
    function _.ownerOf(uint256 id) external => nftOwner[id] expect (address);
    function _.transferFrom(address from, address to, uint256 x) external => transferFromModel(calledContract, from, to, x) expect (bool);

    // Factory, pool and tokens
    function _.getPool(address t0, address t1, uint24 fee) external => poolOf(t0, t1, fee) expect (address);
    function _.token0() external => poolToken(calledContract, 0) expect (address);
    function _.token1() external => poolToken(calledContract, 1) expect (address);
    function _.fee() external => NONDET;
    function _.tickSpacing() external => NONDET;
    function _.factory() external => NONDET;
    function _.slot0() external => NONDET;
    function _.feeGrowthGlobal0X128() external => NONDET;
    function _.feeGrowthGlobal1X128() external => NONDET;
    function _.ticks(int24) external => NONDET;
    function _.balanceOf(address) external => NONDET;
    function _.transfer(address, uint256) external => NONDET;
    function _.approve(address, uint256) external => NONDET;

    // Token transfers of held fees only (no LPVault storage), as in LPVaultV2.spec.
    function LPVault._payFees(bytes32, ILPVault.Market storage, uint256, uint256, address) internal => NONDET;
    function FloorCreditMath.credit(int24 a, int24 b, int24 bandA, int24 bandB, uint128 l) internal returns (uint128)
        => floorCreditModel(a, b, bandA, bandB, l);
    // Proven against the library bytecode in LPOracleSummaries.spec (ozMulDivIsFloor).
    function Math.mulDiv(uint256 x, uint256 y, uint256 den) internal returns (uint256) => mulDivFloor(x, y, den);
    function Math.mulDiv(uint256 x, uint256 y, uint256 den, Math.Rounding r) internal returns (uint256) => mulDivRounded(x, y, den, r);
}

// ---------------------------------------------------------------------------------------------------------------------
// Math summaries
// ---------------------------------------------------------------------------------------------------------------------

function mulDivFloor(uint256 x, uint256 y, uint256 den) returns uint256 {
    require den > 0;
    if (x == den) {
        return y;
    }
    if (y == den) {
        return x;
    }
    mathint q = (x * y) / den;
    require q <= max_uint256;
    return require_uint256(q);
}

function mulDivRounded(uint256 x, uint256 y, uint256 den, Math.Rounding r) returns uint256 {
    uint256 q = mulDivFloor(x, y, den);
    if (x == den || y == den) {
        return q;
    }
    bool up = r == Math.Rounding.Ceil || r == Math.Rounding.Expand;
    if (up && (x * y) % den != 0) {
        require q < max_uint256;
        return require_uint256(q + 1);
    }
    return q;
}

// Persistent: a pure function of its inputs, which no unresolved call can change.
persistent ghost fc(int24, int24, int24, int24, uint128) returns uint128;

function floorCreditModel(int24 a, int24 b, int24 bandA, int24 bandB, uint128 l) returns uint128 {
    // FloorCreditMath reverts NotInsideBand unless bandA <= a < b <= bandB.
    require bandA <= a && a < b && b <= bandB;
    return fc(a, b, bandA, bandB, l);
}

// _floorCredit: liquidity itself on exactly the band's ticks, the library's credit otherwise.
function floorOf(uint256 id, uint256 marketId, mathint l) returns mathint {
    ILPVault.Market m = getMarket(marketId);
    if (nTickLower[id] == m.bandLower && nTickUpper[id] == m.bandUpper) {
        return l;
    }
    return fc(nTickLower[id], nTickUpper[id], m.bandLower, m.bandUpper, require_uint128(l));
}

// ---------------------------------------------------------------------------------------------------------------------
// NFPM, NFT and pool models
// ---------------------------------------------------------------------------------------------------------------------

persistent ghost mapping(uint256 => address) nToken0;
persistent ghost mapping(uint256 => address) nToken1;
persistent ghost mapping(uint256 => uint24) nFee;
persistent ghost mapping(uint256 => int24) nTickLower;
persistent ghost mapping(uint256 => int24) nTickUpper;
persistent ghost mapping(uint256 => uint128) nLiquidity;
persistent ghost mapping(uint256 => address) nftOwner;
persistent ghost mapping(address => mapping(uint8 => address)) poolTokenGhost;
ghost poolOf(address, address, uint24) returns address;

persistent ghost mapping(uint256 => mathint) increasedInCall;
persistent ghost mapping(uint256 => mathint) decreasedInCall;

function nfpmPosition(uint256 id) returns INfpmPositions.NfpmPositionData {
    INfpmPositions.NfpmPositionData p;
    require p.token0 == nToken0[id] && p.token1 == nToken1[id] && p.feeOrTickSpacing == nFee[id];
    require p.tickLower == nTickLower[id] && p.tickUpper == nTickUpper[id] && p.liquidity == nLiquidity[id];
    return p;
}

function nfpmIncrease(uint256 id) returns (uint128, uint256, uint256) {
    uint128 added;
    uint256 a0;
    uint256 a1;
    require nLiquidity[id] + added <= max_uint128;
    nLiquidity[id] = require_uint128(nLiquidity[id] + added);
    increasedInCall[id] = increasedInCall[id] + added;
    return (added, a0, a1);
}

function nfpmDecrease(address caller, uint256 id, uint128 liquidity) returns (uint256, uint256) {
    // NonfungiblePositionManager.decreaseLiquidity: isAuthorizedForToken, liquidity > 0 and at most the position's.
    require nftOwner[id] == caller;
    require liquidity > 0 && liquidity <= nLiquidity[id];
    nLiquidity[id] = require_uint128(nLiquidity[id] - liquidity);
    decreasedInCall[id] = decreasedInCall[id] + liquidity;
    uint256 a0;
    uint256 a1;
    return (a0, a1);
}

function transferFromModel(address target, address from, address to, uint256 x) returns bool {
    if (target == NFPM()) {
        require nftOwner[x] == from && to != 0;
        nftOwner[x] = to;
    }
    return true;
}

function poolToken(address pool, uint8 i) returns address {
    address t = poolTokenGhost[pool][i];
    require t != NFPM();
    return t;
}

function startCall(uint256 id) {
    require increasedInCall[id] == 0 && decreasedInCall[id] == 0;
}

definition pledged(uint256 id) returns bool = getPosition(to_bytes32(id)).account != 0;

definition isPledge(method f) returns bool = f.selector == sig:pledge(address, address, uint256, bytes32).selector;
definition isRelease(method f) returns bool = f.selector == sig:release(bytes32, address).selector;
definition isAdd(method f) returns bool =
    f.selector == sig:addLiquidity(bytes32, address, uint256, uint256, uint256, uint256).selector;

function callWithTokensChecked(env e, method f) {
    if (isAdd(f)) {
        bytes32 key;
        address payer;
        uint256 a0;
        uint256 a1;
        uint256 m0;
        uint256 m1;
        requireInvariant marketTokensNotTheNfpm(getPosition(key).marketId);
        addLiquidity(e, key, payer, a0, a1, m0, m1);
    } else {
        calldataarg args;
        f(e, args);
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Supporting invariants
// ---------------------------------------------------------------------------------------------------------------------

invariant pledgedMarketListed(uint256 id)
    pledged(id) => getMarket(getPosition(to_bytes32(id)).marketId).pool != to_bytes32(0);

invariant marketTokensNotTheNfpm(uint256 m)
    getMarket(m).token0 != NFPM() && getMarket(m).token1 != NFPM();

// ---------------------------------------------------------------------------------------------------------------------
// Record identity
// ---------------------------------------------------------------------------------------------------------------------

rule pledgeRecordsThePosition(address from, address account, uint256 marketId, uint256 id) {
    env e;
    bytes32 k = to_bytes32(id);
    ILPVault.Market m0 = getMarket(marketId);
    uint128 live = nLiquidity[id];
    address ownerBefore = nftOwner[id];

    uint128 credit = pledge(e, from, account, marketId, k);

    ILPVault.Position p = getPosition(k);
    assert p.account == account && to_mathint(p.marketId) == to_mathint(marketId), "the record names another account or market";
    assert p.liquidity == live, "the record's liquidity is not the NFT's";
    assert p.credit == credit && credit > 0 && to_mathint(credit) == floorOf(id, marketId, live),
        "the record's credit is not the floor credit of the NFT's liquidity";
    assert ownerBefore == from && nftOwner[id] == currentContract, "the NFT did not move from `from` into the LPVault";
    assert getMarket(marketId).totalCredit == m0.totalCredit + credit, "the market's credit moved by another amount";
}

// ---------------------------------------------------------------------------------------------------------------------
// Credit
// ---------------------------------------------------------------------------------------------------------------------

rule creditWithinFloorCredit(method f, uint256 id) filtered { f -> !f.isView } {
    env e;
    bytes32 k = to_bytes32(id);
    requireInvariant pledgedMarketListed(id);
    ILPVault.Position p0 = getPosition(k);
    require p0.account != 0 => to_mathint(p0.credit) <= floorOf(id, p0.marketId, p0.liquidity);

    callWithTokensChecked(e, f);

    ILPVault.Position p1 = getPosition(k);
    int24 a = nTickLower[id];
    int24 b = nTickUpper[id];
    ILPVault.Market m = getMarket(p1.marketId);
    mathint l0 = p0.liquidity;
    mathint l1 = p1.liquidity;
    // creditSuperadditive(x = l0, y = l1 - l0) and creditMonotoneInLiquidity(l1, l0), at this record's ticks and band.
    require l1 >= l0 => fc(a, b, m.bandLower, m.bandUpper, require_uint128(l0))
        + fc(a, b, m.bandLower, m.bandUpper, require_uint128(l1 - l0)) <= to_mathint(fc(a, b, m.bandLower, m.bandUpper, require_uint128(l1)));
    require l1 <= l0 => fc(a, b, m.bandLower, m.bandUpper, require_uint128(l1)) <= fc(a, b, m.bandLower, m.bandUpper, require_uint128(l0));

    assert p1.account != 0 => to_mathint(p1.credit) <= floorOf(id, p1.marketId, p1.liquidity),
        "a record's credit exceeds the floor credit of its liquidity";
}

invariant recordLiquidityWithinNft(uint256 id)
    pledged(id) => getPosition(to_bytes32(id)).liquidity <= nLiquidity[id]
    {
        preserved addLiquidity(bytes32 key, address payer, uint256 a0, uint256 a1, uint256 m0, uint256 m1) with (env e) {
            requireInvariant marketTokensNotTheNfpm(getPosition(key).marketId);
            requireInvariant pledgedNftHeldByVault(id);
        }
        preserved with (env e) {
            requireInvariant pledgedNftHeldByVault(id);
        }
    }

// ---------------------------------------------------------------------------------------------------------------------
// Moves
// ---------------------------------------------------------------------------------------------------------------------

rule liquidityMovesOnlyWithRecord(method f, uint256 id) filtered { f -> !f.isView } {
    env e;
    startCall(id);
    ILPVault.Position p0 = getPosition(to_bytes32(id));
    bool was = pledged(id);

    callWithTokensChecked(e, f);

    ILPVault.Position p1 = getPosition(to_bytes32(id));
    assert (increasedInCall[id] != 0 || decreasedInCall[id] != 0) => was,
        "liquidity moved into or out of an NFT without a pledged record";
    assert was && pledged(id) => to_mathint(p1.liquidity) == p0.liquidity + increasedInCall[id] - decreasedInCall[id],
        "a pledged record's liquidity moved by another amount than the NFT's";
}

invariant pledgedNftHeldByVault(uint256 id)
    pledged(id) => nftOwner[id] == currentContract
    {
        preserved addLiquidity(bytes32 key, address payer, uint256 a0, uint256 a1, uint256 m0, uint256 m1) with (env e) {
            requireInvariant marketTokensNotTheNfpm(getPosition(key).marketId);
        }
    }

rule nftMovesOnlyWithRecord(method f, uint256 id) filtered { f -> !f.isView } {
    env e;
    address o0 = nftOwner[id];
    bool was = pledged(id);

    callWithTokensChecked(e, f);

    address o1 = nftOwner[id];
    bool is = pledged(id);
    assert o1 != o0 => (
        (isPledge(f) && !was && is && o1 == currentContract)
        || (isRelease(f) && was && !is && o0 == currentContract)
    ), "an NFT moved without its record being created or deleted";
}
