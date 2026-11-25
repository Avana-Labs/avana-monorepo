/*
 * LPVault (src/LPVault.sol, design design/vault.md) on the Uniswap v2 AMM part
 * (src/integrations/UniswapV2Integration.sol), the real contract. Position key = bytes32(tokenId) of the
 * UniswapV2Positions NFT; the per-pledge LP record is `_recordLp[tokenId]` (PR 367 `_recordPledge`).
 *
 * Record identity and who changes it:
 *   pledgeRecordsThePosition          a pledge writes exactly the record of the position it takes (account, market,
 *                                     the liquidity read, its credit), takes the NFT from `from` into the LPVault,
 *                                     records all the LP the NFT holds, raises the market's credit by the credit and
 *                                     appends the key to the account's list
 *   pledgedRecordKeepsAccountAndMarket a pledged record never changes account or market; only `pledge` creates a
 *                                     record and only `release` deletes one; only pledge, addLiquidity,
 *                                     removeLiquidity, unwind and release change its liquidity or credit
 *   everyChangeIsAuthorized           every state-changing call succeeds only for a caller the AccessManager
 *                                     authorizes (the AaveAdapter role; the liquidation role for unwind; the risk
 *                                     role for listMarket). With AaveAdapterAccounts.onlyPositionOwnerChangesPosition
 *                                     (the adapter acts on a record only for the wallet whose account holds it), only
 *                                     the record's owner changes it.
 *   collectFeesOnlyForRecordAccount   collectFees pays a record's fees only when called for the record's account
 *   releaseDeletesTheRecord           a release deletes exactly the pledged record, lowers the market's credit by its
 *                                     credit and drops the key from the account's list
 *
 * The v2 per-pledge LP record:
 *   removalBurnsAtMostRecordShare     removeLiquidity and unwind burn at most floor(record LP * liquidity removed /
 *                                     record liquidity), lower the record LP by exactly what they burned, and never
 *                                     lower the record's LP per unit of liquidity
 *   topUpAddsExactlyNewLp             addLiquidity raises the record LP by exactly the LP that arrived in the NFT, and
 *                                     the record's liquidity and credit by the liquidity of that LP alone
 *   recordLpWithinNftLp (invariant)   a pledged record never claims more LP than its NFT holds
 *
 * Credit:
 *   creditEqualsLiquidity (invariant) a record's credit is exactly its liquidity: a v2 position is full range, so a v2
 *                                     market's band is the full tick range (bandsInsideTickRange) and every credit
 *                                     step takes the exact-band branch of `_floorCredit`. Liquidity is
 *                                     `lp * sqrt(k) / supply` at the read, with the pending protocol fee counted, so
 *                                     the credit is never above the position's band units, which LPOracle.spec
 *                                     (`valueAtMostExact`, `unitAmountsAtMostExact`) prices at no more than their
 *                                     value at Aave's prices.
 *
 * Moves:
 *   pledgedNftHeldByVault (invariant) the LPVault holds the NFT of every pledged record
 *   nftMovesOnlyWithRecord            an NFT changes owner only in a pledge that creates its record (into the LPVault)
 *                                     or a release that deletes it (out of the LPVault)
 *   lpMovesOnlyWithRecord             LP goes into or out of an NFT only for a pledged record, and the record LP
 *                                     changes by exactly the LP added less the LP taken out
 *
 * Prover limit: the Prover's pointer analysis fails on `release` and `collectFees` (the copy of a record's two held fees,
 * `uint256[2] memory`), so their external calls are unresolved there. `release`'s NFT transfer is therefore not
 * modelled: nftMovesOnlyWithRecord holds for `release` without seeing the transfer, and that the NFT goes to the
 * recipient is checked by test/unit/LPVault.unit.t.sol `test_release_returnsTheNftAndClosesTheRecord` instead. Reading
 * the two fees into locals resolves nothing: `release` then fails to compile (stack too deep).
 *
 * Supporting invariants: bandsInsideTickRange (listMarket's band check), marketTokensNotTheWrapper.
 * Lemma: floorDivAtMost (one nonlinear step, required at the burn rule's own terms).
 *
 * Summaries, and why each is sound:
 *  - UniswapV2Positions (the wrapper, also the ERC-721): ghosts `wPair`, `wLp` per token ID and `nftOwner`. `positions`
 *    reads them; `increase` adds what arrived (positive, at most the amount pulled, as `_pull` measures it) to the NFT;
 *    `unwrap` takes at most the NFT's LP and needs the caller to own the NFT (`_checkAuthorized`); `ownerOf` reads
 *    `nftOwner`; `transferFrom` on the wrapper moves the NFT from its owner (`from` must own it, as ERC721
 *    `_transfer` checks; the approval is not modelled, so more transfers succeed than in the real token). Other
 *    holders can only add LP to an NFT (`increase` is open) and cannot move a vault-held NFT or take its LP, so the
 *    ghosts change between calls only in ways that keep every invariant here.
 *  - Pair reads and calls (`getReserves`, `totalSupply`, `kLast`, `mint`, `burn`, `token0`, `token1`), the factory's
 *    `getPair` and token calls (`balanceOf`, `transfer`, `approve`) are NONDET: they change no LPVault storage. The
 *    pair's `token0`/`token1` never return the wrapper (`pairToken`): a market's tokens are Aave reserves of the price
 *    Spoke (RiskModule listing check), and the wrapper is an ERC-721, not a reserve. Token `transferFrom` (same
 *    sighash as the ERC-721's) is the ERC-721 model only on the wrapper and NONDET on any other address.
 *  - `_liquidityOf` (lp * sqrt(r0 * r1) / supply with the pending fee) returns any value, 0 for no LP;
 *    `_burnsToNothing` and `_amountsAtReserves` return any value: over-approximations, no rule reads the pair math.
 *  - `FloorCreditMath.credit` reverts outside its band (as the library does) and is otherwise any value; on v2 it is
 *    never reached (creditEqualsLiquidity).
 *  - OpenZeppelin `Math.mulDiv` is floor(x * y / den) and its Ceil form the ceiling (LPOracleSummaries.spec
 *    `ozMulDivIsFloor`; checked by test/differential/MathSummaries.differential.t.sol), as Aave's V4 library
 *    verification does. When one factor equals the divisor, the summary returns the other factor: the same value.
 *  - `_payFees` (token transfers of held fees, no LPVault storage) is NONDET.
 *  - The AccessManager's decision is the ghost AuthorityModel (setup/AuthorityModel.spec), bound at
 *    `AuthorityUtils.canCallWithDelay`, the helper through which `restricted` asks it, and recorded with the caller,
 *    target and selector asked; `consumeScheduledOp` is NONDET.
 */

