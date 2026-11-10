# Makefile
# See https://docs.cocotb.org/en/stable/quickstart.html for more info
# From Tiny Tapeout's ttsky-verilog-template, adapted.
#
# SPDX-FileCopyrightText: 2024 Tiny Tapeout
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0

# defaults
SIM ?= icarus
FST ?= -fst # Use more efficient FST format
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(PWD)/../src
# The source files listed in info.yaml, in order
PROJECT_SOURCES = $(shell sed -n 's/^ *- "\([A-Za-z0-9_]*\.sv\)".*/\1/p' $(SRC_DIR)/../info.yaml)

ifneq ($(GATES),yes)

# RTL simulation:
SIM_BUILD				= sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))

else

# Gate level simulation:
SIM_BUILD				= sim_build/gl
COMPILE_ARGS    += -DGL_TEST
COMPILE_ARGS    += -DFUNCTIONAL
COMPILE_ARGS    += -DUSE_POWER_PINS
COMPILE_ARGS    += -DSIM
COMPILE_ARGS    += -DUNIT_DELAY=\#1
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/primitives.v
VERILOG_SOURCES += $(PDK_ROOT)/sky130A/libs.ref/sky130_fd_sc_hd/verilog/sky130_fd_sc_hd.v

# this gets copied in by the GDS action workflow
VERILOG_SOURCES += $(PWD)/gate_level_netlist.v

# Locally, a netlist left over from an earlier design would be tested without a word: say so.
# (A warning, not an error: in CI the netlist comes from an artifact, whose time isn't certain.)
NETLIST = $(PWD)/gate_level_netlist.v
ifeq ($(wildcard $(NETLIST)),)
$(error no gate_level_netlist.v here: copy in a hardened run's netlist, e.g. runs/<run>/final/pnl/tt_um_tiny_breakout.pnl.v)
endif
NEWER_SOURCES = $(shell for f in $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES)); do [ $$f -nt $(NETLIST) ] && echo $$f; done)
ifneq ($(NEWER_SOURCES),)
$(warning warning: gate_level_netlist.v is older than src/$(notdir $(firstword $(NEWER_SOURCES))) (and $(words $(NEWER_SOURCES)) sources in all): it may not be their design)
endif

endif

# Allow sharing configuration between design and testbench via `include`:
COMPILE_ARGS 		+= -I$(SRC_DIR)

# Include the testbench sources:
VERILOG_SOURCES += $(PWD)/tb.v
TOPLEVEL = tb

# List test modules to run, separated by commas and without the .py suffix:
COCOTB_TEST_MODULES = test

# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim
