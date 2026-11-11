/*
 * VaultTokenFactory (src/vault-token/vault-token-factory/VaultTokenFactory.sol, interface
 * src/vault-token/vault-token-factory/IVaultTokenFactory.sol, spec 2.4).
 *
 * Only the timelock deploys vault tokens; each (CDP Spoke, market key) pair, where the market key is (chain, AMM
 * integration, pool, exact position shape), gets at most one token for life, at the CREATE3 address
 * `predictAddress(spoke, marketKey)`; the factory's bindings never change. Collateralization and the Adapter read
 * `tokenOf` as an immutable source, which is what makes the write-once rule load-bearing.
 *
 * Storage assumption: the (Spoke, market key) and integration registries of the 2.4 factory storage, read through
 * `tokenOf` and `lpVaultOf`; plain storage (immutable).
 *
 * Summaries: the LPVault and Collateralization reads of `registerIntegration` are length-checked low-level
 * `STATICCALL`s, which the prover treats as returning arbitrary data, so every identity rule holds for any answer; the
 * VaultToken constructor runs inside the CREATE3 deployment, whose bytecode the prover creates with `dynamic_bound` 1
 * (VaultTokenFactory.conf). The two `satisfy` rules show that a registration and a deployment are reachable, so the
 * rules about them are not vacuous.
 */

methods {
    function TIMELOCK() external returns (address) envfree;
    function ADAPTER() external returns (address) envfree;
    function COLLATERALIZATION() external returns (address) envfree;
    function LP_VAULT_SWAP() external returns (address) envfree;
    function MARKET_REGISTRY() external returns (address) envfree;
    function isVaultToken(address) external returns (bool) envfree;
    function tokenOf(address, bytes32) external returns (address) envfree;
    function lpVaultOf(uint32) external returns (address) envfree;
    function predictAddress(address, bytes32) external returns (address) envfree;
    function marketKeyOf(uint32, address, bytes32, VaultTokenFactory.PositionShape) external returns (bytes32);
    function registerIntegration(uint32, address) external;
    function deployVaultToken(uint32, address, bytes32, VaultTokenFactory.PositionShape, address, address, uint256, address, uint8, string, string) external returns (address);

    function _.INTEGRATION_ID() external => integrationIdOf(calledContract) expect uint32;
    function _.COLLATERALIZATION() external => collateralizationOf(calledContract) expect address;
    function _.LOCK() external => lockOf(calledContract) expect address;
}

ghost integrationIdOf(address) returns uint32;
ghost collateralizationOf(address) returns address;
ghost lockOf(address) returns address;

// PROP-099 verifies: INV-051, Q-226, Q-228
rule deployOnlyByTimelock(uint32 id, address pool, bytes32 poolId, VaultTokenFactory.PositionShape shape, address hub, address spoke,
                          uint256 m, address o, uint8 d, string n, string s) {
    env e;

    deployVaultToken(e, id, pool, poolId, shape, hub, spoke, m, o, d, n, s);

    assert e.msg.sender == TIMELOCK(), "a vault token was deployed by a caller other than the timelock";
}

// PROP-099 verifies: INV-009, INV-012, Q-120, Q-224, Q-226
rule tokenOfIsWriteOnce(method f, address spoke, bytes32 key) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    address before = tokenOf(spoke, key);

    f(e, args);

    assert before != 0 => tokenOf(spoke, key) == before, "a market's vault token changed";
}

// PROP-099 verifies: INV-009, Q-224
rule deployLandsAtThePredictedAddress(uint32 id, address pool, bytes32 poolId, VaultTokenFactory.PositionShape shape, address hub,
                                      address spoke, uint256 m, address o, uint8 d, string n, string s) {
    env e;
    bytes32 key = marketKeyOf(e, id, pool, poolId, shape);
    address predicted = predictAddress(spoke, key);
    require tokenOf(spoke, key) == 0;

    address vt = deployVaultToken(e, id, pool, poolId, shape, hub, spoke, m, o, d, n, s);

    assert vt == predicted && tokenOf(spoke, key) == vt,
        "the token is not at predictAddress(spoke, marketKey) or not registered";
    assert m != 0 && m < 2^32 && hub != 0 && spoke != 0 && o != 0, "a token was deployed with a zero binding";
    assert lpVaultOf(id) != 0, "a token was deployed for an unregistered AMM integration";
}

// PROP-099 verifies: INV-009, Q-224
rule secondDeployForAMarketReverts(uint32 id, address pool, bytes32 poolId, VaultTokenFactory.PositionShape shape, address hub,
                                   address spoke, uint256 m, address o, uint8 d, string n, string s) {
    env e;
    bytes32 key = marketKeyOf(e, id, pool, poolId, shape);
    require tokenOf(spoke, key) != 0;

    deployVaultToken@withrevert(e, id, pool, poolId, shape, hub, spoke, m, o, d, n, s);

    assert lastReverted, "a second vault token was deployed for a (Spoke, market key) pair";
}

// PROP-099 verifies: INV-009, Q-224, Q-226
rule bindingsNeverChange(method f) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    address t = TIMELOCK();
    address a = ADAPTER();
    address c = COLLATERALIZATION();
    address l = LP_VAULT_SWAP();
    address r = MARKET_REGISTRY();

    f(e, args);

    assert TIMELOCK() == t && ADAPTER() == a && COLLATERALIZATION() == c && LP_VAULT_SWAP() == l,
        "a factory binding changed";
    assert MARKET_REGISTRY() == r, "the factory's MarketRegistry changed";
}

// PROP-099 verifies: INV-051, Q-228
rule timelockCanDeploy(uint32 id, address pool, bytes32 poolId, VaultTokenFactory.PositionShape shape, address hub, address spoke,
                       uint256 m, address o, uint8 d, string n, string s) {
    env e;
    require e.msg.sender == TIMELOCK();
    address vt = deployVaultToken(e, id, pool, poolId, shape, hub, spoke, m, o, d, n, s);
    satisfy vt != 0;
}

// PROP-099 verifies: REQ-VTOKEN-044, REQ-AMM-CORE-001, Q-374
rule lpVaultOfIsWriteOnce(method f, uint32 id) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    address before = lpVaultOf(id);

    f(e, args);

    assert before != 0 => lpVaultOf(id) == before, "a registered integration's LPVault changed";
}

// PROP-099 verifies: REQ-VTOKEN-021
rule isVaultTokenOnlyTurnsTrue(method f, address t) filtered { f -> !f.isView } {
    env e;
    calldataarg args;
    bool before = isVaultToken(t);

    f(e, args);

    assert before => isVaultToken(t), "a deployed token stopped being a vault token";
}

// PROP-099 verifies: REQ-VTOKEN-044, REQ-VTOKEN-045, INV-051, Q-228
rule registerOnlyByTimelock(uint32 id, address vault) {
    env e;

    registerIntegration(e, id, vault);

    assert e.msg.sender == TIMELOCK(), "an integration was registered by a caller other than the timelock";
    assert id != 0 && lpVaultOf(id) == vault && vault != 0, "a registration wrote another entry";
    assert vault != ADAPTER() && vault != LP_VAULT_SWAP() && vault != COLLATERALIZATION(),
        "a factory binding was registered as an LPVault";
}

// PROP-099 verifies: REQ-VTOKEN-044, Q-374
rule timelockCanRegister(uint32 id, address vault) {
    env e;
    require e.msg.sender == TIMELOCK();
    registerIntegration(e, id, vault);
    satisfy lpVaultOf(id) == vault;
}
