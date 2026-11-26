# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Tests for dumps.py, on small Yosys-style JSON netlists written for the tests."""

import json

import dumps

DUMP = {
    "creator": "Yosys 0.62",
    "modules": {
        "sky130_fd_sc_hd__inv_1": {"attributes": {"blackbox": "00000000000000000000000000000001"},
                                   "ports": {}, "cells": {}, "netnames": {}},
        "top": {
            "ports": {},
            "cells": {
                "$abc$1$auto$2": {"type": "$_AND_"},
                "$abc$1$auto$3": {"type": "$_AND_"},
                "q_reg": {"type": "sky130_fd_sc_hd__dfxtp_1"},
            },
            "netnames": {},
        },
    },
}


def test_cell_counts_of_the_top_module():
    assert dumps.cell_counts(DUMP, "top") == {"$_AND_": 2, "sky130_fd_sc_hd__dfxtp_1": 1}


def test_cell_counts_of_a_module_without_cells():
    assert dumps.cell_counts(DUMP, "sky130_fd_sc_hd__inv_1") == {}


def test_compare_equal_counts():
    assert dumps.compare_counts({"$_AND_": 2}, {"$_AND_": 2}) == []


def test_compare_lists_every_difference_in_type_order():
    found = dumps.compare_counts({"$_AND_": 2, "$_OR_": 1}, {"$_AND_": 3, "$_XOR_": 4})
    assert found == ["$_AND_: log 2, dump 3", "$_OR_: log 1, dump 0", "$_XOR_: log 0, dump 4"]


def test_load_reads_a_dump_file(tmp_path):
    path = tmp_path / "001.json"
    path.write_text(json.dumps(DUMP))
    assert dumps.load(path) == DUMP
