/*
 * Ghost model of the Aave V4 Borrow Spoke, the Avana Stable LP Hub and the AaveOracle (a3ef63e) as seen from Avana.
 *
 * The Spoke is a token mover that follows the vault-token transfer pair rule (PROP-008): `supply` moves units from the
 * caller to the Hub and raises the account's supplied shares by the same amount (Hub shares == assets for vault
 * tokens, PROP-040), `withdraw` lowers them and pays the caller, `liquidationCall` lowers the borrower's shares by an
 * arbitrary seized amount and pays it to the caller, `borrow` and `repay` move GHO and debt. Health factors after a
 * state-changing call are fresh arbitrary values, so a rule that reads them after the call holds for any HF Aave
 * computes. Reserve identities and immutables are uninterpreted functions, so they are fixed per address.
 *
 * Ghost keys: spoke address, reserve ID, account.
 */

persistent ghost mapping(address => mapping(uint256 => mapping(address => mathint))) spokeSupplied {
    init_state axiom forall address s. forall uint256 r. forall address u. spokeSupplied[s][r][u] == 0;
}
persistent ghost mapping(address => mapping(uint256 => mapping(address => mathint))) spokeDebt {
    init_state axiom forall address s. forall uint256 r. forall address u. spokeDebt[s][r][u] == 0;
}
persistent ghost mapping(address => mapping(uint256 => mapping(address => bool))) spokeCollateralEnabled;
persistent ghost mapping(address => mapping(uint256 => bool)) spokePaused;
persistent ghost mapping(address => mapping(uint256 => bool)) spokeFrozen;
persistent ghost mapping(address => mapping(address => mathint)) spokeHealthFactor;

// Hub added assets and added shares per (hub, assetId).
persistent ghost mapping(address => mapping(uint256 => mathint)) hubAddedAssets;
persistent ghost mapping(address => mapping(uint256 => mathint)) hubAddedShares;

ghost spokeReserveIdOf(address, address, uint256) returns uint256;
ghost spokeUnderlyingOf(address, uint256) returns address;
ghost spokeHubOf(address) returns address;
ghost spokeReserveCount(address) returns uint256;
ghost spokeOracleOf(address) returns address;
ghost hubAssetIdOf(address, address) returns uint256;
ghost aaveOracleSourceOf(address, uint256) returns address;

// Liquidation bookkeeping of the current call.
persistent ghost mathint liquidationCalls;
persistent ghost bool liquidationReceiveShares;
persistent ghost mathint lastSeizedUnits;
persistent ghost mathint lastDebtRepaid;

function spokeGetUserSuppliedShares(address spoke, uint256 rid, address user) returns uint256 {
    require spokeSupplied[spoke][rid][user] >= 0;
    return require_uint256(spokeSupplied[spoke][rid][user]);
}

function spokeGetUserTotalDebt(address spoke, uint256 rid, address user) returns uint256 {
    require spokeDebt[spoke][rid][user] >= 0;
    return require_uint256(spokeDebt[spoke][rid][user]);
}

function spokeGetUserReserveStatus(address spoke, uint256 rid, address user) returns (bool, bool) {
    return (spokeCollateralEnabled[spoke][rid][user], spokeDebt[spoke][rid][user] > 0);
}

function spokeGetReserveConfig(address spoke, uint256 rid) returns IAaveV4Spoke.ReserveConfig {
    IAaveV4Spoke.ReserveConfig c;
    require c.paused == spokePaused[spoke][rid];
    require c.frozen == spokeFrozen[spoke][rid];
    return c;
}

function spokeGetUserAccountData(address spoke, address user) returns IAaveV4Spoke.UserAccountData {
    IAaveV4Spoke.UserAccountData d;
    require spokeHealthFactor[spoke][user] >= 0;
    require to_mathint(d.healthFactor) == spokeHealthFactor[spoke][user];
    return d;
}

function havocHealthFactor(address spoke, address user) {
    mathint hf;
    require hf >= 0 && hf <= max_uint256;
    spokeHealthFactor[spoke][user] = hf;
}

