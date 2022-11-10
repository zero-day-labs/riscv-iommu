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
# Date:     13/10/2022
#
# Description:  Testbench generation script to validate IOMMU register file reading and writing


#   TODO: Check AXI transactions timing
#
#*  Some details discovered when working with verilator and COCÔtb:
#       1.  Accessing to SV packed struct members by their names is not supported by Verilator/cocotb.
#           The packed struct must be handled as an homogeneous array of bits.
#           Reads may be performed using slices. 
#           Writes should be performed through a user-defined function to construct the whole packed struct with desired values
#       2.  When writing, SV packed structs are stored by the simulator so the LS member of the struct is the last one listed in the declaration.
#           When reading, the LS member of the struct is the first one listed in the declaration.
#           All members are stored with the declared edianness.
#       3.  A reset MUST be performed handling the AXI interface, otherwise it won't work well
#       4.  bready and rready are "hardwired" to 1 when reset is active.
#       5.  cocotb-bus must be version 0.1.1. Otherwise the reset signal never gets asserted and simulation gets stuck.

import os
import re
import logging
import pytest

import cocotb
import random
from cocotb.triggers import FallingEdge, Timer, RisingEdge
from cocotb.clock import Clock
from cocotbext.axi import AxiLiteBus, AxiLiteMaster, AxiResp, AxiLiteAWBus
from cocotb.handle import Force, Release

import numpy as np

import math
from enum import Enum, IntEnum
from bitarray import bitarray
from bitarray.util import hex2ba, zeros, int2ba, ba2int
import itertools
import random

class IOMMURegTB:

    def __init__(self, dut):
        self.dut = dut

        self.log = logging.getLogger("IOMMU register file test")
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(dut.clk_i, 1, units="ns").start())    # clock generation

        # connect IOMMU configuration AXI Lite port
        #? Is the False argument correct ?
        bus = AxiLiteBus.from_prefix(dut, "s_axil")
        self.axi_iommu_cfg = AxiLiteMaster(AxiLiteBus.from_prefix(dut, "s_axil"), dut.clk_i)

    # Reset coroutine
    async def resetDUT(self, duration_ns):
        self.dut.rst_ni.value = 0
        await Timer(duration_ns, units="ns")
        self.dut.rst_ni.value = 1
        self.dut._log.debug("Reset complete")

    async def cycle_reset(self):
        self.dut.rst_ni.setimmediatevalue(0)
        await RisingEdge(self.dut.clk_i)
        await RisingEdge(self.dut.clk_i)
        self.dut.rst_ni.value = 1
        await RisingEdge(self.dut.clk_i)
        await RisingEdge(self.dut.clk_i)
        self.dut.rst_ni.value = 0
        await RisingEdge(self.dut.clk_i)
        await RisingEdge(self.dut.clk_i)

    async def AXI_WRTestExp(self):

        await Timer(2, units='ns')

        self.dut.s_axil_awaddr.value = 1
        self.dut.s_axil_awprot.value = 1
        self.dut.s_axil_awvalid.value = 1

        self.dut.s_axil_wdata.value = 1
        self.dut.s_axil_wstrb.value = 1
        self.dut.s_axil_wvalid.value = 1

        self.dut.s_axil_bready.value = 1

        self.dut.s_axil_araddr.value = 1
        self.dut.s_axil_arprot.value = 1
        self.dut.s_axil_arvalid.value = 1

        self.dut.s_axil_rready.value = 1

        await Timer(2, units='ns')

        self.dut.s_axil_awaddr.value = 0
        self.dut.s_axil_awprot.value = 0
        self.dut.s_axil_awvalid.value = 0

        self.dut.s_axil_wdata.value = 0
        self.dut.s_axil_wstrb.value = 0
        self.dut.s_axil_wvalid.value = 0

        self.dut.s_axil_bready.value = 0

        self.dut.s_axil_araddr.value = 0
        self.dut.s_axil_arprot.value = 0
        self.dut.s_axil_arvalid.value = 0

        self.dut.s_axil_rready.value = 0

        await Timer(2, units='ns')

        self.dut.s_axil_awaddr.value = 1
        self.dut.s_axil_awprot.value = 1
        self.dut.s_axil_awvalid.value = 1

        self.dut.s_axil_wdata.value = 1
        self.dut.s_axil_wstrb.value = 1
        self.dut.s_axil_wvalid.value = 1

        self.dut.s_axil_bready.value = 1

        self.dut.s_axil_araddr.value = 1
        self.dut.s_axil_arprot.value = 1
        self.dut.s_axil_arvalid.value = 1

        self.dut.s_axil_rready.value = 1

        await Timer(2, units='ns')
        
        self.dut.s_axil_awaddr.value = 0
        self.dut.s_axil_awprot.value = 0
        self.dut.s_axil_awvalid.value = 0

        self.dut.s_axil_wdata.value = 0
        self.dut.s_axil_wstrb.value = 0
        self.dut.s_axil_wvalid.value = 0

        self.dut.s_axil_bready.value = 0

        self.dut.s_axil_araddr.value = 0
        self.dut.s_axil_arprot.value = 0
        self.dut.s_axil_arvalid.value = 0

        self.dut.s_axil_rready.value = 0

        await Timer(2, units='ns')