import "setup/AuthorityModel.spec";

methods {
    function getPosition(bytes32) external returns (ILPVault.Position) envfree;
    function getMarket(uint256) external returns (ILPVault.Market) envfree;
    function POSITIONS() external returns (address) envfree;
    function authority() external returns (address) envfree;
    function pledge(address, address, uint256, bytes32) external returns (uint128);
    function addLiquidity(bytes32, address, uint256, uint256, uint256, uint256) external returns (uint128, uint128, uint256, uint256);
    function removeLiquidity(bytes32, uint128, uint256, uint256, address) external returns (uint128, uint256, uint256);
    function release(bytes32, address) external returns (uint128);
    function unwind(bytes32, uint128, uint256, uint256, address) external returns (uint128, uint128, uint256, uint256);
    function collectFees(address, bytes32[], address) external returns (uint256[], uint256[]);
    function listMarket(uint256, bytes32, int24, int24) external;

    // The AccessManager decision, bound at AccessManaged's own helper rather than at the external `canCall`, whose
    // summary read another selector and target than the call's in the parametric rules.
    function AuthorityUtils.canCallWithDelay(address, address caller, address target, bytes4 selector) internal
        returns (bool, uint32) => checkedCanCall(caller, target, selector);
    function _.consumeScheduledOp(address, bytes) external => NONDET;

    // Position wrapper and its ERC-721
    function _.positions(uint256 id) external => wrapperPosition(id) expect (address, uint256);
    function _.increase(uint256 id, uint256 amount) external => wrapperIncrease(id, amount) expect (uint256);
    function _.unwrap(uint256 id, uint256 amount, address to) external with (env e) => wrapperUnwrap(e.msg.sender, id, amount) expect void;
    function _.ownerOf(uint256 id) external => nftOwner[id] expect (address);
    function _.transferFrom(address from, address to, uint256 x) external => transferFromModel(calledContract, from, to, x) expect (bool);

    // Pair, factory and tokens
    function _.token0() external => pairToken(calledContract, 0) expect (address);
    function _.token1() external => pairToken(calledContract, 1) expect (address);
    function _.mint(address) external => NONDET;
    function _.burn(address) external => NONDET;
    function _.getReserves() external => NONDET;
    function _.totalSupply() external => NONDET;
    function _.kLast() external => NONDET;
    function _.getPair(address, address) external => NONDET;
    function _.balanceOf(address) external => NONDET;
    function _.transfer(address, uint256) external => NONDET;
    function _.approve(address, uint256) external => NONDET;

    // Pair math, not read by any rule
    function UniswapV2Integration._liquidityOf(address pair, uint256 lp) internal returns (uint128) => liquidityOfModel(lp);
    function UniswapV2Integration._burnsToNothing(address, uint256) internal returns (bool) => NONDET;
    function UniswapV2Integration._amountsAtReserves(address, uint256, uint256) internal returns (uint256, uint256) => NONDET;
    // Pays held fees out in tokens only (no LPVault storage); summarised so the Prover's pointer analysis resolves
    // release's and collectFees's other calls (it failed on both with the body inlined).
    function LPVault._payFees(bytes32, ILPVault.Market storage, uint256, uint256, address) internal => NONDET;
    function FloorCreditMath.credit(int24 a, int24 b, int24 bandA, int24 bandB, uint128 l) internal returns (uint128)
        => floorCreditModel(a, b, bandA, bandB, l);

    // Proven against the library bytecode in LPOracleSummaries.spec (ozMulDivIsFloor).
    function Math.mulDiv(uint256 x, uint256 y, uint256 den) internal returns (uint256) => mulDivFloor(x, y, den);
    function Math.mulDiv(uint256 x, uint256 y, uint256 den, Math.Rounding r) internal returns (uint256) => mulDivRounded(x, y, den, r);

}

// The decision `restricted` read in the current call, and for which caller, target and selector.
persistent ghost bool authChecked;
persistent ghost address checkedCaller;
persistent ghost address checkedTarget;
persistent ghost bytes4 checkedSelector;

function checkedCanCall(address caller, address target, bytes4 selector) returns (bool, uint32) {
    authChecked = true;
    checkedCaller = caller;
    checkedTarget = target;
    checkedSelector = selector;
    bool immediate;
    uint32 delay;
    immediate, delay = authorityCanCall(caller, target, selector);
    return (immediate, delay);
}

definition MIN_TICK() returns mathint = -887272;
definition MAX_TICK() returns mathint = 887272;

// ---------------------------------------------------------------------------------------------------------------------
// Math summaries
// ---------------------------------------------------------------------------------------------------------------------

// floor(x * y / den); the library reverts when den is 0 or the quotient is not a word, so those paths are dropped.
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

function floorCreditModel(int24 a, int24 b, int24 bandA, int24 bandB, uint128 l) returns uint128 {
    // FloorCreditMath reverts NotInsideBand unless bandA <= a < b <= bandB.
    require bandA <= a && a < b && b <= bandB;
    uint128 c;
    return c;
}

// ---------------------------------------------------------------------------------------------------------------------
// Wrapper, NFT and pair models
// ---------------------------------------------------------------------------------------------------------------------

