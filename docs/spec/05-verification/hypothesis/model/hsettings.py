# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Shared Hypothesis settings. Every test's budget is stated here or at the test and in README."""
import os

from hypothesis import HealthCheck, Phase, settings

SCALE = float(os.environ.get("AVANA_HYP_SCALE", "1"))


def cfg(max_examples, stateful_step_count=None):
    kw = dict(max_examples=max(1, int(max_examples * SCALE)), deadline=None, database=None,
              print_blob=True, derandomize=False,
              suppress_health_check=[HealthCheck.too_slow, HealthCheck.filter_too_much,
                                     HealthCheck.data_too_large])
    if os.environ.get("AVANA_HYP_NOSHRINK"):
        kw["phases"] = [Phase.explicit, Phase.reuse, Phase.generate]
    if stateful_step_count is not None:
        kw["stateful_step_count"] = stateful_step_count
    return settings(**kw)
