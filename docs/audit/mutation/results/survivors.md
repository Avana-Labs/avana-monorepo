# Surviving mutants

`mutation-gate` 43653570827, commit `48864ef`. Each survivor is triaged in [findings-register.md](../../findings-register.md) section 2.2: a test that kills it, or the reason it is equivalent.

## slither-mutate and Gambit

| Tool | Layer | Contract | Location | Change | Result |
|---|---|---|---|---|---|
| slither-mutate | 2.1 | LPOracleCL | line 59 (CR) | `revert MarketMismatch(0)` → `//revert MarketMismatch(0)` | survived (inflated, rerun pending) |
| slither-mutate | 2.1 | LPOracleCL | line 60 (CR) | `_MODULE_LOGIC = moduleLogic` → `//_MODULE_LOGIC = moduleLogic` | survived (inflated, rerun pending) |
| slither-mutate | 2.1 | LPOracleCL | line 65 (RR) | `moduleLogic = _MODULE_LOGIC` → `revert()` | survived (inflated, rerun pending) |
| slither-mutate | 2.1 | LPOracleCL | line 81 (RR) | `_forward(_VIEW_LOGIC)` → `revert()` | survived (inflated, rerun pending) |
| slither-mutate | 2.1 | LPOracleCL | line 82 (RR) | `return report` → `revert()` | survived (inflated, rerun pending) |
| slither-mutate | 2.1 | LPOracleCLInitLogic | line 47 (CR) | `revert NotDelegated()` → `//revert NotDelegated()` | survived (inflated, rerun pending) |
| slither-mutate | 2.1 | LPOracleCLInitLogic | line 63 (CR) | `failed = ok && ret.length == 32 ? abi.decode(ret, (uint256)) : type(uint256).max` → `//failed = ok && ret.length == 32 ? abi.decode(ret, (uint256)) : type(uint256).max` | survived (inflated, rerun pending) |
| slither-mutate | 2.1 | LPOracleCLInitLogic | line 63 (LOR) | `failed = ok && ret.length == 32 ? abi.decode(ret, (uint256)) : type(uint256).max` → `failed = ok  \|\|  ret.length == 32 ? abi.decode(ret, (uint256)) : type(uint256).max` | survived (inflated, rerun pending) |
| slither-mutate | 2.1 | LPOracleCLInitLogic | line 63 (MIA) | `failed = ok && ret.length == 32 ? abi.decode(ret, (uint256)) : type(uint256).max` → `true` | survived (inflated, rerun pending) |
| slither-mutate | 2.1 | LPOracleCLInitLogic | line 63 (SBR) | `failed = ok && ret.length == 32 ? abi.decode(ret, (uint256)) : type(uint256).max` → `failed = ok && ret.length == 32 ? abi.decode(ret, (uint128)) : type(uint128).max` | survived (inflated, rerun pending) |
| slither-mutate | 2.1 | LPOracleCLListingLogic | line 40 (CR) | `revert NotDelegated()` → `//revert NotDelegated()` | survived (inflated, rerun pending) |
| slither-mutate | 2.1 | TimelockSelectors | line 98 (MIA) | `isLaunchShortSelector(selector) \|\| isDaoCancelSelector(selector)` → `true` | survived |
| slither-mutate | 2.1 | TimelockSelectors | line 99 (CR) | `return 0` → `//return 0` | survived |

## Necessist