persistent ghost mapping(uint256 => address) wPair;
persistent ghost mapping(uint256 => uint256) wLp;
persistent ghost mapping(uint256 => address) nftOwner;
persistent ghost mapping(address => mapping(uint256 => address)) pairTokenGhost;

// LP added to and taken out of each NFT during the current rule.
persistent ghost mapping(uint256 => mathint) increasedInCall;
persistent ghost mapping(uint256 => mathint) unwrappedInCall;
// The first liquidity read of the current rule: its LP amount and result.
persistent ghost mathint liquidityReads;
persistent ghost uint256 firstLiquidityLp;
persistent ghost uint128 firstLiquidity;

function wrapperPosition(uint256 id) returns (address, uint256) {
    return (wPair[id], wLp[id]);
}

function wrapperIncrease(uint256 id, uint256 amount) returns uint256 {
    // UniswapV2Positions.increase: an unknown position reverts, and the LP that arrived is positive and at most what
    // the caller sent.
    require wPair[id] != 0;
    uint256 received;
    require received > 0 && received <= amount;
    require wLp[id] + received <= max_uint256;
    wLp[id] = require_uint256(wLp[id] + received);
    increasedInCall[id] = increasedInCall[id] + received;
    return received;
}

function wrapperUnwrap(address caller, uint256 id, uint256 amount) {
    // UniswapV2Positions.unwrap: the caller must hold the NFT, and 0 < amount <= the NFT's LP.
    require nftOwner[id] == caller;
    require amount > 0 && amount <= wLp[id];
    wLp[id] = require_uint256(wLp[id] - amount);
    unwrappedInCall[id] = unwrappedInCall[id] + amount;
}

function transferFromModel(address target, address from, address to, uint256 x) returns bool {
    if (target == POSITIONS()) {
        // ERC721.transferFrom: `from` must own the NFT and `to` is not zero.
        require nftOwner[x] == from && to != 0;
        nftOwner[x] = to;
    }
    return true;
}

function pairToken(address pair, uint8 i) returns address {
    address t = pairTokenGhost[pair][i];
    require t != POSITIONS();
    return t;
}

function liquidityOfModel(uint256 lp) returns uint128 {
    uint128 l;
    if (lp == 0) {
        require l == 0;
    }
    if (liquidityReads == 0) {
        firstLiquidityLp = lp;
        firstLiquidity = l;
    }
    liquidityReads = liquidityReads + 1;
    return l;
}

function startCall(uint256 id) {
    require increasedInCall[id] == 0 && unwrappedInCall[id] == 0;
    require liquidityReads == 0;
}

definition recordLp(uint256 id) returns uint256 = currentContract._recordLp[id];
definition pledged(uint256 id) returns bool = getPosition(to_bytes32(id)).account != 0;

definition isPledge(method f) returns bool = f.selector == sig:pledge(address, address, uint256, bytes32).selector;
definition isRelease(method f) returns bool = f.selector == sig:release(bytes32, address).selector;
definition isAdd(method f) returns bool =
    f.selector == sig:addLiquidity(bytes32, address, uint256, uint256, uint256, uint256).selector;
definition isRemove(method f) returns bool =
    f.selector == sig:removeLiquidity(bytes32, uint128, uint256, uint256, address).selector;
definition isUnwind(method f) returns bool =
    f.selector == sig:unwind(bytes32, uint128, uint256, uint256, address).selector;

// Calls `f`; addLiquidity, the only call that pulls tokens with `transferFrom`, with its market's tokens not the
// wrapper (marketTokensNotTheWrapper).
function callWithTokensChecked(env e, method f) {
    if (isAdd(f)) {
        bytes32 key;
        address payer;
        uint256 a0;
        uint256 a1;
        uint256 m0;
        uint256 m1;
        requireInvariant marketTokensNotTheWrapper(getPosition(key).marketId);
        addLiquidity(e, key, payer, a0, a1, m0, m1);
    } else {
        calldataarg args;
        f(e, args);
    }
}

// ---------------------------------------------------------------------------------------------------------------------
// Supporting invariants
// ---------------------------------------------------------------------------------------------------------------------

