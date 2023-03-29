# Copyright © 2023 Manuel Rodríguez & Zero-Day Labs, Lda.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Author:   Manuel Rodríguez <manuel.cederog@gmail.com>
# Date:     28/03/2023
#
# Description:  Makefile to perform lint checks in the RISC-V IOMMU IP using verilator

WARN_FLAGS = -Wno-MULTITOP -Wno-UNOPTFLAT -Wno-CASEINCOMPLETE -Wno-UNSIGNED -Wno-CMPCONST -Wno-SYMRSVDWORD -Wno-LATCH
INCLUDE_PATHS = -I./packages -I./vendor -I./include -I./src -I./src/axi -I./src/cdw -I./src/ddtc -I./src/ig -I./src/interfaces -I./src/iotlb -I./src/pdtc -I./src/ptw -I./src/queue_if -I./src/reg_file

lint:
	verilator --lint-only lint_checks.sv ${INCLUDE_PATHS} ${WARN_FLAGS}

lint_less:
	verilator --lint-only lint_checks.sv -${INCLUDE_PATHS} ${WARN_FLAGS} | less

lint_log:
	verilator --lint-only lint_checks.sv ${INCLUDE_PATHS} ${WARN_FLAGS} 2> verilator_log.txt