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
// Author:  Manuel Rodríguez <manuel.cederog@gmail.com>
// Date:    10/11/2022
//
// Description: RISC-V IOMMU SV package.
//

`ifndef RV_IOMMU_PKG
`define RV_IOMMU_PKG

package rv_iommu;

    // Device Context max length
    localparam DEV_ID_MAX_LEN   = 24;
    localparam PROC_ID_MAX_LEN  = 20;

    // to identify memory accesses to virtual guest interrupt files
    localparam MSI_MASK_LEN     = 52;
    localparam MSI_PATTERN_LEN  = 52;

    //--------------------------
    //#  ICVEC values
    //--------------------------
    localparam logic [3:0] icvec_vals [16] = '{
        4'd0,
        4'd1,
        4'd2,
        4'd3,
        4'd4,
        4'd5,
        4'd6,
        4'd7,
        4'd8,
        4'd9,
        4'd10,
        4'd11,
        4'd12,
        4'd13,
        4'd14,
        4'd15
    };

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

    typedef enum logic[1:0] {
      MSI_DISABLED,
      MSI_FLAT_ONLY,
      MSI_FLAT_MRIF
    } msi_trans_t;

    typedef enum logic [1:0] {
        RSV_1           = 2'b00,
        MRIF            = 2'b01,
        RSV_2           = 2'b10,
        FLAT            = 2'b11
    } msi_pte_mode_e;

    // MSI PTE (Write-through mode)
    typedef struct packed {
        logic           c;
        logic [8:0]     __rsv_2;
        logic [44-1:0]  ppn;
        logic [6:0]     __rsv_1;
        msi_pte_mode_e  m;
        logic           v;
    } msi_pte_flat_t;

    // MSI PTE (MRIF mode)
    typedef struct packed {
        logic [2:0]     __rsv_2;
        logic           nid_10;
        logic [5:0]     __rsv_1;
        logic [44-1:0]  nppn;
        logic [9:0]     nid_9_0;
    } msi_pte_notice_t;

    typedef struct packed {
        logic           c;
        logic [8:0]     __rsv_2;
        logic [47-1:0]  addr;
        logic [3:0]     __rsv_1;
        msi_pte_mode_e  m;
        logic           v;
    } msi_pte_mrif_t;

    typedef struct packed {
        logic [10:0]    nid;
        logic [44-1:0]  nppn;
        logic [47-1:0]  addr;
    } mrifc_entry_t;

    //----------------------
    //#  IOMMU Command Queue
    //----------------------

    // Opcodes
    localparam logic [6:0] IOTINVAL = 7'd1;
    localparam logic [6:0] IOFENCE  = 7'd2;
    localparam logic [6:0] IODIR    = 7'd3;
    localparam logic [6:0] ATS      = 7'd4;

    // Func3
    localparam logic [2:0] VMA      = 3'b000;
    localparam logic [2:0] GVMA     = 3'b001;
    
    localparam logic [2:0] DDT      = 3'b000;
    localparam logic [2:0] PDT      = 3'b001;


    // Generic CQ entry (used to check type of command)
    typedef struct packed {
        logic [117:0]   operands;
        logic [2:0]     func3;
        logic [6:0]     opcode;
    } cq_entry_t;

    // IOTLB Invalidation Command
    typedef struct packed {
        logic [1:0]     reserved_4;
        logic [51:0]    addr;           // Actually VPN... Named 'ADDR' to match with Spec document
        logic [13:0]    reserved_3;
        logic [15:0]    gscid;
        logic [9:0]     reserved_2;
        logic           gv;
        logic           pscv;
        logic [19:0]    pscid;
        logic           reserved_1;
        logic           av;
        logic [2:0]     func3;
        logic [6:0]     opcode;
    } cq_iotinval_t;

    // CQ IO Fence command
    typedef struct packed {
        logic [1:0]     reserved_2;
        logic [62:0]    addr;
        logic [31:0]    data;
        logic [17:0]    reserved_1;
        logic           pw;
        logic           pr;
        logic           wsi;
        logic           av;
        logic [2:0]     func3;
        logic [6:0]     opcode;
    } cq_iofence_t;

    // Context Directory Cache Invalidation Commands
    typedef struct packed {
        logic [63:0]    reserved_4;
        logic [23:0]    did;
        logic [5:0]     reserved_3;
        logic           dv;
        logic           reserved_2;
        logic [19:0]    pid;
        logic [1:0]     reserved_1;
        logic [2:0]     func3;
        logic [6:0]     opcode;
    } cq_iodirinval_t;

    //----------------------------
    //#  IOMMU Fault Queue Structs
    //----------------------------

    typedef struct packed {
        logic [63:0]    iotval2;
        logic [63:0]    iotval;
        logic [31:0]    reserved;
        logic [31:0]    custom;
        logic [23:0]    did;
        logic [5:0]     ttyp;
        logic           priv;
        logic           pv;
        logic [19:0]    pid;
        logic [11:0]    cause;
    } fq_record_t;

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

    // Extended IOMMU fault cases
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
    localparam logic [CAUSE_LEN-1:0] DDT_DATA_CORRUPTION                = 268;
    localparam logic [CAUSE_LEN-1:0] PDT_DATA_CORRUPTION                = 269;
    localparam logic [CAUSE_LEN-1:0] MSI_PT_DATA_CORRUPTION             = 270;
    localparam logic [CAUSE_LEN-1:0] MSI_MRIF_DATA_CORRUPTION           = 271;
    localparam logic [CAUSE_LEN-1:0] INTERN_DATAPATH_FAULT              = 272;
    localparam logic [CAUSE_LEN-1:0] MSI_ST_ACCESS_FAULT                = 273;
    localparam logic [CAUSE_LEN-1:0] PT_DATA_CORRUPTION                 = 274;

    //---------------------------
    //# Transaction type encoding
    //---------------------------
    
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
    //#  HPM Event IDs
    //--------------------------
    typedef enum logic[14:0] {
      NOT_COUNT,
      UT_REQ,
      T_REQ,
      ATS_REQ,
      IOTLB_MISS,
      DDTW,
      PDTW,
      S1_PTW,
      S2_PTW
      // rsv [1 , 16383]
      // custom [16384 , 32767]
    } eventid_t;

    //--------------------------
    //#  Interrupt Generation Support format
    //--------------------------
    typedef enum logic[1:0] {
      MSI_ONLY,
      WSI_ONLY,
      BOTH
    } igs_t;

    //--------------------------
    //#  IOMMU functions
    //--------------------------

    // Checks if final translation page size is 1G when H-extension is enabled
    // Adapted from MMU function in ariane_pkg
    function automatic logic is_trans_1G(input logic S1_en, input logic S2_en,
                                        input logic is_1S_1G, input logic is_2S_1G);
        return (((is_1S_1G && S1_en) || !S1_en) && ((is_2S_1G && S2_en) || !S2_en));
    endfunction : is_trans_1G

    // Checks if final translation page size is 2M when H-extension is enabled
    // Adapted from MMU function in ariane_pkg
    function automatic logic is_trans_2M(input logic S1_en, input logic S2_en,
                                        input logic is_1S_1G, input logic is_1S_2M,
                                        input logic is_2S_1G, input logic is_2S_2M);
        return  (S1_en && S2_en) ? 
                    ((is_1S_2M && (is_2S_1G || is_2S_2M)) || (is_2S_2M && (is_1S_1G || is_1S_2M))) :
                    ((is_1S_2M && S1_en) || (is_2S_2M && S2_en));
    endfunction : is_trans_2M

    // Computes the paddr based on the page size, ppn and offset
    // Adapted from MMU function in ariane_pkg
    function automatic logic [(riscv::GPLEN-1):0] make_gpaddr(
        input logic S1_en, input logic is_1G, input logic is_2M,
        input logic [(riscv::VLEN-1):0] vaddr, input riscv::pte_t pte);
        logic [(riscv::GPLEN-1):0] gpaddr;
        if (S1_en) begin
        gpaddr = {pte.ppn[(riscv::GPPNW-1):0], vaddr[11:0]};
        // Giga page
        if (is_1G) gpaddr[29:12] = vaddr[29:12];
        // Mega page
        if (is_2M) gpaddr[20:12] = vaddr[20:12];
        end else begin
        gpaddr = vaddr[(riscv::GPLEN-1):0];
        end
        return gpaddr;
    endfunction : make_gpaddr

    // Computes the final gppn based on the guest physical address
    // Adapted from MMU function in ariane_pkg
    function automatic logic [(riscv::GPPNW-1):0] make_gppn(input logic S1_en, input logic is_1G,
                                                            input logic is_2M, input logic [28:0] vpn,
                                                            input riscv::pte_t pte);
        logic [(riscv::GPPNW-1):0] gppn;
        if (S1_en) begin
        gppn = pte.ppn[(riscv::GPPNW-1):0];
        if (is_2M) gppn[8:0] = vpn[8:0];
        if (is_1G) gppn[17:0] = vpn[17:0];
        end else begin
        gppn = vpn;
        end
        return gppn;
    endfunction : make_gppn

    // Extract Interrupt File number from GPA
    // The resulting IF number is used to index the corresponding MSI PTE in memory.
    function automatic logic [(riscv::GPPNW-1):0] extract_imsic_num(input logic [(riscv::GPPNW-1):0] gpaddr, input logic [(MSI_MASK_LEN-1):0] mask);
        logic [(riscv::GPPNW-1):0] masked_gpaddr, imsic_num;
        int unsigned i;

        masked_gpaddr = gpaddr & mask[(riscv::GPPNW-1):0];
        imsic_num = '0;
        i = 0;
        for (int unsigned k = 0 ; k < riscv::GPPNW; k++) begin
            if (mask[k]) begin
                imsic_num[i] = masked_gpaddr[k];
                i++;
            end
        end

        return imsic_num;
    endfunction : extract_imsic_num

endpackage

`endif  /* RISCV_IOMMU_PKG */