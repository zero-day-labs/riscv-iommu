// Copyright © 2023 Manuel Rodríguez & Zero-Day Labs, Lda.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Licensed under the Solderpad Hardware License v 2.1 (the “License”); 
// you may not use this file except in compliance with the License, 
// or, at your option, the Apache License version 2.0. 
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/.
// Unless required by applicable law or agreed to in writing, 
// any work distributed under the License is distributed on an “AS IS” BASIS, 
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
// See the License for the specific language governing permissions and limitations under the License.
//
// Author: Manuel Rodríguez <manuel.cederog@gmail.com>
// Date: 12/10/2022
//
// Description: IOMMU memory-mapped register interface package.
//              Defines data structures and other register-related data.
//
// Disclaimer:  This file was generated using LowRISC `reggen` tool. Edit at your own risk.

`ifndef IOMMU_REG_PKG_DEF // if the already-compiled flag is not set...
`define IOMMU_REG_PKG_DEF // set the flag

package iommu_reg_pkg;

  // Address widths within the block
  parameter int BlockAw = 12;

  ////////////////////////////
  // Typedefs for registers //
  ////////////////////////////

  typedef struct packed {
    struct packed {
      logic [7:0]  q;
    } version;
    struct packed {
      logic        q;
    } sv32;
    struct packed {
      logic        q;
    } sv39;
    struct packed {
      logic        q;
    } sv48;
    struct packed {
      logic        q;
    } sv57;
    struct packed {
      logic        q;
    } svpbmt;
    struct packed {
      logic        q;
    } sv32x4;
    struct packed {
      logic        q;
    } sv39x4;
    struct packed {
      logic        q;
    } sv48x4;
    struct packed {
      logic        q;
    } sv57x4;
    struct packed {
      logic        q;
    } amo_mrif;
    struct packed {
      logic        q;
    } msi_flat;
    struct packed {
      logic        q;
    } msi_mrif;
    struct packed {
      logic        q;
    } amo_hwad;
    struct packed {
      logic        q;
    } ats;
    struct packed {
      logic        q;
    } t2gpa;
    struct packed {
      logic        q;
    } endi;
    struct packed {
      logic [1:0]  q;
    } igs;
    struct packed {
      logic        q;
    } hpm;
    struct packed {
      logic        q;
    } dbg;
    struct packed {
      logic [5:0]  q;
    } pas;
    struct packed {
      logic        q;
    } pd8;
    struct packed {
      logic        q;
    } pd17;
    struct packed {
      logic        q;
    } pd20;
  } iommu_reg2hw_capabilities_reg_t;

  typedef struct packed {
    struct packed {
      logic        q;
    } be;
    struct packed {
      logic        q;
    } wsi;
    struct packed {
      logic        q;
    } gxl;
  } iommu_reg2hw_fctl_reg_t;

  typedef struct packed {
    struct packed {
      logic [3:0]  q;
    } iommu_mode;
    struct packed {
      logic        q;
    } busy;
    struct packed {
      logic [43:0] q;
    } ppn;
  } iommu_reg2hw_ddtp_reg_t;

  typedef struct packed {
    struct packed {
      logic [4:0]  q;
    } log2sz_1;
    struct packed {
      logic [43:0] q;
    } ppn;
  } iommu_reg2hw_cqb_reg_t;

  typedef struct packed {
    logic [31:0] q;
  } iommu_reg2hw_cqh_reg_t;

  typedef struct packed {
    logic [31:0] q;
  } iommu_reg2hw_cqt_reg_t;

  typedef struct packed {
    struct packed {
      logic [4:0]  q;
    } log2sz_1;
    struct packed {
      logic [43:0] q;
    } ppn;
  } iommu_reg2hw_fqb_reg_t;

  typedef struct packed {
    logic [31:0] q;
  } iommu_reg2hw_fqh_reg_t;

  typedef struct packed {
    logic [31:0] q;
  } iommu_reg2hw_fqt_reg_t;

  typedef struct packed {
    struct packed {
      logic        q;
    } cqen;
    struct packed {
      logic        q;
    } cie;
    struct packed {
      logic        q;
    } cqmf;
    struct packed {
      logic        q;
    } cmd_to;
    struct packed {
      logic        q;
    } cmd_ill;
    struct packed {
      logic        q;
    } fence_w_ip;
    struct packed {
      logic        q;
    } cqon;
    struct packed {
      logic        q;
    } busy;
  } iommu_reg2hw_cqcsr_reg_t;

  typedef struct packed {
    struct packed {
      logic        q;
    } fqen;
    struct packed {
      logic        q;
    } fie;
    struct packed {
      logic        q;
    } fqmf;
    struct packed {
      logic        q;
    } fqof;
    struct packed {
      logic        q;
    } fqon;
    struct packed {
      logic        q;
    } busy;
  } iommu_reg2hw_fqcsr_reg_t;

  typedef struct packed {
    struct packed {
      logic        q;
    } cip;
    struct packed {
      logic        q;
    } fip;
    struct packed {
      logic        q;
    } pmip;
    struct packed {
      logic        q;
    } pip;
  } iommu_reg2hw_ipsr_reg_t;

  typedef struct packed {
    struct packed {
      logic        q;
    } cy;
    struct packed {
      logic [30:0] q;
    } hpm;
  } iommu_reg2hw_iocountinh_reg_t;

  typedef struct packed {
    struct packed {
      logic [62:0] q;
    } counter;
    struct packed {
      logic        q;
    } of;
  } iommu_reg2hw_iohpmcycles_reg_t;

  typedef struct packed {
    struct packed {
      logic [63:0] q;
    } counter;
  } iommu_reg2hw_iohpmctr_reg_t;

  typedef struct packed {
    struct packed {
      logic [14:0] q;
    } eventid;
    struct packed {
      logic        q;
    } dmask;
    struct packed {
      logic [19:0] q;
    } pid_pscid;
    struct packed {
      logic [23:0] q;
    } did_gscid;
    struct packed {
      logic        q;
    } pv_pscv;
    struct packed {
      logic        q;
    } dv_gscv;
    struct packed {
      logic        q;
    } idt;
    struct packed {
      logic        q;
    } of;
  } iommu_reg2hw_iohpmevt_reg_t;

  typedef struct packed {
    struct packed {
      logic [3:0]  q;
    } civ;
    struct packed {
      logic [3:0]  q;
    } fiv;
    struct packed {
      logic [3:0]  q;
    } pmiv;
    struct packed {
      logic [3:0]  q;
    } piv;
  } iommu_reg2hw_icvec_reg_t;

  typedef struct packed {
    struct packed {
      logic [53:0] q;
    } addr;
  } iommu_reg2hw_msi_addr_reg_t;

  typedef struct packed {
    struct packed {
      logic [31:0] q;
    } data;
  } iommu_reg2hw_msi_data_reg_t;

  typedef struct packed {
    struct packed {
      logic        q;
    } m;
  } iommu_reg2hw_msi_vec_ctl_reg_t;



  typedef struct packed {
    struct packed {
      logic        d;
      logic        de;
    } be;
    struct packed {
      logic        d;
      logic        de;
    } wsi;
    struct packed {
      logic        d;
      logic        de;
    } gxl;
  } iommu_hw2reg_fctl_reg_t;

  typedef struct packed {
    struct packed {
      logic [3:0]  d;
      logic        de;
    } iommu_mode;
    struct packed {
      logic        d;
      logic        de;
    } busy;
    struct packed {
      logic [43:0] d;
      logic        de;
    } ppn;
  } iommu_hw2reg_ddtp_reg_t;

  typedef struct packed {
    struct packed {
      logic [4:0]  d;
      logic        de;
    } log2sz_1;
    struct packed {
      logic [43:0] d;
      logic        de;
    } ppn;
  } iommu_hw2reg_cqb_reg_t;

  typedef struct packed {
    logic [31:0] d;
    logic        de;
  } iommu_hw2reg_cqh_reg_t;

  typedef struct packed {
    logic [31:0] d;
    logic        de;
  } iommu_hw2reg_cqt_reg_t;

  typedef struct packed {
    struct packed {
      logic [4:0]  d;
      logic        de;
    } log2sz_1;
    struct packed {
      logic [43:0] d;
      logic        de;
    } ppn;
  } iommu_hw2reg_fqb_reg_t;

  typedef struct packed {
    logic [31:0] d;
    logic        de;
  } iommu_hw2reg_fqh_reg_t;

  typedef struct packed {
    logic [31:0] d;
    logic        de;
  } iommu_hw2reg_fqt_reg_t;

  typedef struct packed {
    struct packed {
      logic        d;
      logic        de;
    } cqen;
    struct packed {
      logic        d;
      logic        de;
    } cie;
    struct packed {
      logic        d;
      logic        de;
    } cqmf;
    struct packed {
      logic        d;
      logic        de;
    } cmd_to;
    struct packed {
      logic        d;
      logic        de;
    } cmd_ill;
    struct packed {
      logic        d;
      logic        de;
    } fence_w_ip;
    struct packed {
      logic        d;
      logic        de;
    } cqon;
    struct packed {
      logic        d;
      logic        de;
    } busy;
  } iommu_hw2reg_cqcsr_reg_t;

  typedef struct packed {
    struct packed {
      logic        d;
      logic        de;
    } fqen;
    struct packed {
      logic        d;
      logic        de;
    } fie;
    struct packed {
      logic        d;
      logic        de;
    } fqmf;
    struct packed {
      logic        d;
      logic        de;
    } fqof;
    struct packed {
      logic        d;
      logic        de;
    } fqon;
    struct packed {
      logic        d;
      logic        de;
    } busy;
  } iommu_hw2reg_fqcsr_reg_t;

  typedef struct packed {
    struct packed {
      logic        d;
      logic        de;
    } cip;
    struct packed {
      logic        d;
      logic        de;
    } fip;
    struct packed {
      logic        d;
      logic        de;
    } pmip;
    struct packed {
      logic        d;
      logic        de;
    } pip;
  } iommu_hw2reg_ipsr_reg_t;

  typedef struct packed {
    struct packed {
      logic [62:0] d;
      logic        de;
    } counter;
    struct packed {
      logic        d;
      logic        de;
    } of;
  } iommu_hw2reg_iohpmcycles_reg_t;

  typedef struct packed {
    struct packed {
      logic [63:0] d;
      logic        de;
    } counter;
  } iommu_hw2reg_iohpmctr_reg_t;

  typedef struct packed {
    struct packed {
      logic        d;
      logic        de;
    } of;
  } iommu_hw2reg_iohpmevt_reg_t;

  // Register -> HW type
  typedef struct packed {
    iommu_reg2hw_capabilities_reg_t capabilities; // [1772:1736]
    iommu_reg2hw_fctl_reg_t fctl; // [1735:1733]
    iommu_reg2hw_ddtp_reg_t ddtp; // [1732:1684]
    iommu_reg2hw_cqb_reg_t cqb; // [1683:1635]
    iommu_reg2hw_cqh_reg_t cqh; // [1634:1603]
    iommu_reg2hw_cqt_reg_t cqt; // [1602:1571]
    iommu_reg2hw_fqb_reg_t fqb; // [1570:1522]
    iommu_reg2hw_fqh_reg_t fqh; // [1521:1490]
    iommu_reg2hw_fqt_reg_t fqt; // [1489:1458]
    iommu_reg2hw_cqcsr_reg_t cqcsr; // [1457:1450]
    iommu_reg2hw_fqcsr_reg_t fqcsr; // [1449:1444]
    iommu_reg2hw_ipsr_reg_t ipsr; // [1443:1440]
    iommu_reg2hw_iocountinh_reg_t iocountinh;
    iommu_reg2hw_iohpmcycles_reg_t iohpmcycles;
    iommu_reg2hw_iohpmctr_reg_t [30:0] iohpmctr;
    iommu_reg2hw_iohpmevt_reg_t [30:0] iohpmevt;
    iommu_reg2hw_icvec_reg_t icvec; // [1439:1424]
    iommu_reg2hw_msi_addr_reg_t [15:0] msi_addr; // [1423:1368]
    iommu_reg2hw_msi_data_reg_t [15:0] msi_data; // [1367:1336]
    iommu_reg2hw_msi_vec_ctl_reg_t [15:0] msi_vec_ctl; // [1335:1335]
  } iommu_reg2hw_t;

  // HW -> register type
  typedef struct packed {
    iommu_hw2reg_fctl_reg_t             fctl; // [1787:1782]
    iommu_hw2reg_ddtp_reg_t             ddtp; // [1781:1730]
    iommu_hw2reg_cqb_reg_t              cqb; // [1729:1679]
    iommu_hw2reg_cqh_reg_t              cqh; // [1678:1646]
    iommu_hw2reg_cqt_reg_t              cqt; // [1645:1613]
    iommu_hw2reg_fqb_reg_t              fqb; // [1612:1562]
    iommu_hw2reg_fqh_reg_t              fqh; // [1561:1529]
    iommu_hw2reg_fqt_reg_t              fqt; // [1528:1496]
    iommu_hw2reg_cqcsr_reg_t            cqcsr; // [1495:1480]
    iommu_hw2reg_fqcsr_reg_t            fqcsr; // [1479:1468]
    iommu_hw2reg_iohpmcycles_reg_t      iohpmcycles;
    iommu_hw2reg_iohpmctr_reg_t [30:0]  iohpmctr;
    iommu_hw2reg_iohpmevt_reg_t [30:0]  iohpmevt;
    iommu_hw2reg_ipsr_reg_t             ipsr; // [1467:1460]
  } iommu_hw2reg_t;

  // Register offsets
  parameter logic [BlockAw-1:0] IOMMU_CAPABILITIES_OFFSET = 12'h 0;
  parameter logic [BlockAw-1:0] IOMMU_FCTL_OFFSET         = 12'h 8;
  parameter logic [BlockAw-1:0] IOMMU_DDTP_OFFSET         = 12'h 10;
  parameter logic [BlockAw-1:0] IOMMU_CQB_OFFSET          = 12'h 18;
  parameter logic [BlockAw-1:0] IOMMU_CQH_OFFSET          = 12'h 20;
  parameter logic [BlockAw-1:0] IOMMU_CQT_OFFSET          = 12'h 24;
  parameter logic [BlockAw-1:0] IOMMU_FQB_OFFSET          = 12'h 28;
  parameter logic [BlockAw-1:0] IOMMU_FQH_OFFSET          = 12'h 30;
  parameter logic [BlockAw-1:0] IOMMU_FQT_OFFSET          = 12'h 34;
  parameter logic [BlockAw-1:0] IOMMU_CQCSR_OFFSET        = 12'h 48;
  parameter logic [BlockAw-1:0] IOMMU_FQCSR_OFFSET        = 12'h 4c;
  parameter logic [BlockAw-1:0] IOMMU_IPSR_OFFSET         = 12'h 54;
  parameter logic [BlockAw-1:0] IOMMU_IOCNTOVF_OFFSET     = 12'h 58;
  parameter logic [BlockAw-1:0] IOMMU_IOCNTINH_OFFSET     = 12'h 5c;
  parameter logic [BlockAw-1:0] IOMMU_IOHPMCYCLES_OFFSET  = 12'h 60;
  parameter logic [BlockAw-1:0] IOMMU_IOHPMCTR_OFFSET     = 12'h 68;
  parameter logic [BlockAw-1:0] IOMMU_IOHPMEVT_OFFSET     = 12'h 160;
  parameter logic [BlockAw-1:0] IOMMU_ICVEC_OFFSET        = 12'h 2f8;
  parameter logic [BlockAw-1:0] IOMMU_MSI_ADDR_OFFSET     = 12'h 300;
  parameter logic [BlockAw-1:0] IOMMU_MSI_DATA_OFFSET     = 12'h 308;
  parameter logic [BlockAw-1:0] IOMMU_MSI_VEC_CTL_OFFSET  = 12'h 30c;

  // Register width information to check illegal writes
  parameter logic [7:0] IOMMU_PERMIT [21] = '{
    8'b 00111111, // IOMMU_CAPABILITIES
    8'b 00000001, // IOMMU_FCTL
    8'b 01111111, // IOMMU_DDTP
    8'b 01111111, // IOMMU_CQB
    8'b 00001111, // IOMMU_CQH
    8'b 11110000, // IOMMU_CQT
    8'b 01111111, // IOMMU_FQB
    8'b 00001111, // IOMMU_FQH
    8'b 11110000, // IOMMU_FQT
    8'b 00000111, // IOMMU_CQCSR
    8'b 01110000, // IOMMU_FQCSR
    8'b 00010000, // IOMMU_IPSR
    8'b 00001111, // IOMMU_IOCNTOVF
    8'b 11110000, // IOMMU_IOCNTINH
    8'b 11111111, // IOMMU_IOHPMCYCLES
    8'b 11111111, // IOMMU_IOHPMCTR
    8'b 11111111, // IOMMU_IOHPMEVT
    8'b 00000011, // IOMMU_ICVEC
    8'b 01111111, // IOMMU_MSI_ADDR
    8'b 00001111, // IOMMU_MSI_DATA
    8'b 00010000  // IOMMU_MSI_VEC_CTL
  };

endpackage

`endif