invariant bandsInsideTickRange(uint256 m)
    getMarket(m).bandLower >= MIN_TICK() && getMarket(m).bandUpper <= MAX_TICK();

invariant marketTokensNotTheWrapper(uint256 m)
    getMarket(m).token0 != POSITIONS() && getMarket(m).token1 != POSITIONS();

// ---------------------------------------------------------------------------------------------------------------------
// Record identity
// ---------------------------------------------------------------------------------------------------------------------

rule pledgeRecordsThePosition(address from, address account, uint256 marketId, uint256 id) {
    env e;
    bytes32 k = to_bytes32(id);
    startCall(id);
    ILPVault.Market m0 = getMarket(marketId);
    uint256 lpBefore = wLp[id];
    address ownerBefore = nftOwner[id];
    uint256 n = currentContract._accountPositions[account].length;

    uint128 credit = pledge(e, from, account, marketId, k);

    ILPVault.Position p = getPosition(k);
    assert p.account == account && to_mathint(p.marketId) == to_mathint(marketId), "the record names another account or market";
    assert p.liquidity == firstLiquidity && firstLiquidityLp == lpBefore, "the record's liquidity is not that of the NFT's LP";
    assert p.credit == credit && credit > 0, "the record's credit is not the credit returned";
    assert ownerBefore == from && nftOwner[id] == currentContract, "the NFT did not move from `from` into the LPVault";
    assert recordLp(id) == lpBefore, "the record LP is not all the LP the NFT holds";
    assert getMarket(marketId).totalCredit == m0.totalCredit + credit, "the market's credit moved by another amount";
    assert currentContract._accountPositions[account].length == n + 1
        && currentContract._accountPositions[account][n] == k, "the key was not appended to the account's list";
}

rule pledgedRecordKeepsAccountAndMarket(method f, uint256 id) filtered { f -> !f.isView } {
    env e;
    bytes32 k = to_bytes32(id);
    ILPVault.Position p0 = getPosition(k);

    callWithTokensChecked(e, f);

    ILPVault.Position p1 = getPosition(k);
    assert p0.account != 0 && p1.account != 0 => p1.account == p0.account && p1.marketId == p0.marketId,
        "a pledged record changed account or market";
    assert p0.account == 0 && p1.account != 0 => isPledge(f), "a record was created other than by pledge";
    assert p0.account != 0 && p1.account == 0 => isRelease(f), "a record was deleted other than by release";
    assert (p1.liquidity != p0.liquidity || p1.credit != p0.credit)
        => (isPledge(f) || isRelease(f) || isAdd(f) || isRemove(f) || isUnwind(f)),
        "a record's liquidity or credit changed in another function";
}

rule releaseDeletesTheRecord(uint256 id, address recipient) {
    env e;
    bytes32 k = to_bytes32(id);
    ILPVault.Position p0 = getPosition(k);
    ILPVault.Market m0 = getMarket(p0.marketId);
    uint256 n = currentContract._accountPositions[p0.account].length;

    uint128 credit = release(e, k, recipient);

    assert p0.account != 0 && credit == p0.credit, "released a record that was not pledged, or another credit";
    assert getPosition(k).account == 0 && getPosition(k).liquidity == 0 && getPosition(k).credit == 0,
        "the record was not deleted";
    assert getMarket(p0.marketId).totalCredit == m0.totalCredit - credit, "the market's credit moved by another amount";
    assert to_mathint(currentContract._accountPositions[p0.account].length) == n - 1, "the key stayed in the account's list";
}

// Each function is called with explicit arguments: in a call through `calldataarg` the Prover leaves the calldata's
// first four bytes free, so `restricted` (which reads the selector from msg.data) would ask about any selector.
rule everyChangeIsAuthorized(method f) filtered { f -> !f.isView } {
    env e;
    address manager = authority();
    require !authChecked;
    callDirectly(e, f);
    if (f.selector == sig:setAuthority(address).selector) {
        // AccessManaged.setAuthority: only the current AccessManager moves the contract to another one.
        assert e.msg.sender == manager, "a caller other than the AccessManager replaced it";
    } else {
        assert authChecked && checkedCaller == e.msg.sender && checkedTarget == currentContract
            && checkedSelector == selectorOf(f), "the AccessManager was not asked about this call";
        assert authorized(e.msg.sender, currentContract, checkedSelector),
            "a caller the AccessManager does not authorize changed the LPVault";
    }
}