function spokeSupply(address spoke, address caller, uint256 rid, uint256 amount, address onBehalfOf) returns (uint256, uint256) {
    erc20Move(spokeUnderlyingOf(spoke, rid), caller, spokeHubOf(spoke), amount);
    spokeSupplied[spoke][rid][onBehalfOf] = spokeSupplied[spoke][rid][onBehalfOf] + amount;
    havocHealthFactor(spoke, onBehalfOf);
    return (amount, amount);
}

function spokeWithdraw(address spoke, address caller, uint256 rid, uint256 amount, address onBehalfOf) returns (uint256, uint256) {
    require spokeSupplied[spoke][rid][onBehalfOf] >= to_mathint(amount);
    spokeSupplied[spoke][rid][onBehalfOf] = spokeSupplied[spoke][rid][onBehalfOf] - amount;
    erc20Credit(spokeUnderlyingOf(spoke, rid), caller, amount);
    havocHealthFactor(spoke, onBehalfOf);
    return (amount, amount);
}

function spokeBorrow(address spoke, address caller, uint256 rid, uint256 amount, address onBehalfOf) returns (uint256, uint256) {
    spokeDebt[spoke][rid][onBehalfOf] = spokeDebt[spoke][rid][onBehalfOf] + amount;
    erc20Credit(spokeUnderlyingOf(spoke, rid), caller, amount);
    havocHealthFactor(spoke, onBehalfOf);
    return (amount, amount);
}

function spokeRepay(address spoke, address caller, uint256 rid, uint256 amount, address onBehalfOf) returns (uint256, uint256) {
    mathint debt = spokeDebt[spoke][rid][onBehalfOf];
    mathint paid = to_mathint(amount) < debt ? to_mathint(amount) : debt;
    require paid >= 0;
    bool pulled = erc20TransferFrom(spokeUnderlyingOf(spoke, rid), spoke, caller, spokeHubOf(spoke), require_uint256(paid));
    require pulled;
    spokeDebt[spoke][rid][onBehalfOf] = debt - paid;
    havocHealthFactor(spoke, onBehalfOf);
    return (require_uint256(paid), require_uint256(paid));
}

function spokeSetUsingAsCollateral(address spoke, uint256 rid, bool enabled, address onBehalfOf) {
    spokeCollateralEnabled[spoke][rid][onBehalfOf] = enabled;
}

// Aave sizes the repayment D <= debtToCover and the seizure c <= the borrower's supplied shares; the caller pays D
// GHO and receives c vault-token units (receiveShares = false).
function spokeLiquidationCall(address spoke, address caller, uint256 collateralRid, uint256 debtRid, address user,
                              uint256 debtToCover, bool receiveShares) {
    mathint repaid;
    mathint seized;
    require repaid >= 0 && repaid <= to_mathint(debtToCover) && repaid <= spokeDebt[spoke][debtRid][user];
    require seized >= 0 && seized <= spokeSupplied[spoke][collateralRid][user];
    bool pulled = erc20TransferFrom(spokeUnderlyingOf(spoke, debtRid), spoke, caller, spokeHubOf(spoke), require_uint256(repaid));
    require pulled;
    spokeDebt[spoke][debtRid][user] = spokeDebt[spoke][debtRid][user] - repaid;
    spokeSupplied[spoke][collateralRid][user] = spokeSupplied[spoke][collateralRid][user] - seized;
    erc20Credit(spokeUnderlyingOf(spoke, collateralRid), caller, require_uint256(seized));
    havocHealthFactor(spoke, user);
    liquidationCalls = liquidationCalls + 1;
    liquidationReceiveShares = receiveShares;
    lastSeizedUnits = seized;
    lastDebtRepaid = repaid;
}

function hubGetAddedAssets(address hub, uint256 assetId) returns uint256 {
    require hubAddedAssets[hub][assetId] >= 0;
    return require_uint256(hubAddedAssets[hub][assetId]);
}

function hubGetAddedShares(address hub, uint256 assetId) returns uint256 {
    require hubAddedShares[hub][assetId] >= 0;
    return require_uint256(hubAddedShares[hub][assetId]);
}

function setSpokeSupplied(address spoke, uint256 rid, address user, mathint shares) {
    spokeSupplied[spoke][rid][user] = shares;
}

function resetLiquidationModel() {
    liquidationCalls = 0;
    liquidationReceiveShares = false;
    lastSeizedUnits = 0;
    lastDebtRepaid = 0;
}
