# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Avana Labs
"""Pytest setup for the Avana Hypothesis suite.

Run settings live next to each test (`@settings(...)` via model.hsettings.cfg) and are
recorded in README.md. Environment knobs:
  AVANA_HYP_SCALE=<float>  multiply every max_examples (default 1; e.g. 0.1 smoke, 5 deep)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
