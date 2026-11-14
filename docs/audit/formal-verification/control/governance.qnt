// FV-C governance state machine: AvanaTimelock operations with the normal-delay floor, cancel rights
// (role-change and restoring operations only by DAO_CANCELLER_ROLE), AdminRoleOnlyTimelock on role grants,
// the application pause state with its reason, and the address freeze, run as randomized simulation
// (quint run, 10,000 samples x 12 steps per invariant). A hostile proposer schedules any operation; the
// guardians cancel every operation they are allowed to cancel; the Aave governance executor never cancels.
// FV-CTL-98 verifies: SPEC-GOV-002, SPEC-GOV-003, SPEC-GOV-004, SPEC-GOV-005, SPEC-GOV-015, REQ-ACCESS-153, REQ-ACCESS-156, REQ-MREG-022, REQ-MREG-024, INV-049, INV-068, INV-085
module gov {
  type Kind = Upgrade | GrantAdminToX | Unpause | RevokeGuardian | MixedRevokeUnpause | UnfreezeAddress
            | MixedUnfreezeLoosen | SetNormalDelayFloor | SetNormalDelayBelowFloor
  type Op = { kind: Kind, scheduledAt: int, readyAt: int, roleChange: bool, restoring: bool, live: bool, done: bool }

  pure val MIN_NORMAL = 345600
  pure val MAX_NORMAL = 432000
  pure val GRACE = 1209600

  var now: int
  var normalDelay: int
  var pauseState: str           // "None" | "Frozen" | "Paused"
  var pauseReason: str          // "None" | "General" | "MintPathSuspect"
  var ops: int -> Op
  var nextId: int
  var xHoldsAdmin: bool         // attacker X holds APPLICATION_ADMIN on the AaveAdapter
  var guardianActive: bool
  var addrFrozen: bool          // one wallet's address freeze
  var lastUpgradeCancellableByGuardian: bool
  var lastTransitionOk: bool
  var lastExecWaited: bool
  var guardianCancelledRestoring: bool
  var unfrozenOutsideOperation: bool

  pure def isRoleChange(k: Kind): bool = k == GrantAdminToX or k == RevokeGuardian
  pure def isRestoring(k: Kind): bool = k == UnfreezeAddress

