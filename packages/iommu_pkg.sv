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
    //  Device Context Fields
    //------------------------

    // MSI Address Pattern
    typedef struct packed {
        logic [11:0] reserved;
        logic [51:0] pattern;
    } msi_addr_pattern_t;

    // MSI Address Mask
    typedef struct packed {
        logic [11:0] reserved;
        logic [51:0] mask;
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

    // Translation Attributes
    typedef struct packed {
        logic [31:0] reserved_1;
        logic [19:0] pscid;
        logic [11:0] reserved_2;
    } ta_t;

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
    //  Device Context Structs
    //--------------------------

    // Base format Device Context
    typedef struct packed {
        fsc_t fsc;
        ta_t ta;
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
        ta_t ta;
        iohgatp_t iohgatp;
        tc_t tc;
    } dc_ext_t;

endpackage