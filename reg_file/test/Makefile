# Makefile for cocotb test

# defaults
SIM ?= verilator
TOPLEVEL_LANG ?= verilog	# SV

# SV source files
VERILOG_SOURCES += $(PWD)/../iommu_reg_top_exp.sv $(PWD)/../iommu_field.sv $(PWD)/../iommu_field_arb.sv

# TOPLEVEL is the name of the toplevel module in your Verilog or VHDL file
TOPLEVEL = iommu_reg_top

# MODULE is the basename of the Python test file
MODULE = iommu_reg_test

# Set this to 1 to enable the GUI mode in the simulator (if supported).
# GUI = 1

# to produce waveforms in FST format, used by GTKWave
EXTRA_ARGS += -I$(PWD)/../ --trace-fst --trace-structs --trace-max-array 64 --trace-max-width 1024 --no-trace-params

# Default time unit that should be assumed for simulation when not specified by modules in the design.
# COCOTB_HDL_TIMEUNIT = 1ns

# Default time precision that should be assumed for simulation when not specified by modules in the design.
# COCOTB_HDL_TIMEPRECISION = 1ps


# include cocotb's make rules to take care of the simulator setup
include $(shell cocotb-config --makefiles)/Makefile.sim