function callDirectly(env e, method f) {
    bytes32 key;
    address a1;
    address a2;
    uint256 u1;
    uint256 u2;
    uint256 u3;
    uint256 u4;
    uint128 l;
    if (isPledge(f)) {
        pledge(e, a1, a2, u1, key);
    } else if (isRelease(f)) {
        release(e, key, a1);
    } else if (isAdd(f)) {
        addLiquidity(e, key, a1, u1, u2, u3, u4);
    } else if (isRemove(f)) {
        removeLiquidity(e, key, l, u1, u2, a1);
    } else if (isUnwind(f)) {
        unwind(e, key, l, u1, u2, a1);
    } else if (f.selector == sig:collectFees(address, bytes32[], address).selector) {
        bytes32[] keys;
        collectFees(e, a1, keys, a2);
    } else if (f.selector == sig:listMarket(uint256, bytes32, int24, int24).selector) {
        int24 lo;
        int24 hi;
        listMarket(e, u1, key, lo, hi);
    } else {
        calldataarg args;
        f(e, args);
    }
}

function selectorOf(method f) returns bytes4 {
    if (isPledge(f)) {
        return to_bytes4(sig:pledge(address, address, uint256, bytes32).selector);
    } else if (isRelease(f)) {
        return to_bytes4(sig:release(bytes32, address).selector);
    } else if (isAdd(f)) {
        return to_bytes4(sig:addLiquidity(bytes32, address, uint256, uint256, uint256, uint256).selector);
    } else if (isRemove(f)) {
        return to_bytes4(sig:removeLiquidity(bytes32, uint128, uint256, uint256, address).selector);
    } else if (isUnwind(f)) {
        return to_bytes4(sig:unwind(bytes32, uint128, uint256, uint256, address).selector);
    } else if (f.selector == sig:collectFees(address, bytes32[], address).selector) {
        return to_bytes4(sig:collectFees(address, bytes32[], address).selector);
    }
    return to_bytes4(sig:listMarket(uint256, bytes32, int24, int24).selector);
}

rule collectFeesOnlyForRecordAccount(address account, bytes32[] keys, address recipient, uint256 i) {
    env e;
    collectFees(e, account, keys, recipient);
    assert i < keys.length => getPosition(keys[i]).account == account, "fees were collected for another account";
}

// ---------------------------------------------------------------------------------------------------------------------
// The v2 per-pledge LP record
// ---------------------------------------------------------------------------------------------------------------------

rule removalBurnsAtMostRecordShare(method f, uint256 id) filtered { f -> isRemove(f) || isUnwind(f) } {
    env e;
    bytes32 k = to_bytes32(id);
    startCall(id);
    mathint rec0 = recordLp(id);
    ILPVault.Position p0 = getPosition(k);
    uint128 amount;
    uint256 m0;
    uint256 m1;
    address recipient;
    if (isRemove(f)) {
        removeLiquidity(e, k, amount, m0, m1, recipient);
    } else {
        unwind(e, k, amount, m0, m1, recipient);
    }
    ILPVault.Position p1 = getPosition(k);
    mathint burned = unwrappedInCall[id];
    mathint removed = p0.liquidity - p1.liquidity;
    // floorDivAtMost(n = rec0 * removed, q = p0.liquidity)
    require p0.liquidity > 0 => (rec0 * removed / p0.liquidity) * p0.liquidity <= rec0 * removed;

    assert burned * p0.liquidity <= rec0 * removed, "burned more than the record's share of its LP";
    assert recordLp(id) == rec0 - burned, "the record LP did not fall by exactly the LP burned";
    assert recordLp(id) * p0.liquidity >= rec0 * p1.liquidity, "the record's LP per liquidity fell";
}

