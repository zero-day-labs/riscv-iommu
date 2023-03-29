WARN_FLAGS = -Wno-MULTITOP -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST -Wno-SYMRSVDWORD -Wno-LATCH
INCLUDE_PATHS = -I./packages -I./vendor -I./include -I./src -I./src/axi -I./src/cdw -I./src/ddtc -I./src/ig -I./src/interfaces -I./src/iotlb -I./src/pdtc -I./src/ptw -I./src/queue_if -I./src/reg_file

lint:
	verilator --lint-only lint_checks.sv ${INCLUDE_PATHS} ${WARN_FLAGS}

lint_less:
	verilator --lint-only lint_checks.sv -${INCLUDE_PATHS} ${WARN_FLAGS} | less

lint_log:
	verilator --lint-only lint_checks.sv ${INCLUDE_PATHS} ${WARN_FLAGS} 2> verilator_log.txt