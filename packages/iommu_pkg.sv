// Copyright (c) 2022 University of Minho
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

// Licensed under the Solderpad Hardware License v 2.1 (the “License”); 
// you may not use this file except in compliance with the License, 
// or, at your option, the Apache License version 2.0. 
// You may obtain a copy of the License at https://solderpad.org/licenses/SHL-2.1/.
// Unless required by applicable law or agreed to in writing, 
// any work distributed under the License is distributed on an “AS IS” BASIS, 
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. 
// See the License for the specific language governing permissions and limitations under the License.
/*
    Author: Manuel Rodríguez, University of Minho <manuel.cederog@gmail.com>
    Date:    10/11/2022

    Description: RISC-V IOMMU overall SV package.
*/

package iommu_pkg;

    // Device Context max length
    localparam DEV_ID_MAX_LEN   = 24;
    localparam PROC_ID_MAX_LEN  = 20;

    // to identify memory accesses to virtual guest interrupt files
    localparam MSI_MASK_LEN     = 52;
    localparam MSI_PATTERN_LEN  = 52;

    //------------------------
    //#  Context Fields
    //------------------------

    // MSI Address Pattern
    typedef struct packed {
        logic [11:0]                    reserved;
        logic [(MSI_PATTERN_LEN-1):0]   pattern;
    } msi_addr_pattern_t;

    // MSI Address Mask
    typedef struct packed {
        logic [11:0]                reserved;
        logic [(MSI_MASK_LEN-1):0]  mask;
    } msi_addr_mask_t;

    // MSI Page Table Pointer
    typedef struct packed {
        logic [3:0]     mode;
        logic [15:0]    reserved;
        logic [43:0]    ppn;
    } msiptp_t;

    // First Stage Context
    typedef struct packed {
        logic [3:0]     mode;
        logic [15:0]    reserved;
        logic [43:0]    ppn;
    } fsc_t;

    // Translation Attributes for Device Context
    typedef struct packed {
        logic [31:0] reserved_2;
        logic [19:0] pscid;
        logic [11:0] reserved_1;
    } dc_ta_t;

    // Translation Attributes for Process Context
    typedef struct packed {
        logic [31:0]    reserved_2;
        logic [19:0]    pscid;
        logic [8:0]     reserved_1;
        logic           sum;
        logic           ens;
        logic           v;
    } pc_ta_t;

    // IO Hypervisor Guest Address Translation and Protection
    typedef struct packed {
        logic [3:0]     mode;
        logic [15:0]    gscid;
        logic [43:0]    ppn;
    } iohgatp_t;

    // Translation Control
   typedef struct packed {
        logic [31:0]    reserved_2;
        logic [7:0]     custom;
        logic [11:0]    reserved_1;
        logic           sxl;
        logic           sbe;
        logic           dpe;
        logic           sade;
        logic           gade;
        logic           prpr;
        logic           pdtv;
        logic           dtf;
        logic           t2gpa;
        logic           en_pri;
        logic           en_ats;
        logic           v;
   } tc_t;

   // Non-leaf DDT/PDT entry (64-bits)
    typedef struct packed {
        logic [9:0]     reserved_2;
        logic [43:0]    ppn;
        logic [8:0]     reserved_1;
        logic           v;
    } nl_entry_t;

    //--------------------------
    //#  Device Context Structs
    //--------------------------

    // Base format Device Context
    typedef struct packed {
        fsc_t       fsc;
        dc_ta_t     ta;
        iohgatp_t   iohgatp;
        tc_t        tc;
    } dc_base_t;
    
    // Extended format Device Context
    typedef struct packed {
        logic [63:0]        reserved;
        msi_addr_pattern_t  msi_addr_pattern;
        msi_addr_mask_t     msi_addr_mask;
        msiptp_t            msiptp;
        fsc_t               fsc;
        dc_ta_t             ta;
        iohgatp_t           iohgatp;
        tc_t                tc;
    } dc_ext_t;

    //--------------------------
    //#  Process Context Struct
    //--------------------------

    // Process Context
    typedef struct packed {
        fsc_t   fsc;
        pc_ta_t ta;
    } pc_t;

    //--------------------------
    //#  MSI Address Translation
    //--------------------------

    typedef enum logic [1:0] {
        RSV_1           = 2'b00;
        MRIF            = 2'b01;
        RSV_2           = 2'b10;
        WRITE_THROUGH   = 2'b11;
    } msi_pte_mode_e;

    // MSI PTE (Write-through mode)
    typedef struct packed {
        logic           c;
        logic [8:0]     reserved_2;
        logic [44-1:0]  ppn;
        logic [6:0]     reserved_1;
        msi_pte_mode_e  m;
        logic           v;
    } msi_wt_pte_t;

    // MSI PTE (MRIF mode)
    typedef struct packed {
        logic [2:0]     reserved_4;
        logic           nid_10;
        logic [5:0]     reserved_3;
        logic [44-1:0]  nppn;
        logic [9:0]     nid_9_0;
        logic           c;
        logic [8:0]     reserved_2;
        logic [47-1:0]  ppn;
        logic [3:0]     reserved_1;
        msi_pte_mode_e  m;
        logic           v;
    } msi_mrif_pte_t;

    //-----------------------------
    //#  IOMMU fault CAUSE encoding
    //-----------------------------

    // max 12 bits to encode CAUSE
    // cause encondings 275 to 2047 are reserved. Encodings 2048 through 4095 are for custom use.
    localparam CAUSE_LEN = 12;

    // Fault/event cases
    localparam logic [CAUSE_LEN-1:0] INSTR_ACCESS_FAULT     = 1;  // Illegal access as governed by PMPs and PMAs
    localparam logic [CAUSE_LEN-1:0] LD_ADDR_MISALIGNED     = 4;  // Read address misaligned
    localparam logic [CAUSE_LEN-1:0] LD_ACCESS_FAULT        = 5;  // Illegal access as governed by PMPs and PMAs
    localparam logic [CAUSE_LEN-1:0] ST_ADDR_MISALIGNED     = 6;  // Write/AMO address misaligned
    localparam logic [CAUSE_LEN-1:0] ST_ACCESS_FAULT        = 7;  // Illegal write/AMO access as governed by PMPs and PMAs
    localparam logic [CAUSE_LEN-1:0] INSTR_PAGE_FAULT       = 12; // Instruction page fault
    localparam logic [CAUSE_LEN-1:0] LOAD_PAGE_FAULT        = 13; // Load/read page fault
    localparam logic [CAUSE_LEN-1:0] STORE_PAGE_FAULT       = 15; // Store/write/AMO page fault
    localparam logic [CAUSE_LEN-1:0] INSTR_GUEST_PAGE_FAULT = 20; // Instruction guest page fault
    localparam logic [CAUSE_LEN-1:0] LOAD_GUEST_PAGE_FAULT  = 21; // Load/read guest-page fault
    localparam logic [CAUSE_LEN-1:0] STORE_GUEST_PAGE_FAULT = 23; // Store/write/AMO guest-page fault

    // Extended IOMMU fault cases (include in riscv_pkg ???)
    localparam logic [CAUSE_LEN-1:0] ALL_INB_TRANSACTIONS_DISALLOWED    = 256;  // IOMMU off / ATS requested and not supported
    localparam logic [CAUSE_LEN-1:0] DDT_ENTRY_LD_ACCESS_FAULT          = 257;  // PMP/PMA fault when accessing 'ddtp' or 'DC' 
    localparam logic [CAUSE_LEN-1:0] DDT_ENTRY_INVALID                  = 258;  // When either 'ddtp' or 'DC' are not valid
    localparam logic [CAUSE_LEN-1:0] DDT_ENTRY_MISCONFIGURED            = 259;  // Configuration checks failed (See section 2.1.4)
    localparam logic [CAUSE_LEN-1:0] TRANS_TYPE_DISALLOWED              = 260;
    localparam logic [CAUSE_LEN-1:0] MSI_PTE_LD_ACCESS_FAULT            = 261;  // PMP/PMA checkn fault when accessing MSI PTE
    localparam logic [CAUSE_LEN-1:0] MSI_PTE_INVALID                    = 262;
    localparam logic [CAUSE_LEN-1:0] MSI_PTE_MISCONFIGURED              = 263;
    localparam logic [CAUSE_LEN-1:0] MRIF_ACCESS_FAULT                  = 264;
    localparam logic [CAUSE_LEN-1:0] PDT_ENTRY_LD_ACCESS_FAULT          = 265;
    localparam logic [CAUSE_LEN-1:0] PDT_ENTRY_INVALID                  = 266;
    localparam logic [CAUSE_LEN-1:0] PDT_ENTRY_MISCONFIGURED            = 267;
    localparam logic [CAUSE_LEN-1:0] DDT_DATA_CORRUPTION                = 268;  //? What is the difference between data corruption and misconfigured ?
    localparam logic [CAUSE_LEN-1:0] PDT_DATA_CORRUPTION                = 269;
    localparam logic [CAUSE_LEN-1:0] MSI_PT_DATA_CORRUPTION             = 270;
    localparam logic [CAUSE_LEN-1:0] MSI_MRIF_DATA_CORRUPTION           = 271;
    localparam logic [CAUSE_LEN-1:0] INTERN_DATAPATH_FAULT              = 272;
    localparam logic [CAUSE_LEN-1:0] MSI_ST_ACCESS_FAULT                = 273;
    localparam logic [CAUSE_LEN-1:0] PT_DATA_CORRUPTION                 = 274;

    // TODO: Transaction type encoding
    localparam TTYP_LEN = 6;

    localparam logic [TTYP_LEN-1:0] NONE                = 6'b000000;
    // Untranslated (!b3 && !b2)
    localparam logic [TTYP_LEN-1:0] UNTRANSLATED_RX     = 6'b00_0_0_01;
    localparam logic [TTYP_LEN-1:0] UNTRANSLATED_R      = 6'b00_0_0_10;
    localparam logic [TTYP_LEN-1:0] UNTRANSLATED_W      = 6'b00_0_0_11;      // Write/AMO
    // Translated (!b3 && b2)
    localparam logic [TTYP_LEN-1:0] TRANSLATED_RX       = 6'b00_0_1_01;
    localparam logic [TTYP_LEN-1:0] TRANSLATED_R        = 6'b00_0_1_10;
    localparam logic [TTYP_LEN-1:0] TRANSLATED_W        = 6'b00_0_1_11;      // Write/AMO
    // PCIe (b3)
    localparam logic [TTYP_LEN-1:0] PCIE_ATS_TRANS_REQ  = 6'b00_1_0_00;
    localparam logic [TTYP_LEN-1:0] PCIE_MSG_REQ        = 6'b00_1_0_01;

    //-----------------------------
    //# Memory-mapped registers structs
    //-----------------------------

    // Capabilities (caps)
    typedef struct packed {
        logic [7:0]     custom;
        logic [14:0]    reserved_3;
        logic           pd20;
        logic           pd17;
        logic           pd8;
        logic [5:0]     pas;
        logic           dbg;
        logic           hpm;
        logic [1:0]     igs;
        logic           endi;
        logic           t2gpa;
        logic           ats;
        logic           amo;
        logic           msi_mrif;
        logic           msi_flat;
        logic [1:0]     reserved_2;
        logic           sv57x4;
        logic           sv48x4;
        logic           sv39x4;
        logic           sv32x4;
        logic           svpbmt;
        logic [2:0]     reserved_1;
        logic           sv57;
        logic           sv48;
        logic           sv39;
        logic           sv32;
        logic [7:0]     version;
    } capabilities_t;

    // Features control (fctl)
    typedef struct packed {
        logic [15:0]    custom;
        logic [12:0]    reserved;
        logic           gxl;
        logic           wsi;
        logic           be;
    } fctl_t;

    // Device Directory Table Pointer (ddtp)
    typedef struct packed {
        logic [9:0]             reserved_2;
        logic [riscv::PPNW-1:0] ppn;
        logic [4:0]             reserved_1;
        logic                   busy;
        logic [3:0]             iommu_mode;
    } ddtp_t;

    //--------------------------
    //#  IOMMU functions
    //--------------------------

    // Extract vIMSIC number from valid GPA
    function logic [(MSI_MASK_LEN-1):0] extract_imsic_num(input logic [(MSI_MASK_LEN-1):0] gpaddr, input logic [(MSI_MASK_LEN-1):0] mask);
        logic [(MSI_MASK_LEN-1):0] masked_gpaddr, imsic_num;
        int unsigned i;

        masked_gpaddr = gpaddr & mask;
        imsic_num = '0;
        i = 0;
        for (int unsigned k = 0 ; k < MSI_MASK_LEN; k++) begin
            if (masked_gpaddr[k]) begin
                imsic_num[i] = 1'b1;
                i++;
            end
        end

        return imsic_num;
    endfunction : extract_imsic_num

endpackage