# Register indexes
class RegIndex(IntEnum):
    IOMMU_CAPS      = 0
    IOMMU_FCTL      = 1
    IOMMU_DDTP      = 2
    IOMMU_CQB       = 3
    IOMMU_CQH       = 4
    IOMMU_CQT       = 5
    IOMMU_FQB       = 6
    IOMMU_FQH       = 7
    IOMMU_FQT       = 8
    IOMMU_CQCSR     = 9
    IOMMU_FQCSR     = 10
    IOMMU_IPSR      = 11
    IOMMU_ICVEC     = 12
    IOMMU_MSI_ADDR_0    = 13
    IOMMU_MSI_DATA_0    = 14
    IOMMU_MSI_VEC_CTL_0 = 15
    IOMMU_MSI_ADDR_1    = 16
    IOMMU_MSI_DATA_1    = 17
    IOMMU_MSI_VEC_CTL_1 = 18
    IOMMU_MSI_ADDR_2    = 19
    IOMMU_MSI_DATA_2    = 20
    IOMMU_MSI_VEC_CTL_2 = 21
    IOMMU_MSI_ADDR_3    = 22
    IOMMU_MSI_DATA_3    = 23
    IOMMU_MSI_VEC_CTL_3 = 24
    IOMMU_MSI_ADDR_4    = 25
    IOMMU_MSI_DATA_4    = 26
    IOMMU_MSI_VEC_CTL_4 = 27
    IOMMU_MSI_ADDR_5    = 28
    IOMMU_MSI_DATA_5    = 29
    IOMMU_MSI_VEC_CTL_5 = 30
    IOMMU_MSI_ADDR_6    = 31
    IOMMU_MSI_DATA_6    = 32
    IOMMU_MSI_VEC_CTL_6 = 33
    IOMMU_MSI_ADDR_7    = 34
    IOMMU_MSI_DATA_7    = 35
    IOMMU_MSI_VEC_CTL_7 = 36
    IOMMU_MSI_ADDR_8    = 37
    IOMMU_MSI_DATA_8    = 38
    IOMMU_MSI_VEC_CTL_8 = 39
    IOMMU_MSI_ADDR_9    = 40
    IOMMU_MSI_DATA_9    = 41
    IOMMU_MSI_VEC_CTL_9 = 42
    IOMMU_MSI_ADDR_10   = 43
    IOMMU_MSI_DATA_10   = 44
    IOMMU_MSI_VEC_CTL_10    = 45    
    IOMMU_MSI_ADDR_11       = 46
    IOMMU_MSI_DATA_11       = 47
    IOMMU_MSI_VEC_CTL_11    = 48
    IOMMU_MSI_ADDR_12       = 49
    IOMMU_MSI_DATA_12       = 50
    IOMMU_MSI_VEC_CTL_12    = 51
    IOMMU_MSI_ADDR_13       = 52
    IOMMU_MSI_DATA_13       = 53
    IOMMU_MSI_VEC_CTL_13    = 54
    IOMMU_MSI_ADDR_14       = 55
    IOMMU_MSI_DATA_14       = 56
    IOMMU_MSI_VEC_CTL_14    = 57
    IOMMU_MSI_ADDR_15       = 58
    IOMMU_MSI_DATA_15       = 59
    IOMMU_MSI_VEC_CTL_15    = 60

