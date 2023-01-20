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

    //------------------------
    //#  Device Context Fields
    //------------------------

    // to identify memory accesses to virtual guest interrupt files
    localparam MSI_MASK_LEN     = 52;
    localparam MSI_PATTERN_LEN  = 52;

    // MSI Address Pattern
    typedef struct packed {
        logic [11:0] reserved;
        logic [(MSI_PATTERN_LEN-1):0] pattern;
    } msi_addr_pattern_t;

    // MSI Address Mask
    typedef struct packed {
        logic [11:0] reserved;
        logic [(MSI_MASK_LEN-1):0] mask;
    } msi_addr_mask_t;

    // MSI Page Table Pointer
    typedef struct packed {
        logic [3:0] mode;
        logic [15:0] reserved;
        logic [43:0] ppn;
    } msiptp_t;

    // First Stage Context
    typedef struct packed {
        logic [3:0] mode;
        logic [15:0] reserved;
        logic [43:0] ppn;
    } fsc_t;

    // Translation Attributes for Device Context
    typedef struct packed {
        logic [31:0] reserved_1;
        logic [19:0] pscid;
        logic [11:0] reserved_2;
    } dc_ta_t;

    // Translation Attributes for Process Context
    typedef struct packed {
        logic [31:0] reserved_1;
        logic [19:0] pscid;
        logic [8:0] reserved_2;
        logic sum;
        logic ens;
        logic v;
    } pc_ta_t;

    // IO Hypervisor Guest Address Translation and Protection
    typedef struct packed {
        logic [3:0] mode;
        logic [15:0] gscid;
        logic [43:0] ppn;
    } iohgatp_t;

    // Translation Control
   typedef struct packed {
        logic [31:0] custom;
        logic [19:0] reserved;
        logic sxl;
        logic sbe;
        logic dpe;
        logic sade;
        logic gade;
        logic prpr;
        logic pdtv;
        logic dtf;
        logic t2gpa;
        logic en_pri;
        logic en_ats;
        logic v;
   } tc_t;

    //--------------------------
    //#  Device Context Structs
    //--------------------------

    // Base format Device Context
    typedef struct packed {
        fsc_t fsc;
        dc_ta_t ta;
        iohgatp_t iohgatp;
        tc_t tc;
    } dc_base_t;
    
    // Extended format Device Context
    typedef struct packed {
        logic [63:0] rsvd;
        msi_addr_pattern_t msi_addr_pattern;
        msi_addr_mask_t msi_addr_mask;
        msiptp_t msiptp;
        fsc_t fsc;
        dc_ta_t ta;
        iohgatp_t iohgatp;
        tc_t tc;
    } dc_ext_t;

    //--------------------------
    //#  Process Context Struct
    //--------------------------

    // Process Context
    typedef struct packed {
        fsc_t fsc;
        pc_ta_t ta;
    } pc_t;

    //--------------------------
    //#  MSI Address Translation
    //--------------------------

    // MSI PTE (Write-through mode)
    typedef struct packed {
        logic           c;
        logic [8:0]     reserved_2;
        logic [44-1:0]  ppn;
        logic [6:0]     reserved_1;
        logic [1:0]     m;
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
        logic [1:0]     m;
        logic           v;
    } msi_mrif_pte_t;

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