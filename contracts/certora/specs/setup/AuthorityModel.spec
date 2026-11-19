/*
 * Ghost model of the OpenZeppelin AccessManager decision that `restricted` (AccessManaged v5.1.0) reads.
 *
 * AccessManaged asks its authority through AuthorityUtils.canCallWithDelay, a low-level STATICCALL to the address in
 * the `_authority` storage slot. The Prover knows that call's sighash (`canCall(address,address,bytes4)`) but not its
 * target, so with the real AccessManager in the scene the call stays unresolved and its return data is havocked: any
 * caller passes `restricted`. A contract spec binds this model by sighash instead:
 *
 *     function _.canCall(address caller, address target, bytes4 selector) external
 *         => authorityCanCall(caller, target, selector) expect (bool, uint32);
 *
 * so the decision is a fixed (immediate, delay) per (caller, target, selector), the same value a rule reads from
 * `authImmediate` and `authDelay`. The rules then hold for every role configuration of the AccessManager; which
 * roles the DAO grants is the AccessManager's configuration, outside the verified contract.
 *
 * Only ghosts and CVL functions live here; each contract spec binds them in its own `methods` block.
 */

persistent ghost mapping(address => mapping(address => mapping(bytes4 => bool))) authImmediate;
persistent ghost mapping(address => mapping(address => mapping(bytes4 => uint32))) authDelay;

function authorityCanCall(address caller, address target, bytes4 selector) returns (bool, uint32) {
    return (authImmediate[caller][target][selector], authDelay[caller][target][selector]);
}

// The AccessManager lets `caller` run `selector` on `target`, now or through a scheduled operation.
definition authorized(address caller, address target, bytes4 selector) returns bool =
    authImmediate[caller][target][selector] || authDelay[caller][target][selector] > 0;
