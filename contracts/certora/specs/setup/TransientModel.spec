/*
 * Transient storage at the start of a transaction (EIP-1153): every slot reads zero until the transaction writes it.
 *
 * The prover keeps transient storage across the calls of one rule, as within one transaction, but starts a rule with
 * arbitrary transient contents. A rule that stands for one whole transaction calls `transientStorageEmpty()` first;
 * the TSTORE and TLOAD hooks then make every transient read return the last value written in the rule, or zero.
 * Invariants need no call: the prover checks them after its own transient-storage reset step.
 */

persistent ghost mapping(address => mapping(uint256 => uint256)) tStorage;

hook ALL_TSTORE(uint256 loc, uint256 v) {
    tStorage[executingContract][loc] = v;
}

hook ALL_TLOAD(uint256 loc) uint256 v {
    require tStorage[executingContract][loc] == v;
}

function transientStorageEmpty() {
    require forall address c. forall uint256 l. tStorage[c][l] == 0;
}