rule topUpAddsExactlyNewLp(uint256 id, address payer, uint256 a0, uint256 a1, uint256 m0, uint256 m1) {
    env e;
    bytes32 k = to_bytes32(id);
    startCall(id);
    mathint rec0 = recordLp(id);
    ILPVault.Position p0 = getPosition(k);

    uint128 liquidity;
    uint128 credit;
    uint256 used0;
    uint256 used1;
    liquidity, credit, used0, used1 = addLiquidity(e, k, payer, a0, a1, m0, m1);

    ILPVault.Position p1 = getPosition(k);
    assert increasedInCall[id] > 0 && unwrappedInCall[id] == 0, "no LP arrived in the NFT, or LP left it";
    assert recordLp(id) == rec0 + increasedInCall[id], "the record LP moved by another amount than the LP that arrived";
    assert to_mathint(firstLiquidityLp) == increasedInCall[id] && liquidity == firstLiquidity,
        "the liquidity added is not that of the LP that arrived";
    assert p1.liquidity == p0.liquidity + liquidity && p1.credit == p0.credit + credit,
        "the record moved by another liquidity or credit than the top-up's";
}

invariant recordLpWithinNftLp(uint256 id)
    pledged(id) => recordLp(id) <= wLp[id]
    {
        preserved addLiquidity(bytes32 key, address payer, uint256 a0, uint256 a1, uint256 m0, uint256 m1) with (env e) {
            requireInvariant marketTokensNotTheWrapper(getPosition(key).marketId);
            requireInvariant pledgedNftHeldByVault(id);
        }
        preserved with (env e) {
            requireInvariant pledgedNftHeldByVault(id);
        }
    }

// ---------------------------------------------------------------------------------------------------------------------
// Credit
// ---------------------------------------------------------------------------------------------------------------------

invariant creditEqualsLiquidity(uint256 id)
    getPosition(to_bytes32(id)).credit == getPosition(to_bytes32(id)).liquidity
    {
        preserved with (env e) {
            requireInvariant bandsInsideTickRange(getPosition(to_bytes32(id)).marketId);
        }
        preserved pledge(address from, address account, uint256 marketId, bytes32 key) with (env e) {
            requireInvariant bandsInsideTickRange(marketId);
            requireInvariant bandsInsideTickRange(getPosition(to_bytes32(id)).marketId);
        }
    }

// ---------------------------------------------------------------------------------------------------------------------
// Moves
// ---------------------------------------------------------------------------------------------------------------------

invariant pledgedNftHeldByVault(uint256 id)
    pledged(id) => nftOwner[id] == currentContract
    {
        preserved addLiquidity(bytes32 key, address payer, uint256 a0, uint256 a1, uint256 m0, uint256 m1) with (env e) {
            requireInvariant marketTokensNotTheWrapper(getPosition(key).marketId);
        }
    }

rule nftMovesOnlyWithRecord(method f, uint256 id) filtered { f -> !f.isView } {
    env e;
    bytes32 k = to_bytes32(id);
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

rule lpMovesOnlyWithRecord(method f, uint256 id) filtered { f -> !f.isView } {
    env e;
    startCall(id);
    mathint rec0 = recordLp(id);
    bool was = pledged(id);

    callWithTokensChecked(e, f);

    assert (increasedInCall[id] != 0 || unwrappedInCall[id] != 0) => was,
        "LP moved into or out of an NFT without a pledged record";
    assert was => recordLp(id) == rec0 + increasedInCall[id] - unwrappedInCall[id],
        "a pledged record's LP moved by another amount than the LP moved";
}

// ---------------------------------------------------------------------------------------------------------------------
// Lemma
// ---------------------------------------------------------------------------------------------------------------------

rule floorDivAtMost(mathint n, mathint q) {
    require n >= 0 && q > 0;
    assert (n / q) * q <= n, "floor(n / q) * q exceeds n";
}
