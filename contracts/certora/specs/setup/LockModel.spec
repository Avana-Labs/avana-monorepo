/*
 * Ghost model of the protocol Lock (2.16) as seen from the contracts that call it.
 *
 * `lockHolder` mirrors the transient HOLDER_SLOT: `acquire` succeeds only while it is free and records the caller,
 * `release` succeeds only for the holder and frees it. The Lock's own access rules (members only, holder-only
 * release, no delegatecall) are proved on the real Lock in Lock.spec (PROP-037), so the model applies them to any
 * caller the verified contract makes. A refused `acquire` or `release` reverts the whole call; the model prunes it.
 */

persistent ghost address lockHolder;

function lockAcquire(address caller) {
    require lockHolder == 0;
    lockHolder = caller;
}

function lockRelease(address caller) {
    require lockHolder == caller;
    lockHolder = 0;
}

function lockHolderOf() returns address {
    return lockHolder;
}

function lockIsLocked() returns bool {
    return lockHolder != 0;
}

function setLockHolder(address holder) {
    lockHolder = holder;
}