# Register offsets
REG_OFFSETS = [
    hex2ba('0'),
    hex2ba('8'),
    hex2ba('10'),
    hex2ba('18'),
    hex2ba('20'),
    hex2ba('24'),
    hex2ba('28'),
    hex2ba('30'),
    hex2ba('34'),
    hex2ba('48'),
    hex2ba('4c'),
    hex2ba('54'),
    hex2ba('2f8'),
    hex2ba('300'),
    hex2ba('308'),
    hex2ba('30c'),
    hex2ba('310'),
    hex2ba('318'),
    hex2ba('31c'),
    hex2ba('320'),
    hex2ba('328'),
    hex2ba('32c'),
    hex2ba('330'),
    hex2ba('338'),
    hex2ba('33c'),
    hex2ba('340'),
    hex2ba('348'),
    hex2ba('34c'),
    hex2ba('350'),
    hex2ba('358'),
    hex2ba('35c'),
    hex2ba('360'),
    hex2ba('368'),
    hex2ba('36c'),
    hex2ba('370'),
    hex2ba('378'),
    hex2ba('37c'),
    hex2ba('380'),
    hex2ba('388'),
    hex2ba('38c'),
    hex2ba('390'),
    hex2ba('398'),
    hex2ba('39c'),
    hex2ba('3a0'),
    hex2ba('3a8'),
    hex2ba('3ac'),
    hex2ba('3b0'),
    hex2ba('3b8'),
    hex2ba('3bc'),
    hex2ba('3c0'),
    hex2ba('3c8'),
    hex2ba('3cc'),
    hex2ba('3d0'),
    hex2ba('3d8'),
    hex2ba('3dc'),
    hex2ba('3e0'),
    hex2ba('3e8'),
    hex2ba('3ec'),
    hex2ba('3f0'),
    hex2ba('3f8'),
    hex2ba('3fc')
]