  action init = all {
    now' = 1780000000, normalDelay' = MAX_NORMAL, pauseState' = "None", pauseReason' = "None",
    ops' = Map(-1 -> { kind: Unpause, scheduledAt: 0, readyAt: 0, roleChange: false, restoring: false,
                       live: false, done: true }),
    nextId' = 0, xHoldsAdmin' = false, guardianActive' = true, addrFrozen' = false,
    lastUpgradeCancellableByGuardian' = true, lastTransitionOk' = true, lastExecWaited' = true,
    guardianCancelledRestoring' = false, unfrozenOutsideOperation' = false,
  }

  action flagsUnchanged = all {
    lastTransitionOk' = true, lastExecWaited' = true, guardianCancelledRestoring' = false,
    unfrozenOutsideOperation' = false,
  }

  // the proposer schedules any operation with the current normal delay (SPEC-GOV-001: none of these is short)
  action schedule = nondet k = Set(Upgrade, GrantAdminToX, Unpause, RevokeGuardian, MixedRevokeUnpause,
                                   UnfreezeAddress, MixedUnfreezeLoosen, SetNormalDelayFloor,
                                   SetNormalDelayBelowFloor).oneOf()
    all {
      ops' = ops.put(nextId, { kind: k, scheduledAt: now, readyAt: now + normalDelay, roleChange: isRoleChange(k),
                               restoring: isRestoring(k), live: true, done: false }),
      nextId' = nextId + 1,
      now' = now, normalDelay' = normalDelay, pauseState' = pauseState, pauseReason' = pauseReason,
      xHoldsAdmin' = xHoldsAdmin, guardianActive' = guardianActive, addrFrozen' = addrFrozen,
      lastUpgradeCancellableByGuardian' = lastUpgradeCancellableByGuardian, flagsUnchanged,
    }

  // a guardian (CANCELLER_ROLE, not DAO_CANCELLER_ROLE) cancels any live operation SPEC-GOV-005 lets it cancel
  action guardianCancel = nondet id = ops.keys().oneOf()
    val o = ops.get(id)
    all {
      guardianActive, o.live, not(o.roleChange), not(o.restoring),
      ops' = ops.set(id, { ...o, live: false }),
      guardianCancelledRestoring' = o.restoring,
      now' = now, normalDelay' = normalDelay, pauseState' = pauseState, pauseReason' = pauseReason,
      nextId' = nextId, xHoldsAdmin' = xHoldsAdmin, guardianActive' = guardianActive, addrFrozen' = addrFrozen,
      lastUpgradeCancellableByGuardian' = lastUpgradeCancellableByGuardian,
      lastTransitionOk' = true, lastExecWaited' = true, unfrozenOutsideOperation' = false,
    }

  action tick = nondet d = Set(1, 3600, 43200, 345600, 432000, 1209600).oneOf()
    all {
      now' = now + d, normalDelay' = normalDelay, pauseState' = pauseState, pauseReason' = pauseReason,
      ops' = ops, nextId' = nextId, xHoldsAdmin' = xHoldsAdmin, guardianActive' = guardianActive,
      addrFrozen' = addrFrozen, lastUpgradeCancellableByGuardian' = lastUpgradeCancellableByGuardian,
      flagsUnchanged,
    }

  // public execution of a ready, unexpired operation (SPEC-GOV-002). A grant of APPLICATION_ADMIN to X reverts
  // AdminRoleOnlyTimelock (REQ-ACCESS-153), so that operation never executes; setNormalDelay below the floor
  // reverts DelayOutOfBounds (SPEC-GOV-003).
  action execute = nondet id = ops.keys().oneOf()
    val o = ops.get(id)
    all {
      o.live, not(o.done), o.readyAt <= now, now < o.readyAt + GRACE,
      o.kind != GrantAdminToX, o.kind != SetNormalDelayBelowFloor,
      ops' = ops.set(id, { ...o, done: true, live: false }),
      xHoldsAdmin' = xHoldsAdmin,
      guardianActive' = if (o.kind == RevokeGuardian) false else guardianActive,
      lastUpgradeCancellableByGuardian' = (if (o.kind == Upgrade) not(o.roleChange) and not(o.restoring)
                                           else lastUpgradeCancellableByGuardian),
      pauseState' = if ((o.kind == Unpause or o.kind == MixedRevokeUnpause) and pauseState == "Paused") "None"
                    else pauseState,
      pauseReason' = if ((o.kind == Unpause or o.kind == MixedRevokeUnpause) and pauseState == "Paused") "None"
                     else pauseReason,
      addrFrozen' = if (o.kind == UnfreezeAddress or o.kind == MixedUnfreezeLoosen) false else addrFrozen,
      normalDelay' = if (o.kind == SetNormalDelayFloor) MIN_NORMAL else normalDelay,
      lastExecWaited' = (now - o.scheduledAt >= MIN_NORMAL),
      lastTransitionOk' = true, guardianCancelledRestoring' = false, unfrozenOutsideOperation' = false,
      now' = now, nextId' = nextId,
    }

  // X calls upgradeToAndCall directly (needs APPLICATION_ADMIN)
  action xDirectUpgrade = all {
    xHoldsAdmin, lastUpgradeCancellableByGuardian' = false,
    now' = now, normalDelay' = normalDelay, pauseState' = pauseState, pauseReason' = pauseReason, ops' = ops,
    nextId' = nextId, xHoldsAdmin' = xHoldsAdmin, guardianActive' = guardianActive, addrFrozen' = addrFrozen,
    flagsUnchanged,
  }

  // guardian address freeze (immediate); only an executed unfreezeAddress lifts it
  action guardianFreezeAddress = all {
    guardianActive, addrFrozen' = true,
    now' = now, normalDelay' = normalDelay, pauseState' = pauseState, pauseReason' = pauseReason, ops' = ops,
    nextId' = nextId, xHoldsAdmin' = xHoldsAdmin, guardianActive' = guardianActive,
    lastUpgradeCancellableByGuardian' = lastUpgradeCancellableByGuardian,
    lastTransitionOk' = true, lastExecWaited' = true, guardianCancelledRestoring' = false,
    unfrozenOutsideOperation' = false,
  }

  // pause switch by a guardian holding both roles (SPEC-GOV-004 with REQ-MREG-024); invalid calls revert
  action guardianPause = nondet f = Set("freeze", "pauseGeneral", "pauseMint", "unfreeze", "unpause").oneOf()
    val r = if (f == "pauseGeneral") "General" else if (f == "pauseMint") "MintPathSuspect" else "None"
    val valid = (f == "freeze" and pauseState == "None")
                or ((f == "pauseGeneral" or f == "pauseMint") and not(pauseState == "Paused" and pauseReason == r))
                or (f == "unfreeze" and pauseState == "Frozen")
                or (f == "unpause" and pauseState == "Paused")
    val nxtS = if (not(valid)) pauseState
               else if (f == "freeze") "Frozen"
               else if (f == "pauseGeneral" or f == "pauseMint") "Paused"
               else "None"
    val nxtR = if (not(valid)) pauseReason else if (nxtS == "Paused") r else "None"
    all {
      guardianActive, pauseState' = nxtS, pauseReason' = nxtR,
      lastTransitionOk' = ((pauseState == nxtS and pauseReason == nxtR)
                          or (pauseState == "None" and nxtS != "None")
                          or (pauseState == "Frozen" and nxtS != "Frozen")
                          or (pauseState == "Paused" and nxtS == "None")
                          or (pauseState == "Paused" and nxtS == "Paused" and nxtR != pauseReason)),
      lastExecWaited' = true, guardianCancelledRestoring' = false, unfrozenOutsideOperation' = false,
      now' = now, normalDelay' = normalDelay, ops' = ops, nextId' = nextId, xHoldsAdmin' = xHoldsAdmin,
      guardianActive' = guardianActive, addrFrozen' = addrFrozen,
      lastUpgradeCancellableByGuardian' = lastUpgradeCancellableByGuardian,
    }

  action step = any { schedule, guardianCancel, tick, execute, xDirectUpgrade, guardianFreezeAddress, guardianPause }

  // Invariants
  val execWaitedNormalDelay = lastExecWaited
  val pauseTransitionsLegal = lastTransitionOk and Set("None", "Frozen", "Paused").contains(pauseState)
                              and ((pauseState == "Paused") == (pauseReason != "None"))
  val upgradesGuardianCancellable = lastUpgradeCancellableByGuardian
  val adminOnlyTimelock = not(xHoldsAdmin)
  val normalDelayInBounds = MIN_NORMAL <= normalDelay and normalDelay <= MAX_NORMAL
  val restoringNotGuardianCancellable = not(guardianCancelledRestoring) and not(unfrozenOutsideOperation)
  val all_hold = execWaitedNormalDelay and pauseTransitionsLegal and upgradesGuardianCancellable
                 and adminOnlyTimelock and normalDelayInBounds and restoringNotGuardianCancellable
}
