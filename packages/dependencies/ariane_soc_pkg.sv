// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Florian Zaruba, ETH Zurich
// Description: Contains SoC information as constants

`ifndef ARIANE_SOC
`define ARIANE_SOC

`include "ariane_pkg.sv"
package ariane_soc;
  // M-Mode Hart, S-Mode Hart
  localparam int unsigned NumTargets = 2;
  // Uart, SPI, Ethernet, reserved
  localparam int unsigned NumSources = 30;
  localparam int unsigned MaxPriority = 7;

  typedef enum int unsigned {
    CVA6        = 0,
    DEBUG       = 1,   
    IOMMU_COMP  = 2,  // IOMMU Master IF to give completions to TRs
    IOMMU_MEM   = 3   // IOMMU Master IF for implicit memory accesses
  } axi_master_t;

  // Added IOMMU Completion IF port and Memory IF port (+2)
  localparam NrSlaves = 2+2; // actually masters, but slaves on the crossbar

  // 4 is recommended by AXI standard, so lets stick to it, do not change
  localparam IdWidth   = 4;
  localparam IdWidthSlave = IdWidth + $clog2(NrSlaves);

  localparam IOMMUNumWires = 4;

  // must be in order from highest address to lowest
  typedef enum int unsigned {
    DRAM      =  0,
    IOMMU_CFG =  1, // IOMMU programming IF
    DMA_CFG   =  2, // DMA slave port for configuration of the engine
    GPIO      =  3,
    Ethernet  =  4,
    SPI       =  5,
    Timer     =  6,
    UART      =  7,
    PLIC      =  8,
    CLINT     =  9,
    ROM       =  10,
    Debug     =  11
  } axi_slaves_t;

  localparam NB_PERIPHERALS = Debug + 1;


  localparam logic[63:0] DebugLength    = 64'h1000;
  localparam logic[63:0] ROMLength      = 64'h10000;
  localparam logic[63:0] CLINTLength    = 64'hC0000;
  localparam logic[63:0] PLICLength     = 64'h3FF_FFFF;
  localparam logic[63:0] UARTLength     = 64'h1000;
  localparam logic[63:0] TimerLength    = 64'h1000;
  localparam logic[63:0] SPILength      = 64'h800000;
  localparam logic[63:0] EthernetLength = 64'h10000;
  localparam logic[63:0] GPIOLength     = 64'h1000;
  localparam logic[63:0] DMALength      = 64'h1000;     //? Correct value for this?
  localparam logic[63:0] IOMMULength    = 64'h1000;     // Regmap occupies 4kiB of memory address space
  localparam logic[63:0] DRAMLength     = 64'h40000000; // 1GByte of DDR (split between two chips on Genesys2)
  localparam logic[63:0] SRAMLength     = 64'h1800000;  // 24 MByte of SRAM
  // Instantiate AXI protocol checkers
  localparam bit GenProtocolChecker = 1'b0;

  typedef enum logic [63:0] {
    DebugBase    = 64'h0000_0000,
    ROMBase      = 64'h0001_0000,
    CLINTBase    = 64'h0200_0000,
    PLICBase     = 64'h0C00_0000,
    UARTBase     = 64'h1000_0000,
    TimerBase    = 64'h1800_0000,
    SPIBase      = 64'h2000_0000,
    EthernetBase = 64'h3000_0000,
    GPIOBase     = 64'h4000_0000,
    DMABase      = 64'h5000_0000, //? Correct value for this?
    IOMMUBase    = 64'h5001_0000, //? Correct value for this?
    DRAMBase     = 64'h8000_0000
  } soc_bus_start_t;

  localparam NrRegion = 1;
  localparam logic [NrRegion-1:0][NB_PERIPHERALS-1:0] ValidRule = {{NrRegion * NB_PERIPHERALS}{1'b1}};

  /* verilator lint_off WIDTH */
  /* verilator lint_off WIDTHCONCAT */
  localparam ariane_pkg::ariane_cfg_t ArianeSocCfg = '{
    RASDepth: cva6_config_pkg::CVA6ConfigRASDepth,
    BTBEntries: cva6_config_pkg::CVA6ConfigBTBEntries,
    BHTEntries: cva6_config_pkg::CVA6ConfigBHTEntries,
    // idempotent region
    NrNonIdempotentRules:  1,
    NonIdempotentAddrBase: {64'b0},
    NonIdempotentLength:   {DRAMBase},
    NrExecuteRegionRules:  3,
    ExecuteRegionAddrBase: {DRAMBase,   ROMBase,   DebugBase},
    ExecuteRegionLength:   {DRAMLength, ROMLength, DebugLength},
    // cached region
    NrCachedRegionRules:    1,
    CachedRegionAddrBase:  {DRAMBase},
    CachedRegionLength:    {DRAMLength},
    //  cache config
    AxiCompliant:           1'b1,
    SwapEndianess:          1'b0,
    // debug
    DmBaseAddress:          DebugBase,
    NrPMPEntries:           cva6_config_pkg::CVA6ConfigNrPMPEntries
  };
  /* verilator lint_on WIDTHCONCAT */
  /* verilator lint_on WIDTH */

endpackage

`endif