# Write byte masks (for write legacy verification)
REG_WSTRB = [
    bitarray('00111111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00001111'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00001111'),
    bitarray('00000111'),
    bitarray('00000111'),
    bitarray('00000001'),
    bitarray('00000011'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001'),
    bitarray('01111111'),
    bitarray('00001111'),
    bitarray('00000001')
]

# Register Request interface slices (upward direcion)
REG_REQ_VALID   = 0
REG_REQ_WSTRB   = slice(1,8)
REG_REQ_WDATA   = slice(9,72)
REG_REQ_WRITE   = 73
REG_REQ_ADDR    = slice(74,86)

# Register Response interface slices
REG_RSP_READY   = 65
REG_RSP_ERROR   = 64
REG_RSP_RDATA   = slice(0,63)

# Reset coroutine
async def resetCycle(reset_n, duration_ns):
    reset_n.value = 0
    await Timer(duration_ns, units="ns")
    reset_n.value = 1
    reset_n._log.debug("Reset complete")


# Generate int value to write to whole reg request bus
def formReqData(addr: int, write: int, wdata: int, wstrb:int, valid:int) -> int:
    addrBA = int2ba(addr,13)
    writeBA = int2ba(write,1)
    wdataBA = int2ba(wdata,64)
    wstrbBA = int2ba(wstrb,8)
    validBA = int2ba(valid,1)

    reqBA = addrBA + writeBA + wdataBA + wstrbBA + validBA
    return ba2int(reqBA)


# Write to one register (64-bits)
async def regWrite(dut, waddr: bitarray, wdata: bitarray, wstrb: bitarray):

    waddrInt = ba2int(waddr)
    wdataInt = ba2int(wdata)
    wstrbInt = ba2int(wstrb)

    # Set write signals
    reqData = formReqData(waddrInt, 1, wdataInt, wstrbInt, 1)
    dut.reg_req_i.value = reqData

    # wait some time
    await Timer(5, units='ns')  # wait some time

    # # wait for ready signal to come up
    # while dut.reg_rsp_o.value[REG_RSP_READY] == 1:
    #     await RisingEdge(dut.clk_i)
    # print("Signal is zero")
    # # wait for signal to come up
    # while not dut.reg_rsp_o.value[REG_RSP_READY]:
    #     await RisingEdge(dut.clk_i)

    # check if there was a write error
    assert dut.reg_rsp_o.value[REG_RSP_ERROR] == 0, "Error signaled by Reg IF when writing"

    # clear valid signal
    reqData = formReqData(0,0,0,0,0)
    dut.reg_req_i.value = reqData


# Read from one register (64-bits)
async def regRead(dut, raddr):

    # convert raddr to int
    addr = ba2int(raddr)
    # set read signals
    reqData = formReqData(addr, 0, 0, 0, 1)
    dut.reg_req_i.value = reqData

    await Timer(5, units='ns')  # wait some time

    # # wait for ready signal to come down
    # while dut.reg_rsp_o.value[REG_RSP_READY] == 1:
    #     await RisingEdge(dut.clk_i)
    # print("Signal is zero")
    # # wait for ready signal to come up
    # while not dut.reg_rsp_o.value[REG_RSP_READY]:
    #     await RisingEdge(dut.clk_i)

    # check if there was a write error
    assert dut.reg_rsp_o.value[REG_RSP_ERROR] == 0, "Error signaled by Reg IF when reading"

    # capture value
    resp = dut.reg_rsp_o.value[REG_RSP_RDATA]

    # clear valid signal
    reqData = formReqData(0, 0, 0, 0, 0)
    dut.reg_req_i.value = reqData

    return resp

# Capabilities register read test
# @cocotb.test()
async def capsReadTest(dut):

    # get DUT and reset
    tb = IOMMURegTB(dut)
    await tb.resetDUT(10)
    # cocotb.start_soon(Clock(dut.clk_i, 1, units="ns").start())    # clock generation
    # await resetDUT(dut.rst_ni, 10)

    # Read doubleword from caps register
    rdata = await regRead(tb.dut, REG_OFFSETS[RegIndex.IOMMU_CAPS])

    # Convert rdata to 64-bit bitarray
    rdataBA = int2ba(int(rdata), 64)
    print(rdataBA)

    # Compare with expected
    refBA = bitarray('0000000000000000000000000111100000000000010000100000001000010000')
    assert rdataBA == refBA, "Supported features do not match"

    # await Timer(10, units='ns')

# Write/read test
# @cocotb.test()
async def WRTest(dut):
    
    FCTL_WWORD = zeros(61) + bitarray('111')
    FCTL_WWORD_EXP = zeros(61) + bitarray('101')
    DDTP_WWORD = zeros(10) + int2ba(4561384684, 44) + zeros(5) + bitarray('1 0110')
    DDTP_WWORD_EXP = zeros(10) + int2ba(4561384684, 44) + zeros(5) + bitarray('0 0000')
    CQB_WWORD = zeros(59) + bitarray('00100')
    CQT_WWORD = zeros(54) + bitarray('1111111111')
    CQT_WWORD_EXP = zeros(54) + bitarray('0000011111')
    CQCSR_WWORD = zeros(64)
    CQCSR_WWORD.setall(1)
    CQCSR_WWORD_EXP = zeros(62) + bitarray('11')


    # get DUT, generate clock and reset
    tb = IOMMURegTB(dut)
    await tb.resetDUT(10)

    # FCTL: Attempt to write to a constrained field (MSI bit)
    # write to fctl register
    await regWrite(tb.dut, REG_OFFSETS[RegIndex.IOMMU_FCTL], FCTL_WWORD, REG_WSTRB[RegIndex.IOMMU_FCTL])
    await Timer(2, units='ns')
    # Read doubleword from FCTL register
    rdata = await regRead(tb.dut, REG_OFFSETS[RegIndex.IOMMU_FCTL])
    # Convert rdata to 64-bit bitarray
    rdataBA = int2ba(int(rdata), 64)
    # Compare with expected
    assert rdataBA == FCTL_WWORD_EXP, "Value read from FCTL does not match with expected"

    await Timer(2, units='ns')

    # DDTP: Attempt to write to a RO field, and to a constrained field
    # write to ddtp register
    await regWrite(tb.dut, REG_OFFSETS[RegIndex.IOMMU_DDTP], DDTP_WWORD, REG_WSTRB[RegIndex.IOMMU_DDTP])
    await Timer(2, units='ns')
    # Read doubleword from DDTP register
    rdata = await regRead(tb.dut, REG_OFFSETS[RegIndex.IOMMU_DDTP])
    # Convert rdata to 64-bit bitarray
    rdataBA = int2ba(int(rdata), 64)
    # Compare with expected
    assert rdataBA == DDTP_WWORD_EXP, "Value read from DDTP does not match with expected"

    await Timer(2, units='ns')

    # CQB and CQT: Test LOGSZ-1 logic
    # write to CQB register
    await regWrite(tb.dut, REG_OFFSETS[RegIndex.IOMMU_CQB], CQB_WWORD, REG_WSTRB[RegIndex.IOMMU_CQB])
    await Timer(2, units='ns')
    # write to CQT register
    await regWrite(tb.dut, REG_OFFSETS[RegIndex.IOMMU_CQT], CQT_WWORD, REG_WSTRB[RegIndex.IOMMU_CQT])
    await Timer(2, units='ns')
    # Read doubleword from CQT register
    rdata = await regRead(tb.dut, REG_OFFSETS[RegIndex.IOMMU_CQT])
    # Convert rdata to 64-bit bitarray
    rdataBA = int2ba(int(rdata), 64)
    # Compare with expected
    assert rdataBA == CQT_WWORD_EXP, "Value read from CQT does not match with expected"

    # CQCSR: Test RW1C logic
    # write to cqcsr register
    await regWrite(tb.dut, REG_OFFSETS[RegIndex.IOMMU_CQCSR], CQCSR_WWORD, REG_WSTRB[RegIndex.IOMMU_CQCSR])
    await Timer(2, units='ns')
    # Read doubleword from cqcsr register
    rdata = await regRead(tb.dut, REG_OFFSETS[RegIndex.IOMMU_CQCSR])
    # Convert rdata to 64-bit bitarray
    rdataBA = int2ba(int(rdata), 64)
    # Compare with expected
    assert rdataBA == CQCSR_WWORD_EXP, "Value read from CQCSR does not match with expected"

# AXI Lite Interface write/read test
@cocotb.test()
async def AXI_WRTest(dut):
    
    FCTL_WWORD = zeros(61) + bitarray('111')
    FCTL_WWORD_EXP = zeros(61) + bitarray('101')
    DDTP_WWORD = zeros(10) + int2ba(4561384684, 44) + zeros(5) + bitarray('1 0110')
    DDTP_WWORD_EXP = zeros(10) + int2ba(4561384684, 44) + zeros(5) + bitarray('0 0000')
    # CQB_WWORD = zeros(59) + bitarray('00100')
    # CQT_WWORD = zeros(54) + bitarray('1111111111')
    # CQT_WWORD_EXP = zeros(54) + bitarray('0000011111')
    CQCSR_WWORD = zeros(64)
    CQCSR_WWORD.setall(1)
    CQCSR_WWORD_EXP = zeros(62) + bitarray('11')

    # get DUT, generate clock and reset
    tb = IOMMURegTB(dut)
    await tb.resetDUT(2)

    # FCTL: Attempt to write to a constrained field (MSI bit)
    # write to fctl register
    await tb.axi_iommu_cfg.write_qword(ba2int(REG_OFFSETS[RegIndex.IOMMU_FCTL]), ba2int(FCTL_WWORD), byteorder='little')
    await Timer(1, units='ns')
    # Read doubleword from FCTL register
    rRes = await tb.axi_iommu_cfg.read_qword(ba2int(REG_OFFSETS[RegIndex.IOMMU_FCTL]), byteorder='little')
    # Compare with expected
    assert rRes == ba2int(FCTL_WWORD_EXP), "Value read from FCTL does not match with expected"

    await Timer(2, units='ns')

    # DDTP
    # write to DTP register
    await tb.axi_iommu_cfg.write_qword(ba2int(REG_OFFSETS[RegIndex.IOMMU_DDTP]), ba2int(DDTP_WWORD), byteorder='little')
    await Timer(1, units='ns')
    # Read doubleword from DDTP register
    rRes = await tb.axi_iommu_cfg.read_qword(ba2int(REG_OFFSETS[RegIndex.IOMMU_DDTP]), byteorder='little')
    # Compare with expected
    assert rRes == ba2int(DDTP_WWORD_EXP), "Value read from DDTP does not match with expected"

    await Timer(2, units='ns')

    # CQCSR
    # write to CQCSR register
    await tb.axi_iommu_cfg.write_qword(ba2int(REG_OFFSETS[RegIndex.IOMMU_CQCSR]), ba2int(CQCSR_WWORD), byteorder='little')
    await Timer(1, units='ns')
    # Read doubleword from CQCSR register
    rRes = await tb.axi_iommu_cfg.read_qword(ba2int(REG_OFFSETS[RegIndex.IOMMU_CQCSR]), byteorder='little')
    # Compare with expected
    assert rRes == ba2int(CQCSR_WWORD_EXP), "Value read from CQCSR does not match with expected"

    await Timer(2, units='ns')

    