| Layer | Location | Removed statement |
|---|---|---|
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:104:9-104:35` | `dt = bound(dt, 0, 50_000);` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:105:15-105:22` | `.poke()` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:105:9-105:23` | `oracle.poke();` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:127:15-127:32` | `.setPokeMinGas(1)` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:127:9-127:33` | `oracle.setPokeMinGas(1);` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:128:11-128:23` | `.stopPrank()` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:128:9-128:24` | `vm.stopPrank();` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:129:9-129:40` | `_situation(kind, uint256(ONE));` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:130:9-130:55` | `gasLimit = bound(gasLimit, 10_000, 1_500_000);` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:135:11-135:31` | `.revertToState(snap)` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:135:9-135:32` | `vm.revertToState(snap);` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:65:9-65:57` | `answer = bound(answer, 95_000_000, 101_000_000);` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:68:9-68:34` | `_situation(kind, answer);` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:75:11-75:31` | `.revertToState(snap)` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:75:9-75:32` | `vm.revertToState(snap);` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:77:9-77:107` | `w[OracleInputsLayout.HEAD_WORDS + token * STRIDE + OracleInputsLayout.TOKEN_WORDS + word] = value;` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:78:11-78:121` | `.mockCall(address(store), abi.encodeCall(store.getOracleInputs, (address(oracle), list, true)), abi.encode(w))` |
| 2.1 | `test/fuzz/LPOracle.Confirmation.fuzz.t.sol:78:9-78:122` | `vm.mockCall(address(store), abi.encodeCall(store.getOracleInputs, (address(oracle), list, true)), abi.encode(w));` |
| 2.1 | `test/fuzz/LPOracle.Oracle.fuzz.t.sol:54:11-54:44` | `.warp(T0 + bound(dt, 0, 400_000))` |
| 2.1 | `test/fuzz/LPOracle.Oracle.fuzz.t.sol:54:9-54:45` | `vm.warp(T0 + bound(dt, 0, 400_000));` |
| 2.1 | `test/fuzz/LPOracle.Oracle.fuzz.t.sol:57:13-57:75` | `_round(feeds[i], answerClass[i], raw[i], ageClass[i], age[i]);` |
| 2.1 | `test/fuzz/LPOracle.Oracle.fuzz.t.sol:59:30-59:58` | `oracle.setLock(false, true);` |
| 2.1 | `test/fuzz/LPOracle.Oracle.fuzz.t.sol:59:36-59:57` | `.setLock(false, true)` |
| 2.1 | `test/fuzz/LPOracle.Oracle.fuzz.t.sol:60:35-60:81` | `oracle.setConsistency(false, true, 99, false);` |
| 2.1 | `test/fuzz/LPOracle.Oracle.fuzz.t.sol:60:41-60:80` | `.setConsistency(false, true, 99, false)` |
| 2.1 | `test/fuzz/LPOracle.Oracle.fuzz.t.sol:61:35-61:68` | `oracle.setCompositionFails(true);` |
| 2.1 | `test/fuzz/LPOracle.Oracle.fuzz.t.sol:61:41-61:67` | `.setCompositionFails(true)` |
| 2.1 | `test/fuzz/LPOracle.Oracle.fuzz.t.sol:62:35-62:79` | `oracle.setConsistency(true, false, 0, true);` |
| 2.1 | `test/fuzz/LPOracle.Oracle.fuzz.t.sol:62:41-62:78` | `.setConsistency(true, false, 0, true)` |
| 2.1 | `test/fuzz/LPOracle.Oracle.fuzz.t.sol:63:24-63:38` | `oracle.poke();` |
| 2.1 | `test/fuzz/LPOracle.Oracle.fuzz.t.sol:63:30-63:37` | `.poke()` |
| 2.1 | `test/fuzz/LPOracle.Oracle.fuzz.t.sol:88:9-88:35` | `_pushAll(int256(ONE), t1);` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:43:11-43:41` | `.warp(T0 + bound(dt, 0, 7200))` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:43:9-43:42` | `vm.warp(T0 + bound(dt, 0, 7200));` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:46:13-46:65` | `pA.push(int256(ONE), block.timestamp - MAX_AGE - 1);` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:46:15-46:64` | `.push(int256(ONE), block.timestamp - MAX_AGE - 1)` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:48:13-48:44` | `aB.push(97e6, block.timestamp);` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:48:15-48:43` | `.push(97e6, block.timestamp)` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:50:13-50:70` | `pB.setMode(pB.latestRoundData.selector, ReadMode.Revert);` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:50:15-50:69` | `.setMode(pB.latestRoundData.selector, ReadMode.Revert)` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:51:13-51:70` | `aB.setMode(aB.latestRoundData.selector, ReadMode.Revert);` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:51:15-51:69` | `.setMode(aB.latestRoundData.selector, ReadMode.Revert)` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:53:9-53:49` | `_second(sA, mode[0], answer[0], age[0]);` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:54:9-54:49` | `_second(sB, mode[1], answer[1], age[1]);` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:84:11-84:66` | `.setMode(sA.latestRoundData.selector, ReadMode.BurnGas)` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:84:9-84:67` | `sA.setMode(sA.latestRoundData.selector, ReadMode.BurnGas);` |
| 2.1 | `test/fuzz/LPOracle.ServedViews.fuzz.t.sol:85:9-85:45` | `gas = bound(gas, 50_000, 2_000_000);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:105:13-105:44` | `p = bound(p, 0, MAX_ROUTE + 1);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:106:13-106:44` | `b = bound(b, 0, MAX_ROUTE + 1);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:126:9-126:40` | `q = bound(q, 0, MAX_ROUTE + 1);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:127:9-127:40` | `s = bound(s, 0, MAX_ROUTE + 1);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:212:9-212:52` | `v[i] = bound(v[i] + bump, v[i], MAX_ROUTE);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:215:9-215:55` | `a[j] = bound(a[j] + bump, a[j], 2 ** 128 - 1);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:228:9-228:100` | `(na, nv, nd) = (uint8(bound(na, 0, 10)), uint8(bound(nv, 0, 10)), uint8(bound(nd, 0, 10)));` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:235:25-235:94` | `a[i] = h % 4 == 0 ? 2 ** 128 + (h >> 8) % 1000 : (h >> 8) % 2 ** 128;` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:236:25-236:106` | `v[i] = h % 5 == 0 ? (h % 2 == 0 ? 0 : MAX_ROUTE + 1) : 1 + (h >> 16) % MAX_ROUTE;` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:237:25-237:90` | `d[i] = uint8(h % 7 == 0 ? 78 + (h >> 24) % 100 : (h >> 24) % 19);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:239:17-239:104` | `inBounds = inBounds && a[i] < 2 ** 128 && v[i] >= 1 && v[i] <= MAX_ROUTE && d[i] <= 77;` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:265:9-265:40` | `low = bound(low, 0, MAX_ROUTE);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:266:9-266:44` | `high = bound(high, low, MAX_ROUTE);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:271:13-271:34` | `pv = pv * v[i] / 1e8;` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:307:9-307:44` | `low = bound(low, 0, 2 * MAX_ROUTE);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:319:9-319:37` | `n = bound(n, 1, MAX_TOKENS);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:340:13-340:27` | `t[i] = raw[i];` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:354:13-354:36` | `hit = hit \|\| s == t[i];` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:373:13-373:103` | `legs[i] = LPPriceMath.LegAge(updatedAt[i], borrowAge[i], liquidationAge[i], alternate[i]);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:374:40-374:62` | `newest = updatedAt[i];` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:376:9-376:68` | `_checkAgeLimits(legs, newest + bound(elapsed, 0, 2 ** 33));` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:428:9-428:38` | `fresh = bound(fresh, 1, SAT);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:429:9-429:44` | `accepted = bound(accepted, 1, SAT);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:464:9-464:44` | `accepted = bound(accepted, 1, 4e8);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:486:9-486:36` | `q = bound(q, 1, MAX_ROUTE);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:487:9-487:36` | `p = bound(p, 1, MAX_ROUTE);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:488:9-488:36` | `b = bound(b, 1, MAX_ROUTE);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:489:9-489:50` | `accepted = bound(accepted, 1, MAX_ROUTE);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:490:9-490:39` | `rise = bound(rise, 0, 20_000);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:518:9-518:39` | `answer = bound(answer, -2, 3);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:519:9-519:51` | `nowTs = bound(nowTs, 0, type(uint64).max);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:520:9-520:59` | `startedAt = bound(startedAt, 0, type(uint64).max);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:540:9-540:53` | `window = bound(window, 0, type(uint64).max);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:541:9-541:47` | `blockTime = bound(blockTime, 0, 3600);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:557:9-557:49` | `callGas = bound(callGas, 0, 30_000_000);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:558:9-558:53` | `worstCase = bound(worstCase, 0, 30_000_000);` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:67:13-67:103` | `answerA = int256(bound(uint256(answerA < 0 ? -(answerA + 1) : answerA), 1, 2 ** 128 - 1));` |
| 2.1 | `test/fuzz/LPPriceMath.fuzz.t.sol:68:13-68:103` | `answerB = int256(bound(uint256(answerB < 0 ? -(answerB + 1) : answerB), 1, 2 ** 128 - 1));` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:129:9-129:106` | `_execRevert(revoke, abi.encodeWithSelector(IAvanaTimelockErrors.TimelockAdminRequired.selector));` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:134:9-134:108` | `_execRevert(renounce, abi.encodeWithSelector(IAvanaTimelockErrors.TimelockAdminRequired.selector));` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:222:9-222:31` | `_expectShort(mr, cap);` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:223:9-223:32` | `_expectShort(lvs, cap);` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:224:9-224:43` | `_expectShort(address(other), cap);` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:225:9-225:35` | `_expectShort(ps, disable);` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:226:9-226:36` | `_expectShort(lvs, disable);` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:227:9-227:34` | `_expectShort(ps, remove);` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:228:9-228:34` | `_expectShort(mr, remove);` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:232:9-232:34` | `_expectDao(lvs, restore);` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:233:9-233:33` | `_expectDao(ps, restore);` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:234:9-234:35` | `_expectDao(lvs, unfreeze);` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:235:9-235:29` | `_expectDao(mr, add);` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:236:9-236:41` | `_expectDao(address(other), add);` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:443:11-443:48` | `.warp(block.timestamp + NORMAL_DELAY)` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:443:9-443:49` | `vm.warp(block.timestamp + NORMAL_DELAY);` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:486:11-486:41` | `.prank(aaveGovernanceExecutor)` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:486:9-486:42` | `vm.prank(aaveGovernanceExecutor);` |
| 2.1 | `test/unit/AvanaTimelock.Edges.unit.t.sol:83:9-83:112` | `_execRevert(revoke, abi.encodeWithSelector(IAvanaTimelockErrors.PublicExecutionOnlyByToggle.selector));` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:254:18-254:86` | `(normalTarget, normalSelector) = (rows[i].target, rows[i].selector);` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:261:9-261:82` | `batch[shortCount] = Call(normalTarget, abi.encodePacked(normalSelector));` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:305:11-305:52` | `.warp(block.timestamp + NORMAL_DELAY + 1)` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:305:9-305:53` | `vm.warp(block.timestamp + NORMAL_DELAY + 1);` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:329:9-329:45` | `ops[2] = _two(ops[0][0], ops[1][0]);` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:330:9-330:94` | `ops[3] = _self(abi.encodeWithSignature("setNormalDelay(uint256)", MIN_NORMAL_DELAY));` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:342:9-342:45` | `ops[6] = _two(ops[4][0], ops[0][0]);` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:382:17-382:44` | `vm.warp(t0 + NORMAL_DELAY);` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:382:19-382:43` | `.warp(t0 + NORMAL_DELAY)` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:386:17-386:29` | `vm.warp(t0);` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:386:19-386:28` | `.warp(t0)` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:422:11-422:39` | `.warp(ts + NORMAL_DELAY - 1)` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:422:9-422:40` | `vm.warp(ts + NORMAL_DELAY - 1);` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:534:11-534:27` | `.prank(attacker)` |
| 2.1 | `test/unit/AvanaTimelock.Matrix.unit.t.sol:534:9-534:28` | `vm.prank(attacker);` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:100:11-100:37` | `.prank(governanceMultisig)` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:100:9-100:38` | `vm.prank(governanceMultisig);` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:120:11-120:27` | `.prank(attacker)` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:120:9-120:28` | `vm.prank(attacker);` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:142:11-142:27` | `.prank(attacker)` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:142:9-142:28` | `vm.prank(attacker);` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:60:11-60:52` | `.warp(block.timestamp + NORMAL_DELAY - 1)` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:60:9-60:53` | `vm.warp(block.timestamp + NORMAL_DELAY - 1);` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:64:11-64:37` | `.warp(block.timestamp + 1)` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:64:9-64:38` | `vm.warp(block.timestamp + 1);` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:66:11-66:27` | `.prank(attacker)` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:66:9-66:28` | `vm.prank(attacker);` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:84:11-84:29` | `.warp(readyAt - 1)` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:84:9-84:30` | `vm.warp(readyAt - 1);` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:85:11-85:27` | `.prank(attacker)` |
| 2.1 | `test/unit/AvanaTimelock.RiskChangeProcess.unit.t.sol:85:9-85:28` | `vm.prank(attacker);` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:111:11-111:60` | `.assume(d < MIN_NORMAL_DELAY \|\| d > NORMAL_DELAY)` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:111:9-111:61` | `vm.assume(d < MIN_NORMAL_DELAY \|\| d > NORMAL_DELAY);` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:207:9-207:88` | `predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:245:9-245:35` | `n = uint8(bound(n, 0, 6));` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:250:13-250:55` | `calls[i] = short ? _tighten() : _loosen();` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:316:11-316:39` | `.warp(t0 + NORMAL_DELAY - 1)` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:316:9-316:40` | `vm.warp(t0 + NORMAL_DELAY - 1);` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:339:11-339:44` | `.warp(readyAt + GRACE_PERIOD - 1)` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:339:9-339:45` | `vm.warp(readyAt + GRACE_PERIOD - 1);` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:364:11-364:27` | `.prank(attacker)` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:364:9-364:28` | `vm.prank(attacker);` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:412:9-412:51` | `_execute(governanceMultisig, calls, SALT);` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:502:11-502:48` | `.warp(block.timestamp + NORMAL_DELAY)` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:502:9-502:49` | `vm.warp(block.timestamp + NORMAL_DELAY);` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:582:13-582:62` | `timelock.executeBatch(t, v, p, bytes32(0), SALT);` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:582:21-582:61` | `.executeBatch(t, v, p, bytes32(0), SALT)` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:639:11-639:42` | `.assume(a != address(timelock))` |
| 2.1 | `test/unit/AvanaTimelock.unit.t.sol:639:9-639:43` | `vm.assume(a != address(timelock));` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:134:9-134:21` | `v = _view();` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:203:9-203:39` | `_assertUnknown("startedAt 0");` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:204:12-204:46` | `.setStartedAt(block.timestamp + 1)` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:204:9-204:47` | `seq.setStartedAt(block.timestamp + 1);` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:205:9-205:51` | `_assertUnknown("startedAt in the future");` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:208:9-208:44` | `_assertUnknown("a reverting feed");` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:212:9-212:56` | `_assertUnknown("a failing configuration read");` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:213:14-213:78` | `.setMode(store.sequencer.selector, HostileConfig.Mode.Oversized)` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:213:9-213:79` | `store.setMode(store.sequencer.selector, HostileConfig.Mode.Oversized);` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:226:14-226:42` | `.setTimers(5000, 3600, 1800)` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:226:9-226:43` | `store.setTimers(5000, 3600, 1800);` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:234:11-234:31` | `.warp(failedAt + 99)` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:234:9-234:32` | `vm.warp(failedAt + 99);` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:62:13-62:28` | `.setDecimals(8)` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:62:9-62:29` | `pUsd.setDecimals(8);` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:69:13-69:49` | `.push(USDC_USD, block.timestamp + 1)` |
| 2.1 | `test/unit/DebtOracle.Boundaries.unit.t.sol:69:9-69:50` | `pUsd.push(USDC_USD, block.timestamp + 1);` |
| 2.1 | `test/unit/LPOracle.Access.unit.t.sol:116:9-116:23` | `p = _params();` |
| 2.1 | `test/unit/LPOracle.Access.unit.t.sol:118:9-118:32` | `(ok, ret) = _deploy(p);` |
| 2.1 | `test/unit/LPOracle.Access.unit.t.sol:138:11-138:24` | `.prank(alice)` |
| 2.1 | `test/unit/LPOracle.Access.unit.t.sol:138:9-138:25` | `vm.prank(alice);` |
| 2.1 | `test/unit/LPOracle.Access.unit.t.sol:140:11-140:22` | `.prank(bob)` |
| 2.1 | `test/unit/LPOracle.Access.unit.t.sol:140:9-140:23` | `vm.prank(bob);` |
| 2.1 | `test/unit/LPOracle.Access.unit.t.sol:144:14-144:69` | `.setMode(store.getOracleInputs.selector, ReadMode.Huge)` |
| 2.1 | `test/unit/LPOracle.Access.unit.t.sol:144:9-144:70` | `store.setMode(store.getOracleInputs.selector, ReadMode.Huge);` |
| 2.1 | `test/unit/LPOracle.Access.unit.t.sol:176:11-176:24` | `.prank(alice)` |
| 2.1 | `test/unit/LPOracle.Access.unit.t.sol:176:9-176:25` | `vm.prank(alice);` |
| 2.1 | `test/unit/LPOracle.Access.unit.t.sol:90:11-90:24` | `.prank(alice)` |
| 2.1 | `test/unit/LPOracle.Access.unit.t.sol:90:9-90:25` | `vm.prank(alice);` |
| 2.1 | `test/unit/LPOracle.BorrowGates.unit.t.sol:139:11-139:25` | `.warp(restart)` |
| 2.1 | `test/unit/LPOracle.BorrowGates.unit.t.sol:139:9-139:26` | `vm.warp(restart);` |
| 2.1 | `test/unit/LPOracle.BorrowGates.unit.t.sol:148:9-148:40` | `_pushAll(int256(ONE), restart);` |
| 2.1 | `test/unit/LPOracle.BorrowGates.unit.t.sol:152:9-152:22` | `v = _state();` |
| 2.1 | `test/unit/LPOracle.BorrowGates.unit.t.sol:171:11-171:25` | `.warp(restart)` |
| 2.1 | `test/unit/LPOracle.BorrowGates.unit.t.sol:171:9-171:26` | `vm.warp(restart);` |
| 2.1 | `test/unit/LPOracle.BorrowGates.unit.t.sol:191:11-191:27` | `.warp(T0 + 3700)` |
| 2.1 | `test/unit/LPOracle.BorrowGates.unit.t.sol:191:9-191:28` | `vm.warp(T0 + 3700);` |
| 2.1 | `test/unit/LPOracle.BorrowGates.unit.t.sol:58:9-58:52` | `c.tokens[1].secondSource.twapWindow = 1800;` |
| 2.1 | `test/unit/LPOracle.BorrowGates.unit.t.sol:69:11-69:30` | `.warp(T0 + MAX_AGE)` |
| 2.1 | `test/unit/LPOracle.BorrowGates.unit.t.sol:69:9-69:31` | `vm.warp(T0 + MAX_AGE);` |
| 2.1 | `test/unit/LPOracle.BorrowGates.unit.t.sol:82:9-82:33` | `_sequencerUp(T0 - 7200);` |
| 2.1 | `test/unit/LPOracle.BorrowGates.unit.t.sol:88:11-88:29` | `.warp(T0 + 21_600)` |
| 2.1 | `test/unit/LPOracle.BorrowGates.unit.t.sol:88:9-88:30` | `vm.warp(T0 + 21_600);` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:110:9-110:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:113:9-113:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:118:15-118:37` | `.setListingFailures(0)` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:118:9-118:38` | `oracle.setListingFailures(0);` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:132:9-132:42` | `m.tokenDecimals = new uint8[](2);` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:133:17-133:57` | `.setMarketOf(address(oracle), MARKET, m)` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:133:9-133:58` | `registry.setMarketOf(address(oracle), MARKET, m);` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:138:9-138:24` | `m.decimals = 6;` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:140:17-140:57` | `.setMarketOf(address(oracle), MARKET, m)` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:140:9-140:58` | `registry.setMarketOf(address(oracle), MARKET, m);` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:35:9-35:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:38:9-38:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:41:11-41:30` | `.setBounds(1, 1e19)` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:41:9-41:31` | `pA.setBounds(1, 1e19);` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:44:9-44:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:47:9-47:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:50:9-50:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:60:9-60:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:63:9-63:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:66:9-66:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:69:9-69:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:72:9-72:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:93:9-93:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.CheckConfig.unit.t.sol:96:9-96:48` | `c.tokens[0].secondSource = _twap(deep);` |
| 2.1 | `test/unit/LPOracle.CheckConfigEdges.unit.t.sol:101:9-101:37` | `(tiny[0], tiny[1]) = (1, 1);` |
| 2.1 | `test/unit/LPOracle.CheckConfigEdges.unit.t.sol:118:9-118:42` | `m.tokens = _one(address(tokenA));` |
| 2.1 | `test/unit/LPOracle.CheckConfigEdges.unit.t.sol:119:9-119:42` | `m.tokenDecimals = new uint8[](1);` |
| 2.1 | `test/unit/LPOracle.CheckConfigEdges.unit.t.sol:123:9-123:42` | `m.tokenDecimals = new uint8[](2);` |
| 2.1 | `test/unit/LPOracle.CheckConfigEdges.unit.t.sol:66:11-66:53` | `.mockCallRevert(address(pA), call, "down")` |
| 2.1 | `test/unit/LPOracle.CheckConfigEdges.unit.t.sol:66:9-66:54` | `vm.mockCallRevert(address(pA), call, "down");` |
| 2.1 | `test/unit/LPOracle.CheckConfigEdges.unit.t.sol:77:11-77:72` | `.mockCall(address(store), call, abi.encode(uint256(1) << 16))` |
| 2.1 | `test/unit/LPOracle.CheckConfigEdges.unit.t.sol:77:9-77:73` | `vm.mockCall(address(store), call, abi.encode(uint256(1) << 16));` |
| 2.1 | `test/unit/LPOracle.CheckConfigEdges.unit.t.sol:99:15-99:42` | `.setCompositionFails(false)` |
| 2.1 | `test/unit/LPOracle.CheckConfigEdges.unit.t.sol:99:9-99:43` | `oracle.setCompositionFails(false);` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:118:13-118:31` | `_advance(T0 + 60);` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:126:9-126:27` | `_advance(T0 + 60);` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:130:11-130:30` | `.clearMockedCalls()` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:130:9-130:31` | `vm.clearMockedCalls();` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:135:9-135:28` | `_advance(T0 + 120);` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:149:11-149:24` | `.recordLogs()` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:149:9-149:25` | `vm.recordLogs();` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:151:13-151:35` | `_pokeAt(t + k * 1000);` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:156:9-156:27` | `_pokeAt(t + 3599);` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:218:11-218:36` | `.warp(t + MAX_VERIFY_AGE)` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:218:9-218:37` | `vm.warp(t + MAX_VERIFY_AGE);` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:261:11-261:25` | `.warp(T0 + 60)` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:261:9-261:26` | `vm.warp(T0 + 60);` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:271:11-271:26` | `.setDecimals(8)` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:271:9-271:27` | `pA.setDecimals(8);` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:272:11-272:26` | `.setDecimals(8)` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:272:9-272:27` | `aA.setDecimals(8);` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:288:11-288:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:288:9-288:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:295:11-295:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:295:9-295:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:302:11-302:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:302:9-302:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:65:11-65:24` | `.recordLogs()` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:65:9-65:25` | `vm.recordLogs();` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:82:11-82:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.Decimals.unit.t.sol:82:9-82:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:122:15-122:55` | `.setCompositionFailsBelow(1, 98_000_000)` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:122:9-122:56` | `oracle.setCompositionFailsBelow(1, 98_000_000);` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:135:15-135:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:135:9-135:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:142:15-142:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:142:9-142:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:150:15-150:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:150:9-150:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:151:11-151:27` | `.warp(T1 + 3600)` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:151:9-151:28` | `vm.warp(T1 + 3600);` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:158:15-158:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:158:9-158:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:190:16-190:45` | `.push(int256(ONE), T1 + 1000)` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:190:9-190:46` | `standby.push(int256(ONE), T1 + 1000);` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:205:11-205:33` | `.push(int256(ONE), T1)` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:205:9-205:34` | `aB.push(int256(ONE), T1);` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:214:17-214:106` | `.setRoutes(address(tokenB), _one(address(standby)), _one(address(aB)), RouteSlot.Primary)` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:214:9-214:107` | `registry.setRoutes(address(tokenB), _one(address(standby)), _one(address(aB)), RouteSlot.Primary);` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:215:17-215:46` | `.bumpVersion(address(tokenB))` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:215:9-215:47` | `registry.bumpVersion(address(tokenB));` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:216:11-216:27` | `.warp(T1 + 2000)` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:216:9-216:28` | `vm.warp(T1 + 2000);` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:217:15-217:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:217:9-217:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:218:9-218:50` | `(failedSince,,,) = oracle.storedTimers();` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:46:11-46:26` | `.warp(T1 + 900)` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:46:9-46:27` | `vm.warp(T1 + 900);` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:47:15-47:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:47:9-47:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:67:11-67:27` | `.warp(T1 + 3599)` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:67:9-67:28` | `vm.warp(T1 + 3599);` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:88:15-88:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.Disagreement.unit.t.sol:88:9-88:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:104:11-104:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:104:9-104:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:105:9-105:42` | `_pushAll(int256(ONE), T0 + 7300);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:106:11-106:24` | `.recordLogs()` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:106:9-106:25` | `vm.recordLogs();` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:124:11-124:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:124:9-124:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:148:9-148:34` | `_pokeAt(STALE_AT + 3600);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:151:11-151:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:151:9-151:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:152:9-152:25` | `_othersAt(back);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:153:11-153:35` | `.push(int256(ONE), back)` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:153:9-153:36` | `pB.push(int256(ONE), back);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:154:11-154:35` | `.push(int256(ONE), back)` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:154:9-154:36` | `aB.push(int256(ONE), back);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:163:11-163:29` | `.warp(back + 1800)` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:163:9-163:30` | `vm.warp(back + 1800);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:164:9-164:22` | `v = _state();` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:172:11-172:42` | `.push(int256(ONE), back + 4200)` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:172:9-172:43` | `aB.push(int256(ONE), back + 4200);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:173:15-173:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:173:9-173:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:57:11-57:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:57:9-57:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:58:9-58:36` | `_othersAt(STALE_AT + 3600);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:72:11-72:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:72:9-72:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:73:9-73:30` | `_othersAt(back + 30);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:74:11-74:35` | `.push(int256(ONE), back)` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:74:9-74:36` | `pB.push(int256(ONE), back);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:75:11-75:35` | `.push(int256(ONE), back)` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:75:9-75:36` | `aB.push(int256(ONE), back);` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:85:11-85:29` | `.warp(back + 1799)` |
| 2.1 | `test/unit/LPOracle.Grace.unit.t.sol:85:9-85:30` | `vm.warp(back + 1799);` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:101:9-101:46` | `_assertFailedRead("twapWindow 2^32");` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:102:9-102:54` | `_serveHead(2, uint256(type(uint16).max) + 1);` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:103:9-103:59` | `_assertFailedRead("consistencyToleranceBps 2^16");` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:104:9-104:55` | `_serveHead(8, uint256(type(uint160).max) + 1);` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:105:9-105:60` | `_assertFailedRead("sequencer feed above 160 bits");` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:106:9-106:54` | `_serveHead(9, uint256(type(uint32).max) + 1);` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:112:9-112:40` | `_serve(1, 0, type(uint16).max);` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:113:9-113:63` | `_assertLive("token B tolerance 2^16 - 1 fits uint16");` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:115:9-115:53` | `_assertFailedRead("token B tolerance 2^16");` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:116:9-116:53` | `_serve(0, 1, uint256(type(uint64).max) + 1);` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:117:9-117:49` | `_assertFailedRead("route version 2^64");` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:118:9-118:25` | `_serve(0, 2, 3);` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:126:9-126:53` | `_assertFailedRead("leg with no aggregator");` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:127:9-127:77` | `_serve(0, leg, uint256(uint160(address(pA))) \| (uint256(1) << 160));` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:128:9-128:56` | `_assertFailedRead("aggregator above 160 bits");` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:129:9-129:31` | `_serve(0, leg + 1, 0);` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:130:9-130:78` | `_assertFailedRead("leg with no feed definition (pinned decimals 0)");` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:131:9-131:33` | `_serve(0, leg + 1, 256);` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:132:9-132:50` | `_assertFailedRead("pinned decimals 256");` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:133:9-133:59` | `_serve(1, leg + 4, uint256(type(uint32).max) + 1);` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:134:9-134:53` | `_assertFailedRead("token B heartbeat 2^32");` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:136:9-136:67` | `_serve(0, leg + 2 * L + 7, uint256(type(uint32).max) + 1);` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:149:9-149:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:151:9-151:40` | `failed = oracle.checkConfig(c);` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:181:11-181:54` | `.mockCall(address(tokenB), call, hex"0006")` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:181:9-181:55` | `vm.mockCall(address(tokenB), call, hex"0006");` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:192:11-192:48` | `.mockCall(address(pA), call, hex"01")` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:192:9-192:49` | `vm.mockCall(address(pA), call, hex"01");` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:97:9-97:40` | `_assertLive("unchanged words");` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:98:9-98:41` | `_serveHead(1, type(uint32).max);` |
| 2.1 | `test/unit/LPOracle.Inputs.unit.t.sol:99:9-99:56` | `_assertLive("twapWindow 2^32 - 1 fits uint32");` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:101:11-101:39` | `.warp(block.timestamp + 600)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:101:9-101:40` | `vm.warp(block.timestamp + 600);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:102:9-102:43` | `_keepOthersFresh(block.timestamp);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:103:15-103:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:103:9-103:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:111:15-111:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:111:9-111:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:113:11-113:42` | `.push(int256(ONE), T0 + 80_000)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:113:9-113:43` | `pA.push(int256(ONE), T0 + 80_000);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:114:11-114:42` | `.push(int256(ONE), T0 + 80_000)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:114:9-114:43` | `aA.push(int256(ONE), T0 + 80_000);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:117:9-117:37` | `_keepOthersFresh(back + 60);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:118:11-118:35` | `.push(int256(ONE), back)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:118:9-118:36` | `pB.push(int256(ONE), back);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:119:11-119:35` | `.push(int256(ONE), back)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:119:9-119:36` | `aB.push(int256(ONE), back);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:129:15-129:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:129:9-129:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:131:11-131:42` | `.push(int256(ONE), T0 + 80_000)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:131:9-131:43` | `pA.push(int256(ONE), T0 + 80_000);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:132:11-132:42` | `.push(int256(ONE), T0 + 80_000)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:132:9-132:43` | `aA.push(int256(ONE), T0 + 80_000);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:135:9-135:37` | `_keepOthersFresh(back + 60);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:138:15-138:48` | `.setRound(7, int256(ONE), T0, T0)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:138:9-138:49` | `phase4.setRound(7, int256(ONE), T0, T0);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:139:11-139:50` | `.setPhaseAggregator(4, address(phase4))` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:139:9-139:51` | `pB.setPhaseAggregator(4, address(phase4));` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:140:11-140:77` | `.setRound(uint80((uint256(5) << 64) \| 1), int256(ONE), back, back)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:140:9-140:78` | `pB.setRound(uint80((uint256(5) << 64) \| 1), int256(ONE), back, back);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:141:11-141:35` | `.push(int256(ONE), back)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:141:9-141:36` | `aB.push(int256(ONE), back);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:152:9-152:29` | `_keepOthersFresh(t);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:160:9-160:34` | `_keepOthersFresh(t + 12);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:178:11-178:37` | `.push(int256(ONE), t + 20)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:178:9-178:38` | `na.push(int256(ONE), t + 20);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:181:11-181:37` | `.push(int256(ONE), t + 40)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:181:9-181:38` | `pA.push(int256(ONE), t + 40);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:182:11-182:37` | `.push(int256(ONE), t + 40)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:182:9-182:38` | `aA.push(int256(ONE), t + 40);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:193:11-193:27` | `.warp(T0 + 1000)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:193:9-193:28` | `vm.warp(T0 + 1000);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:194:9-194:41` | `_pushAll(99_990_000, T0 + 1000);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:195:15-195:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:195:9-195:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:196:9-196:43` | `(, at) = oracle.priceCheckpoint();` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:210:11-210:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:210:9-210:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:232:11-232:65` | `.setMode(pB.latestRoundData.selector, ReadMode.Normal)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:232:9-232:66` | `pB.setMode(pB.latestRoundData.selector, ReadMode.Normal);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:233:11-233:65` | `.setMode(aB.latestRoundData.selector, ReadMode.Normal)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:233:9-233:66` | `aB.setMode(aB.latestRoundData.selector, ReadMode.Normal);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:257:11-257:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:257:9-257:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:258:11-258:24` | `.recordLogs()` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:258:9-258:25` | `vm.recordLogs();` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:259:15-259:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:259:9-259:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:54:9-54:39` | `_keepOthersFresh(T0 + 10_000);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:63:9-63:29` | `_keepOthersFresh(t);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:74:11-74:19` | `.warp(t)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:74:9-74:20` | `vm.warp(t);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:76:15-76:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:76:9-76:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:79:9-79:35` | `_keepOthersFresh(t + 150);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:80:11-80:38` | `.push(int256(ONE), t + 100)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:80:9-80:39` | `pB.push(int256(ONE), t + 100);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:81:11-81:38` | `.push(int256(ONE), t + 100)` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:81:9-81:39` | `aB.push(int256(ONE), t + 100);` |
| 2.1 | `test/unit/LPOracle.Poke.unit.t.sol:98:9-98:52` | `test_TEST_042_recoveredAtFirstFreshRound();` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:119:11-119:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:135:15-135:35` | `.revertToState(snap)` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:154:11-154:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:154:9-154:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:155:9-155:42` | `_pushAll(int256(ONE), T0 + 3700);` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:171:11-171:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:171:9-171:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:172:11-172:32` | `.push(int256(ONE), t)` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:172:9-172:33` | `pB.push(int256(ONE), t);` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:173:11-173:32` | `.push(int256(ONE), t)` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:173:9-173:33` | `aB.push(int256(ONE), t);` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:184:9-184:23` | `_lowerFloor();` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:186:11-186:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:186:9-186:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:187:9-187:40` | `_pushAll(int256(ONE), T0 + 60);` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:195:11-195:31` | `.revertToState(snap)` |
| 2.1 | `test/unit/LPOracle.PokeGas.unit.t.sol:195:9-195:32` | `vm.revertToState(snap);` |
| 2.1 | `test/unit/LPOracle.PokeInvariance.unit.t.sol:75:9-75:41` | `_pushAll(int256(ONE), T0 + 600);` |
| 2.1 | `test/unit/LPOracle.PokeInvariance.unit.t.sol:92:9-92:25` | `_block(T0 + 60);` |
| 2.1 | `test/unit/LPOracle.PokeInvariance.unit.t.sol:93:9-93:40` | `_pushAll(int256(ONE), T0 + 60);` |
| 2.1 | `test/unit/LPOracle.Price.unit.t.sol:114:11-114:63` | `.setMode(pA.latestRoundData.selector, ReadMode.Huge)` |
| 2.1 | `test/unit/LPOracle.Price.unit.t.sol:114:9-114:64` | `pA.setMode(pA.latestRoundData.selector, ReadMode.Huge);` |
| 2.1 | `test/unit/LPOracle.Price.unit.t.sol:116:11-116:65` | `.setMode(pA.latestRoundData.selector, ReadMode.Normal)` |
| 2.1 | `test/unit/LPOracle.Price.unit.t.sol:116:9-116:66` | `pA.setMode(pA.latestRoundData.selector, ReadMode.Normal);` |
| 2.1 | `test/unit/LPOracle.Price.unit.t.sol:29:11-29:37` | `.push(99_987_000, T0 + 60)` |
| 2.1 | `test/unit/LPOracle.Price.unit.t.sol:29:9-29:38` | `aA.push(99_987_000, T0 + 60);` |
| 2.1 | `test/unit/LPOracle.Price.unit.t.sol:37:11-37:38` | `.push(100_300_000, T0 + 60)` |
| 2.1 | `test/unit/LPOracle.Price.unit.t.sol:37:9-37:39` | `aA.push(100_300_000, T0 + 60);` |
| 2.1 | `test/unit/LPOracle.Price.unit.t.sol:85:11-85:25` | `.warp(T0 + 60)` |
| 2.1 | `test/unit/LPOracle.Price.unit.t.sol:85:9-85:26` | `vm.warp(T0 + 60);` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:34:9-34:39` | `_assertState(PriceState.Live);` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:35:15-35:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:35:9-35:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:39:9-39:43` | `_assertState(PriceState.Drifting);` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:41:9-41:39` | `_assertState(PriceState.Live);` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:45:9-45:41` | `_assertState(PriceState.Cached);` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:50:11-50:40` | `.push(int256(ONE), T1 + 3600)` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:50:9-50:41` | `pA.push(int256(ONE), T1 + 3600);` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:51:11-51:40` | `.push(int256(ONE), T1 + 3600)` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:51:9-51:41` | `aA.push(int256(ONE), T1 + 3600);` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:52:9-52:42` | `_assertState(PriceState.Expired);` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:66:9-66:39` | `_assertState(PriceState.Live);` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:69:11-69:23` | `.warp(later)` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:69:9-69:24` | `vm.warp(later);` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:70:11-70:36` | `.push(int256(ONE), later)` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:70:9-70:37` | `pA.push(int256(ONE), later);` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:71:11-71:36` | `.push(int256(ONE), later)` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:71:9-71:37` | `aA.push(int256(ONE), later);` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:72:11-72:36` | `.push(int256(ONE), later)` |
| 2.1 | `test/unit/LPOracle.PriceStateDriver.unit.t.sol:72:9-72:37` | `sA.push(int256(ONE), later);` |
| 2.1 | `test/unit/LPOracle.RealStore.unit.t.sol:145:9-145:23` | `g = gasleft();` |
| 2.1 | `test/unit/LPOracle.RealStore.unit.t.sol:146:15-146:30` | `.latestAnswer()` |
| 2.1 | `test/unit/LPOracle.RealStore.unit.t.sol:146:9-146:31` | `oracle.latestAnswer();` |
| 2.1 | `test/unit/LPOracle.Recheck.unit.t.sol:154:14-154:36` | `.setCachedWindow(3000)` |
| 2.1 | `test/unit/LPOracle.Recheck.unit.t.sol:154:9-154:37` | `store.setCachedWindow(3000);` |
| 2.1 | `test/unit/LPOracle.Recheck.unit.t.sol:157:14-157:47` | `.setRound(0.6e8, block.timestamp)` |
| 2.1 | `test/unit/LPOracle.Recheck.unit.t.sol:157:9-157:48` | `fUsdt.setRound(0.6e8, block.timestamp);` |
| 2.1 | `test/unit/LPOracle.Recheck.unit.t.sol:158:17-158:50` | `.setRound(0.6e8, block.timestamp)` |
| 2.1 | `test/unit/LPOracle.Recheck.unit.t.sol:158:9-158:51` | `fUsdtAlt.setRound(0.6e8, block.timestamp);` |
| 2.1 | `test/unit/LPOracle.Recheck.unit.t.sol:159:15-159:48` | `.setRound(0.6e8, block.timestamp)` |
| 2.1 | `test/unit/LPOracle.Recheck.unit.t.sol:159:9-159:49` | `ssUsdt.setRound(0.6e8, block.timestamp);` |
| 2.1 | `test/unit/LPOracle.Recheck.unit.t.sol:170:14-170:69` | `.setSecondSource(usdt, _second(address(ssUsdc)), empty)` |
| 2.1 | `test/unit/LPOracle.Recheck.unit.t.sol:170:9-170:70` | `store.setSecondSource(usdt, _second(address(ssUsdc)), empty);` |
| 2.1 | `test/unit/LPOracle.Recheck.unit.t.sol:232:11-232:35` | `.push(3600e8, T0 + 3600)` |
| 2.1 | `test/unit/LPOracle.Recheck.unit.t.sol:232:9-232:36` | `sB.push(3600e8, T0 + 3600);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:107:17-107:111` | `.setRoutes(address(tokenB), _one(address(pB)), _two(address(aB), address(xB)), RouteSlot.None)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:107:9-107:112` | `registry.setRoutes(address(tokenB), _one(address(pB)), _two(address(aB), address(xB)), RouteSlot.None);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:108:15-108:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:108:9-108:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:110:11-110:42` | `.push(int256(ONE), T0 + 20_000)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:110:9-110:43` | `aB.push(int256(ONE), T0 + 20_000);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:111:11-111:42` | `.push(int256(ONE), T0 + 80_000)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:111:9-111:43` | `pA.push(int256(ONE), T0 + 80_000);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:112:11-112:42` | `.push(int256(ONE), T0 + 80_000)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:112:9-112:43` | `aA.push(int256(ONE), T0 + 80_000);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:113:11-113:42` | `.push(int256(ONE), T0 + 88_250)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:113:9-113:43` | `xB.push(int256(ONE), T0 + 88_250);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:115:11-115:40` | `.push(int256(ONE), back + 60)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:115:9-115:41` | `pA.push(int256(ONE), back + 60);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:116:11-116:40` | `.push(int256(ONE), back + 60)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:116:9-116:41` | `aA.push(int256(ONE), back + 60);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:117:11-117:40` | `.push(int256(ONE), back + 60)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:117:9-117:41` | `sA.push(int256(ONE), back + 60);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:118:11-118:40` | `.push(int256(ONE), back + 60)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:118:9-118:41` | `sB.push(int256(ONE), back + 60);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:119:11-119:35` | `.push(int256(ONE), back)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:119:9-119:36` | `aB.push(int256(ONE), back);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:120:11-120:35` | `.push(int256(ONE), back)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:120:9-120:36` | `pB.push(int256(ONE), back);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:132:9-132:19` | `_outage();` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:133:11-133:35` | `.push(int256(ONE), BACK)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:133:9-133:36` | `aB.push(int256(ONE), BACK);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:140:11-140:31` | `.revertToState(snap)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:140:9-140:32` | `vm.revertToState(snap);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:155:11-155:35` | `.push(int256(ONE), BACK)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:155:9-155:36` | `aB.push(int256(ONE), BACK);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:171:9-171:30` | `(n, rec) = _graces();` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:176:9-176:30` | `(n, rec) = _graces();` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:69:11-69:31` | `.revertToState(snap)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:69:9-69:32` | `vm.revertToState(snap);` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:71:9-71:30` | `(n, rec) = _graces();` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:84:11-84:35` | `.push(int256(ONE), BACK)` |
| 2.1 | `test/unit/LPOracle.RecoveryEdges.unit.t.sol:84:9-84:36` | `pB.push(int256(ONE), BACK);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:218:9-218:42` | `_malform(0, 5, type(uint16).max);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:222:11-222:30` | `.clearMockedCalls()` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:222:9-222:31` | `vm.clearMockedCalls();` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:223:9-223:42` | `_malform(0, 3, type(uint32).max);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:224:9-224:22` | `v = _state();` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:227:11-227:30` | `.clearMockedCalls()` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:227:9-227:31` | `vm.clearMockedCalls();` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:230:11-230:30` | `.clearMockedCalls()` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:230:9-230:31` | `vm.clearMockedCalls();` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:248:11-248:31` | `.push(99_500_000, t)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:248:9-248:32` | `pB.push(99_500_000, t);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:249:11-249:31` | `.push(99_500_000, t)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:249:9-249:32` | `aB.push(99_500_000, t);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:262:11-262:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:262:9-262:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:265:11-265:32` | `.push(99_500_000, t2)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:265:9-265:33` | `aB.push(99_500_000, t2);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:266:9-266:27` | `_malform(0, 0, 3);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:267:11-267:24` | `.recordLogs()` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:267:9-267:25` | `vm.recordLogs();` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:269:9-269:51` | `_assertNoTimerEvent(vm.getRecordedLogs());` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:289:11-289:31` | `.push(99_500_000, t)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:289:9-289:32` | `pB.push(99_500_000, t);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:290:11-290:31` | `.push(99_500_000, t)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:290:9-290:32` | `aB.push(99_500_000, t);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:291:11-291:31` | `.push(99_500_000, t)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:291:9-291:32` | `sB.push(99_500_000, t);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:296:9-296:27` | `_malform(1, 0, 3);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:298:13-298:34` | `vm.warp(t + k * 600);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:298:15-298:33` | `.warp(t + k * 600)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:299:13-299:39` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:299:15-299:38` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:304:11-304:32` | `.warp(staleAt + 3599)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:304:9-304:33` | `vm.warp(staleAt + 3599);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:323:11-323:24` | `.recordLogs()` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:323:9-323:25` | `vm.recordLogs();` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:327:13-327:39` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:327:15-327:38` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:335:9-335:51` | `_assertNoTimerEvent(vm.getRecordedLogs());` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:345:11-345:24` | `.recordLogs()` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:345:9-345:25` | `vm.recordLogs();` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:346:15-346:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:346:9-346:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:360:13-360:70` | `sA.setMode(sA.latestRoundData.selector, ReadMode.Normal);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:360:15-360:69` | `.setMode(sA.latestRoundData.selector, ReadMode.Normal)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:364:11-364:26` | `.setDecimals(8)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:364:9-364:27` | `sA.setDecimals(8);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:369:15-369:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:369:9-369:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:380:11-380:32` | `.push(98_514_852, T1)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:380:9-380:33` | `sA.push(98_514_852, T1);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:432:11-432:19` | `.warp(t)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:432:9-432:20` | `vm.warp(t);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:433:11-433:31` | `.push(99_600_000, t)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:433:9-433:32` | `pB.push(99_600_000, t);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:434:11-434:31` | `.push(99_600_000, t)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:434:9-434:32` | `aB.push(99_600_000, t);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:435:11-435:31` | `.push(99_500_000, t)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:435:9-435:32` | `aA.push(99_500_000, t);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:441:11-441:31` | `.revertToState(snap)` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:441:9-441:32` | `vm.revertToState(snap);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:442:9-442:27` | `_malform(0, 0, 3);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:443:9-443:32` | `_malform(1, 6, 1 << 8);` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:47:15-47:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.SecondSourceWords.unit.t.sol:47:9-47:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:101:9-101:23` | `p = _params();` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:102:9-102:41` | `p.config = _tokens(p.config, 1);` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:103:9-103:39` | `p.isUsdStable = new bool[](1);` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:104:9-104:32` | `(ok, ret) = _deploy(p);` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:107:9-107:41` | `p.config = _tokens(p.config, 9);` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:108:9-108:39` | `p.isUsdStable = new bool[](9);` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:109:9-109:32` | `(ok, ret) = _deploy(p);` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:111:9-111:23` | `p = _params();` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:113:9-113:32` | `(ok, ret) = _deploy(p);` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:126:9-126:23` | `p = _params();` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:128:9-128:30` | `(, ret) = _deploy(p);` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:130:9-130:23` | `p = _params();` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:132:9-132:30` | `(, ret) = _deploy(p);` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:135:9-135:38` | `(, ret) = _deploy(_params());` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:64:9-64:30` | `one[0] = c.tokens[0];` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:68:9-68:23` | `c = _config();` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:71:9-71:33` | `c.marketId = MARKET + 1;` |
| 2.1 | `test/unit/LPOracle.SeedChecks.unit.t.sol:94:9-94:31` | `p.config.marketId = 0;` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:103:9-103:37` | `_assertUnknown("159 bytes");` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:104:9-104:47` | `_answer(_sized(up, ROUND_LENGTH + 1));` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:105:9-105:37` | `_assertUnknown("161 bytes");` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:106:9-106:51` | `_answer(abi.encodePacked(up, uint256(0)));` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:107:9-107:37` | `_assertUnknown("192 bytes");` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:108:9-108:38` | `_answer(_sized(up, 1 << 20));` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:109:9-109:32` | `_assertUnknown("1 MB");` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:110:9-110:49` | `_answer(_sized(down, ROUND_LENGTH + 1));` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:111:9-111:52` | `_assertUnknown("161 bytes reporting down");` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:112:9-112:53` | `_answer(abi.encodePacked(down, uint256(0)));` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:113:9-113:52` | `_assertUnknown("192 bytes reporting down");` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:125:9-125:51` | `_answer(abi.encodePacked(up, uint256(0)));` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:126:13-126:33` | `.measureEvaluation()` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:126:9-126:34` | `this.measureEvaluation();` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:128:9-128:38` | `_answer(_sized(up, 1 << 20));` |
| 2.1 | `test/unit/LPOracle.SequencerAnswer.unit.t.sol:143:70-143:82` | `.startedAt()` |
| 2.1 | `test/unit/LPOracle.SpotReads.unit.t.sol:100:11-100:46` | `.warp(block.timestamp + WINDOW + 1)` |
| 2.1 | `test/unit/LPOracle.SpotReads.unit.t.sol:100:9-100:47` | `vm.warp(block.timestamp + WINDOW + 1);` |
| 2.1 | `test/unit/LPOracle.SpotReads.unit.t.sol:101:9-101:36` | `_setPrices(price0, price1);` |
| 2.1 | `test/unit/LPOracle.SpotReads.unit.t.sol:102:9-102:18` | `_reads();` |
| 2.1 | `test/unit/LPOracle.SpotReads.unit.t.sol:105:9-105:18` | `_reads();` |
| 2.1 | `test/unit/LPOracle.SpotReads.unit.t.sol:136:9-136:39` | `pool = IClPool(address(liar));` |
| 2.1 | `test/unit/LPOracle.SpotReads.unit.t.sol:140:9-140:21` | `pool = real;` |
| 2.1 | `test/unit/LPOracle.SpotReads.unit.t.sol:144:13-144:41` | `liar.lie(lies[i], ticks[i]);` |
| 2.1 | `test/unit/LPOracle.SpotReads.unit.t.sol:144:17-144:40` | `.lie(lies[i], ticks[i])` |
| 2.1 | `test/unit/LPOracle.SpotReads.unit.t.sol:98:9-98:18` | `_reads();` |
| 2.1 | `test/unit/LPOracle.SpotReads.unit.t.sol:99:9-99:82` | `_swapTo(pool, uint160(uint256(_oracleSqrt(price0, price1)) * 102 / 100));` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:104:11-104:32` | `.push(89_000_000, T1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:104:9-104:33` | `pB.push(89_000_000, T1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:105:11-105:32` | `.push(85_000_000, T1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:105:9-105:33` | `aB.push(85_000_000, T1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:133:11-133:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:133:9-133:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:145:11-145:40` | `.push(int256(ONE), T1 + 3600)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:145:9-145:41` | `pA.push(int256(ONE), T1 + 3600);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:146:11-146:40` | `.push(int256(ONE), T1 + 3600)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:146:9-146:41` | `aA.push(int256(ONE), T1 + 3600);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:171:9-171:42` | `_assertPokeMatchesReport("Live");` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:172:11-172:32` | `.push(97_000_000, T1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:172:9-172:33` | `aA.push(97_000_000, T1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:173:9-173:62` | `_assertPokeMatchesReport("Drifting by disagreement");` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:174:11-174:33` | `.push(int256(ONE), T1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:174:9-174:34` | `aA.push(int256(ONE), T1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:175:9-175:34` | `_pushAll(89_000_000, T1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:176:9-176:58` | `_assertPokeMatchesReport("Drifting by the band");` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:177:9-177:35` | `_pushAll(int256(ONE), T1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:178:15-178:53` | `.setConsistency(true, false, 0, false)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:178:9-178:54` | `oracle.setConsistency(true, false, 0, false);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:179:9-179:82` | `_assertPokeMatchesReport("Drifting by an unavailable consistency check");` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:180:15-180:54` | `.setConsistency(false, false, 0, false)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:180:9-180:55` | `oracle.setConsistency(false, false, 0, false);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:181:15-181:36` | `.setLock(false, true)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:181:9-181:37` | `oracle.setLock(false, true);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:182:9-182:61` | `_assertPokeMatchesReport("Cached by the pool lock");` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:183:15-183:37` | `.setLock(false, false)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:183:9-183:38` | `oracle.setLock(false, false);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:184:15-184:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:184:9-184:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:185:9-185:34` | `_pushAll(98_000_000, T1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:186:9-186:68` | `_assertPokeMatchesReport("Cached by the quote-change cap");` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:188:11-188:32` | `.warp(staleAt + 3600)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:188:9-188:33` | `vm.warp(staleAt + 3600);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:189:11-189:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:189:9-189:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:190:11-190:45` | `.push(int256(ONE), staleAt + 3600)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:190:9-190:46` | `pB.push(int256(ONE), staleAt + 3600);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:191:11-191:45` | `.push(int256(ONE), staleAt + 3600)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:191:9-191:46` | `aB.push(int256(ONE), staleAt + 3600);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:215:15-215:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:215:9-215:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:219:11-219:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:219:9-219:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:258:14-258:34` | `.setConfig(p.config)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:258:9-258:35` | `store.setConfig(p.config);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:260:9-260:35` | `_pushAll(int256(ONE), T1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:264:11-264:33` | `.push(105_000_000, T1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:264:9-264:34` | `aA.push(105_000_000, T1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:265:11-265:33` | `.push(105_000_000, T1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:265:9-265:34` | `sA.push(105_000_000, T1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:267:11-267:33` | `.push(101_000_000, T1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:267:9-267:34` | `aB.push(101_000_000, T1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:268:11-268:33` | `.push(101_000_000, T1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:268:9-268:34` | `sB.push(101_000_000, T1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:289:11-289:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:289:9-289:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:290:15-290:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:290:9-290:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:295:11-295:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:295:9-295:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:298:9-298:45` | `(, t1) = oracle.lastAcceptedPrice();` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:301:11-301:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:301:9-301:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:318:15-318:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:318:9-318:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:323:11-323:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:323:9-323:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:324:11-324:39` | `.push(99_000_000, T0 + 3600)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:324:9-324:40` | `pA.push(99_000_000, T0 + 3600);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:325:11-325:39` | `.push(99_000_000, T0 + 3600)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:325:9-325:40` | `aA.push(99_000_000, T0 + 3600);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:330:11-330:27` | `.warp(T0 + 7199)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:330:9-330:28` | `vm.warp(T0 + 7199);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:331:11-331:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:331:9-331:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:332:15-332:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:332:9-332:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:333:9-333:43` | `(, at) = oracle.priceCheckpoint();` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:343:15-343:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:343:9-343:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:348:11-348:31` | `.revertToState(snap)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:348:9-348:32` | `vm.revertToState(snap);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:351:11-351:31` | `.revertToState(snap)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:351:9-351:32` | `vm.revertToState(snap);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:353:11-353:47` | `.push(int256(ONE), T1 + MAX_AGE + 1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:353:9-353:48` | `pA.push(int256(ONE), T1 + MAX_AGE + 1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:354:11-354:47` | `.push(int256(ONE), T1 + MAX_AGE + 1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:354:9-354:48` | `aA.push(int256(ONE), T1 + MAX_AGE + 1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:358:11-358:33` | `.push(int256(ONE), T1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:358:9-358:34` | `aB.push(int256(ONE), T1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:59:11-59:38` | `.push(int256(ONE), staleAt)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:59:9-59:39` | `pB.push(int256(ONE), staleAt);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:60:11-60:38` | `.push(int256(ONE), staleAt)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:60:9-60:39` | `aB.push(int256(ONE), staleAt);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:64:11-64:32` | `.warp(staleAt + 3599)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:64:9-64:33` | `vm.warp(staleAt + 3599);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:85:11-85:34` | `.roll(block.number + 1)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:85:9-85:35` | `vm.roll(block.number + 1);` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:92:11-92:31` | `.warp(staleB + 3599)` |
| 2.1 | `test/unit/LPOracle.StateMachine.unit.t.sol:92:9-92:32` | `vm.warp(staleB + 3599);` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:146:15-146:54` | `.setConsistency(false, false, 0, false)` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:146:9-146:55` | `oracle.setConsistency(false, false, 0, false);` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:154:15-154:37` | `.setLock(false, false)` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:154:9-154:38` | `oracle.setLock(false, false);` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:169:14-169:70` | `.setMode(store.getOracleInputs.selector, ReadMode.Short)` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:169:9-169:71` | `store.setMode(store.getOracleInputs.selector, ReadMode.Short);` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:183:15-183:31` | `.setDecimals(18)` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:183:9-183:32` | `tokenB.setDecimals(18);` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:185:15-185:66` | `.setMode(tokenB.decimals.selector, ReadMode.Revert)` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:185:9-185:67` | `tokenB.setMode(tokenB.decimals.selector, ReadMode.Revert);` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:187:15-187:66` | `.setMode(tokenB.decimals.selector, ReadMode.Normal)` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:187:9-187:67` | `tokenB.setMode(tokenB.decimals.selector, ReadMode.Normal);` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:24:11-24:47` | `.push(int256(ONE), T0 + MAX_AGE + 1)` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:24:9-24:48` | `sA.push(int256(ONE), T0 + MAX_AGE + 1);` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:25:11-25:47` | `.push(int256(ONE), T0 + MAX_AGE + 1)` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:25:9-25:48` | `sB.push(int256(ONE), T0 + MAX_AGE + 1);` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:69:11-69:25` | `.push(1e12, t)` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:69:9-69:26` | `pA.push(1e12, t);` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:71:11-71:42` | `.setRound(9, int256(ONE), t, 0)` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:71:9-71:43` | `pA.setRound(9, int256(ONE), t, 0);` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:73:11-73:47` | `.setRound(10, int256(ONE), t, t + 1)` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:73:9-73:48` | `pA.setRound(10, int256(ONE), t, t + 1);` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:85:15-85:22` | `.poke()` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:85:9-85:23` | `oracle.poke();` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:92:11-92:40` | `.push(int256(ONE), T0 + 4000)` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:92:9-92:41` | `pA.push(int256(ONE), T0 + 4000);` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:93:11-93:40` | `.push(int256(ONE), T0 + 4000)` |
| 2.1 | `test/unit/LPOracle.States.unit.t.sol:93:9-93:41` | `aA.push(int256(ONE), T0 + 4000);` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:109:9-109:39` | `_pushAll(98_500_000, T0 + 12);` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:113:9-113:39` | `_pushAll(99_000_000, T0 + 12);` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:121:13-121:37` | `pA.push(answers[i], T0);` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:121:15-121:36` | `.push(answers[i], T0)` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:122:13-122:37` | `aA.push(answers[i], T0);` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:122:15-122:36` | `.push(answers[i], T0)` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:124:13-124:36` | `oracle.getPriceState();` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:124:19-124:35` | `.getPriceState()` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:125:13-125:37` | `oracle.getTokenPrices();` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:125:19-125:36` | `.getTokenPrices()` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:126:13-126:40` | `oracle.borrowPriceMaxAge();` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:126:19-126:39` | `.borrowPriceMaxAge()` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:127:13-127:45` | `oracle.liquidationPriceMaxAge();` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:127:19-127:44` | `.liquidationPriceMaxAge()` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:128:13-128:38` | `oracle.latestRoundData();` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:128:19-128:37` | `.latestRoundData()` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:130:11-130:63` | `.setMode(pA.latestRoundData.selector, ReadMode.Huge)` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:130:9-130:64` | `pA.setMode(pA.latestRoundData.selector, ReadMode.Huge);` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:131:11-131:64` | `.setMode(sB.latestRoundData.selector, ReadMode.Short)` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:131:9-131:65` | `sB.setMode(sB.latestRoundData.selector, ReadMode.Short);` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:33:15-33:54` | `.setConsistency(false, false, 0, false)` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:33:9-33:55` | `oracle.setConsistency(false, false, 0, false);` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:56:11-56:38` | `.push(104_700_000, T0 + 60)` |
| 2.1 | `test/unit/LPOracle.Stress.unit.t.sol:56:9-56:39` | `sA.push(104_700_000, T0 + 60);` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:229:9-229:49` | `(a3[0], a3[1], a3[2]) = (1e6, 1e6, 1e6);` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:230:9-230:82` | `_assertInvalid(a3, _u2(1e8, 1e8), _d2(6, 6), "more amounts than prices");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:232:9-232:25` | `a1[0] = 1e6 + 1;` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:233:9-233:89` | `_assertInvalid(a1, _u2(1e8, 1e8), _d2(6, 6), "fewer amounts: no token dropped");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:234:9-234:97` | `_assertInvalid(new uint256[](0), new uint256[](0), new uint8[](0), "empty composition");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:235:9-235:61` | `_assertInvalid(a1, a1, new uint8[](1), "one token");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:236:9-236:91` | `_assertInvalid(new uint256[](9), new uint256[](9), new uint8[](9), "nine tokens");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:237:9-237:89` | `_assertInvalid(_u2(1e6, 1e6), _u2(1e8, 1e8), new uint8[](3), "decimals length");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:238:9-238:84` | `_assertInvalid(_u2(2 ** 128, 1), _u2(1e8, 1e8), _d2(6, 6), "amount 2^128");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:239:9-239:74` | `_assertInvalid(_u2(1e6, 1e6), _u2(0, 1e8), _d2(6, 6), "price 0");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:240:9-240:107` | `_assertInvalid(_u2(1e6, 1e6), _u2(1e8, MAX_ROUTE + 1), _d2(6, 6), "price above MAX_ROUTE_ANSWER");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:241:9-241:113` | `_assertInvalid(_u2(1e6, 1e6), _u2(MAX_ROUTE + 1, 1e8), _d2(6, 6), "first price above MAX_ROUTE_ANSWER");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:283:10-283:61` | `.setCompositionTable(10, _u2(5_648_563, 4_348_479))` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:283:9-283:62` | `m.setCompositionTable(10, _u2(5_648_563, 4_348_479));` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:289:10-289:47` | `.setCompositionTable(6, _u2(0, 9999))` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:289:9-289:48` | `m.setCompositionTable(6, _u2(0, 9999));` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:290:10-290:49` | `.setCompositionTable(7, _u2(0, 99_995))` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:290:9-290:50` | `m.setCompositionTable(7, _u2(0, 99_995));` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:291:10-291:50` | `.setCompositionTable(8, _u2(0, 999_954))` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:291:9-291:51` | `m.setCompositionTable(8, _u2(0, 999_954));` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:300:10-300:42` | `.setLinearComposition(_u2(1, 1))` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:300:9-300:43` | `m.setLinearComposition(_u2(1, 1));` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:313:10-313:51` | `.setCompositionTable(6, new uint256[](3))` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:313:9-313:52` | `m.setCompositionTable(6, new uint256[](3));` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:314:10-314:50` | `.setCompositionTable(7, _u2(1e18, 1e18))` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:314:9-314:51` | `m.setCompositionTable(7, _u2(1e18, 1e18));` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:356:9-356:82` | `_assertBandInvalid(_u3(1e8, 1e8, 1e8), _u2(1e8, 1e8), "unequal lengths");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:357:9-357:77` | `_assertBandInvalid(new uint256[](1), new uint256[](1), "one token");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:358:9-358:73` | `_assertBandInvalid(new uint256[](0), new uint256[](0), "empty");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:359:9-359:79` | `_assertBandInvalid(new uint256[](9), new uint256[](9), "nine tokens");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:360:9-360:70` | `_assertBandInvalid(_u2(0, 1e8), _u2(0, 1e8), "a zero quote");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:361:9-361:102` | `_assertBandInvalid(_u2(MAX_ROUTE + 1, 1e8), _u2(1e8, 1e8), "a quote above MAX_ROUTE_ANSWER");` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:462:9-462:66` | `(b, l) = m.ageLimits(new LPPriceMath.LegAge[](0), false);` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:565:9-565:98` | `(up, down, unknown, grace, ready) = m.sequencerStatus(true, true, 2, 1, 1_000_000, 3600);` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:567:9-567:99` | `(up, down, unknown, grace, ready) = m.sequencerStatus(true, true, -1, 1, 1_000_000, 3600);` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:569:9-569:98` | `(up, down, unknown, grace, ready) = m.sequencerStatus(true, true, 0, 0, 1_000_000, 3600);` |
| 2.1 | `test/unit/LPPriceMath.unit.t.sol:571:9-571:106` | `(up, down, unknown, grace, ready) = m.sequencerStatus(true, true, 0, 1_000_001, 1_000_000, 3600);` |
| 2.1 | `test/unit/Lock.unit.t.sol:109:11-109:80` | `.assume(caller != address(adapter) && caller != address(lpVaultSwap))` |
| 2.1 | `test/unit/Lock.unit.t.sol:109:9-109:81` | `vm.assume(caller != address(adapter) && caller != address(lpVaultSwap));` |
| 2.1 | `test/unit/Lock.unit.t.sol:165:11-165:51` | `.assume(caller != address(holderMember))` |
| 2.1 | `test/unit/Lock.unit.t.sol:165:9-165:52` | `vm.assume(caller != address(holderMember));` |
| 2.1 | `test/unit/Lock.unit.t.sol:204:11-204:20` | `.record()` |
| 2.1 | `test/unit/Lock.unit.t.sol:204:9-204:21` | `vm.record();` |
| 2.1 | `test/unit/Lock.unit.t.sol:206:13-206:22` | `.holder()` |
| 2.1 | `test/unit/Lock.unit.t.sol:206:9-206:23` | `lock.holder();` |
| 2.1 | `test/unit/Lock.unit.t.sol:207:13-207:24` | `.isLocked()` |
| 2.1 | `test/unit/Lock.unit.t.sol:207:9-207:25` | `lock.isLocked();` |
| 2.1 | `test/unit/Lock.unit.t.sol:208:16-208:26` | `.release()` |
| 2.1 | `test/unit/Lock.unit.t.sol:208:9-208:27` | `adapter.release();` |
| 2.1 | `test/unit/Lock.unit.t.sol:278:11-278:25` | `.prank(caller)` |
| 2.1 | `test/unit/Lock.unit.t.sol:278:9-278:26` | `vm.prank(caller);` |
| 2.1 | `test/unit/Lock.unit.t.sol:288:11-288:40` | `.deal(address(this), 1 ether)` |
| 2.1 | `test/unit/Lock.unit.t.sol:288:9-288:41` | `vm.deal(address(this), 1 ether);` |
| 2.1 | `test/unit/Lock.unit.t.sol:292:11-292:44` | `.deal(address(outsider), 1 ether)` |
| 2.1 | `test/unit/Lock.unit.t.sol:292:9-292:45` | `vm.deal(address(outsider), 1 ether);` |
| 2.1 | `test/unit/Lock.unit.t.sol:293:11-293:36` | `.prank(address(outsider))` |
| 2.1 | `test/unit/Lock.unit.t.sol:293:9-293:37` | `vm.prank(address(outsider));` |
| 2.1 | `test/unit/Lock.unit.t.sol:297:9-297:80` | `(ok,) = address(lock).call{value: 1}(abi.encodeCall(ILock.holder, ()));` |
| 2.1 | `test/unit/Lock.unit.t.sol:305:11-305:35` | `.prank(address(adapter))` |
| 2.1 | `test/unit/Lock.unit.t.sol:305:9-305:36` | `vm.prank(address(adapter));` |
| 2.1 | `test/unit/Lock.unit.t.sol:335:16-335:26` | `.acquire()` |
| 2.1 | `test/unit/Lock.unit.t.sol:335:9-335:27` | `adapter.acquire();` |
| 2.1 | `test/unit/Lock.unit.t.sol:353:11-353:43` | `.deal(address(adapter), 1 ether)` |
| 2.1 | `test/unit/Lock.unit.t.sol:353:9-353:44` | `vm.deal(address(adapter), 1 ether);` |
| 2.1 | `test/unit/Lock.unit.t.sol:354:11-354:35` | `.prank(address(adapter))` |
| 2.1 | `test/unit/Lock.unit.t.sol:354:9-354:36` | `vm.prank(address(adapter));` |
| 2.1 | `test/unit/Lock.unit.t.sol:357:9-357:50` | `(ok,) = address(lock).call{value: 1}("");` |
| 2.1 | `test/unit/Lock.unit.t.sol:366:9-366:44` | `steps = uint8(bound(steps, 1, 24));` |
| 2.1 | `test/unit/Lock.unit.t.sol:370:17-370:50` | `try adapter.acquire() {} catch {}` |
| 2.1 | `test/unit/Lock.unit.t.sol:372:17-372:54` | `try lpVaultSwap.acquire() {} catch {}` |
| 2.1 | `test/unit/Lock.unit.t.sol:374:17-374:50` | `try adapter.release() {} catch {}` |
| 2.1 | `test/unit/Lock.unit.t.sol:376:17-376:54` | `try lpVaultSwap.release() {} catch {}` |
| 2.1 | `test/unit/Lock.unit.t.sol:416:16-416:26` | `.acquire()` |
| 2.1 | `test/unit/Lock.unit.t.sol:416:9-416:27` | `adapter.acquire();` |
| 2.1 | `test/unit/Lock.unit.t.sol:418:20-418:30` | `.acquire()` |
| 2.1 | `test/unit/Lock.unit.t.sol:418:9-418:31` | `lpVaultSwap.acquire();` |
| 2.1 | `test/unit/Lock.unit.t.sol:66:11-66:64` | `.assume(a != address(0) && b != address(0) && a != b)` |
| 2.1 | `test/unit/Lock.unit.t.sol:66:9-66:65` | `vm.assume(a != address(0) && b != address(0) && a != b);` |
