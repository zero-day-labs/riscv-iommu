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
// Date: 06/02/2023
//
// Description: RISC-V IOMMU Translation Logic Wrapper.
//              Encompasses all modules involved in the address translation 
//              process and report of translation faults.
//              Process Context support: YES
//              MSI Translation support: YES

//! NOTES:
/*
    - For now, req_trans_i must be hold high for the entire translation process (whenever walks are needed). If it is cleared, 
      IOTLB hit signal is also cleared even if it has a valid translation. Further on, input signals may be propagated to achieve 
      a stronger implementation (+ HW cost).
*/

// TODO: Including MSI translation separately with MRIF support
/*
    -   If MRIF support is enabled, the MRIFC must be looked up simultaneously with the IOTLB. Assuming that 
        there is no possibility to have two MSI entries configured in different modes (FLAT/MRIF) with the same 
        tags cached at the same time, it is not possible to have hits in both IOTLB and MRIFC.
    
    -   Thus, IOTLB and MRIFC are looked up simultaneously. The MRIFC holds the first-stage mappings that translate 
        GVAs to an MSI GPA. This simplifies some operations such as lookups when two-stage translation is supported and 
        the invalidation of first-stage entries that map to MSI GPAs.

    -   A hit in the IOTLB may represent a normal translation or an MSI translation in FLAT mode. 
        The IOTLB entry also contains the first-stage PTE for MSI entries with first-stage enabled.
        After the hit, the physical address is built the same way as a normal translation.

    -   A hit in the MRIFC represents an MSI translation with the MSI PTE in MRIF mode. If the VM associated 
        with the MSI PT uses first-stage translation, the first-stage PTE is also stored in this cache.
        After the hit, we must somehow resume the AXI transaction to get the MSI data and init the MRIF handler.

    -   A miss in both caches can result in one of two behaviors:
        
        (1) If first-stage translation is enabled, we can't know yet whether the GVA maps to an MSI address.
            Thus, we do not check the address, and we simply trigger the PTW to perform two-stage translation.
            If the GVA maps to an MSI GPA, the PTW sends all first-stage data to the MSI PTW and triggers the 
            MSI PTW to perform MSI translation. The MSI PTW updates the IOTLB or the MRIFC with first-stage and
            MSI data, depending on whether the MSI PTE is in MSI or MRIF mode.
            
        (2) If first-stage translation is disabled, we can imediately check whether the GPA is an MSI address.
            If it is, we trigger the MSI PTW directly. The normal PTW remains unused.
            If the GPA is not an MSI address, we trigger the PTW to perform normal translation.
            Note that, if both translation stages are in Bare mode, and the address is not MSI, there is no
            need to lookup any cache.
*/

module rv_iommu_tw_sv39x4_pc #(

    parameter int unsigned  IOTLB_ENTRIES       = 4,
    parameter int unsigned  DDTC_ENTRIES        = 4,
    parameter int unsigned  PDTC_ENTRIES        = 4,

    // MSI translation support
    parameter rv_iommu::msi_trans_t MSITrans    = rv_iommu::MSI_DISABLED,

    /// AXI Full request struct type
    parameter type  axi_req_t       = logic,
    /// AXI Full response struct type
    parameter type  axi_rsp_t       = logic,

    // DC type (DO NOT OVERWRITE)
    parameter type dc_t = (MSITrans == rv_iommu::MSI_DISABLED) ? (rv_iommu::dc_base_t) : (rv_iommu::dc_ext_t)
) (
    input  logic    clk_i,
    input  logic    rst_ni,

    // Trigger translation
    input  logic    req_trans_i,

    // Translation request data
    input  logic [23:0]                     did_i,      // device_id associated with the transaction
    input  logic                            pv_i,       // a valid process_id is associated with the request
    input  logic [19:0]                     pid_i,      // process_id associated with the transaction
    input  logic [riscv::VLEN-1:0]          iova_i,     // IOVA
    output logic [15:0]                     gscid_o,    // GSCID
    output logic [19:0]                     pscid_o,    // PSCID
    
    input  logic [rv_iommu::TTYP_LEN-1:0]   trans_type_i,   // transaction type
    input  logic                            priv_lvl_i,     // privilege mode associated with the transaction
    input  logic                            is_32_bit_i,    // Data size is 32 bit

    // AXI ports directed to Data Structures Interface
    // CDW
    input  axi_rsp_t    cdw_axi_resp_i,
    output axi_req_t    cdw_axi_req_o,
    // PTW
    input  axi_rsp_t    ptw_axi_resp_i,
    output axi_req_t    ptw_axi_req_o,
    // MSI PTW
    input  axi_rsp_t    msiptw_axi_resp_i,
    output axi_req_t    msiptw_axi_req_o,
    // MRIF handler
    input  axi_rsp_t    mrif_handler_axi_resp_i,
    output axi_req_t    mrif_handler_axi_req_o,

    // From Regmap
    input  rv_iommu_reg_pkg::iommu_reg2hw_capabilities_reg_t   capabilities_i,
    input  rv_iommu_reg_pkg::iommu_reg2hw_fctl_reg_t           fctl_i,
    input  rv_iommu_reg_pkg::iommu_reg2hw_ddtp_reg_t           ddtp_i,

    // Request status and output data
    output logic                        trans_valid_o,      // Translation completed
    output logic [riscv::PLEN-1:0]      spaddr_o,           // Translated address
    // Error
    output logic                                trans_error_o,      // Translation error
    output logic                                report_fault_o,     // The fault must be reported through the FQ
    output logic [(rv_iommu::CAUSE_LEN-1):0]    cause_code_o,       // Fault code defined by translation logic
    output logic                                is_guest_pf_o,      // a guest page fault occurred in the PTW
    output logic                                is_implicit_o,      // Guest page fault caused by implicit access for 1st-stage addr translation
    output logic [riscv::SVX-1:0]               bad_gpaddr_o,       // to report bits [63:2] of the GPA in case of a Guest Page Fault
    input  logic                                msi_write_error_i,  // An error occurred when writing an MSI generated by the IOMMU

    // to HPM
    output logic                        iotlb_miss_o,       // IOTLB miss happened
    output logic                        ddt_walk_o,         // DDT walk triggered
    output logic                        pdt_walk_o,         // PDT walk triggered
    output logic                        s1_ptw_o,           // first-stage PT walk triggered
    output logic                        s2_ptw_o,           // second-stage PT walk triggered

    // IOATC Invalidation control (from CQ Handler to IOATC)
    // DDTC Invalidation
    input  logic                        flush_ddtc_i,   // Flush DDTC
    input  logic                        flush_dv_i,     // Indicates if device_id is valid
    input  logic [23:0]                 flush_did_i,    // device_id to tag entries to be flushed
    // PDTC Invalidation
    input  logic                        flush_pdtc_i,   // Flush PDTC
    input  logic                        flush_pv_i,     // This is used to difference between IODIR.INVAL_DDT and IODIR.INVAL_PDT
    input  logic [19:0]                 flush_pid_i,    // process_id to be flushed if PV = 1
    // IOTLB Invalidation
    input  logic                        flush_vma_i,    // Flush first-stage PTEs cached entries in IOTLB
    input  logic                        flush_gvma_i,   // Flush second-stage PTEs cached entries in IOTLB 
    input  logic                        flush_av_i,     // Address valid
    input  logic                        flush_gv_i,     // GSCID valid
    input  logic                        flush_pscv_i,   // PSCID valid
    input  logic [riscv::GPPNW-1:0]     flush_vpn_i,    // IOVA to tag entries to be flushed
    input  logic [15:0]                 flush_gscid_i,  // GSCID (Guest physical address space identifier) to tag entries to be flushed
    input  logic [19:0]                 flush_pscid_i   // PSCID (Guest virtual address space identifier) to tag entries to be flushed

    output logic        ignore_request_o,   // Ignore request (MRIF only)
    input  logic        msi_data_valid_i,   // MSI data sent by DMA available
    input  logic [31:0] msi_data_i          // MSI data
);

    // Address translation parameters
    logic en_1S, en_2S;
    logic [15:0] gscid;
    logic [19:0] pscid;
    logic [riscv::PPNW-1:0] iohgatp_ppn, iosatp_ppn;

    // PTW implicit translations for CDW walks
    logic                           cdw_implicit_access;
    logic [riscv::GPPNW-1:0]        pdt_gppn;
    logic                           cdw_done;
    logic                           flush_cdw;
    logic [riscv::PPNW-1:0]         iohgatp_ppn_fw;
    logic                           is_ddt_walk;

    // If DC.tc.DPE is 1 and no valid process_id is given by the device, default value of zero is used
    logic [19:0] process_id;
    assign process_id = (!pv_i && ddtc_lu_content.tc.dpe) ? '0 : pid_i;

    // To check whether first and second-stage translation modes are Bare
    logic first_stage_is_bare, second_stage_is_bare;
    assign first_stage_is_bare  =   ((ddtc_lu_content.tc.pdtv && pdtc_lu_content.fsc.mode == 4'b0000) ||
                                    (!ddtc_lu_content.tc.pdtv && ddtc_lu_content.fsc.mode == 4'b0000));
    assign second_stage_is_bare =   (ddtc_lu_content.iohgatp.mode == 4'b0000);

    // To check whether process_id is wider than supported
    logic pid_wider_than_supported;
    assign pid_wider_than_supported = ((ddtc_lu_content.fsc.mode == 4'b0001 && |process_id[19:8]) ||
                                       (ddtc_lu_content.fsc.mode == 4'b0010 && |process_id[19:17]));

    // To determine if current DC enables MSI translation
    logic msi_enabled;
    assign msi_enabled = (ddtc_lu_content.msiptp.mode != 4'b0000);

    // To determine if request is translated or untranslated
    logic is_translated;
    assign is_translated = (!trans_type_i[3] && trans_type_i[2]);

    // To determine if request is a PCIe ATS TR
    logic is_pcie_tr_req;
    assign is_pcie_tr_req = (trans_type_i == rv_iommu::PCIE_ATS_TRANS_REQ);

    // To determine if transaction is a store
    logic is_store;
    assign is_store = ((&trans_type_i[1:0] == 1'b1) && (!trans_type_i[3]));

    // To determine if transaction is read-for-execute
    logic is_rx;
    assign is_rx = (!trans_type_i[3] && !trans_type_i[1] && trans_type_i[0]);

    // Efective iohgatp.ppn field to introduce in the PTW. May need to be forwarded by the CDW
    logic [riscv::PPNW-1:0] ptw_iohgatp_ppn;
    assign ptw_iohgatp_ppn = (is_ddt_walk & cdw_implicit_access) ? iohgatp_ppn_fw : iohgatp_ppn;

    // To select en_1S and en_2S source for PTW implicit second-stage translations in CDW Walks
    logic   ptw_en_1S, ptw_en_2S;
    assign  ptw_en_1S = (cdw_implicit_access) ? 1'b0 : en_1S;
    assign  ptw_en_2S = (cdw_implicit_access) ? 1'b1 : en_2S;

    // Set for faults occurred before DDTC lookup
    logic   report_always;

    // Translation error signaling according to the spec
    logic   wrap_error;
    logic [(rv_iommu::CAUSE_LEN-1):0]  wrap_cause_code;  // Fault code as defined by IOMMU and Priv Spec
    // CDW error
    logic cdw_error;
    logic [(rv_iommu::CAUSE_LEN-1):0]  cdw_cause_code;
    // PTW error
    logic ptw_error;
    logic [(rv_iommu::CAUSE_LEN-1):0]  ptw_cause_code;
    // CDW error
    logic msiptw_error;
    logic [(rv_iommu::CAUSE_LEN-1):0]  msiptw_cause_code;
    // PTW error
    logic mrif_handler_error;
    logic [(rv_iommu::CAUSE_LEN-1):0]  mrif_handler_cause_code;

    // To indicate whether the occurring fault has to be reported according to DC.tc.DTF and the fault source
    // If DC.tc.DTF=1, only faults occurred before finding the corresponding DC should be reported
    assign  report_fault_o    = (((ddtc_lu_hit & !ddtc_lu_content.tc.dtf) | 
                                  (report_always | msi_write_error_i | (cdw_error & is_ddt_walk))) & wrap_error);
                                  
    // Guest page fault occurred during implicit 2nd-stage translation for 1st-stage translation
    logic   ptw_error_2S_int;
    assign  is_implicit_o = (ptw_error_2S_int | (flush_cdw & ~is_ddt_walk));

    // HPM event indicators
    logic cdw_active, ptw_active;
    assign iotlb_miss_o = iotlb_access & (~iotlb_lu_hit);
    assign ddt_walk_o   = cdw_active & (is_ddt_walk);
    assign pdt_walk_o   = cdw_active & (~is_ddt_walk);
    assign s1_ptw_o     = ptw_active & (ptw_en_1S);
    assign s2_ptw_o     = ptw_active & (ptw_en_2S);
    assign gscid_o      = gscid;
    assign pscid_o      = pscid;

    // IOATC wires
    // DDTC
    logic                       ddtc_access;
    dc_t                        ddtc_lu_content;
    logic                       ddtc_lu_hit;

    logic                       ddtc_update;
    logic [23:0]                ddtc_up_did;
    dc_t                        ddtc_up_content;

    // PDTC
    logic                       pdtc_access;
    rv_iommu::pc_t              pdtc_lu_content;
    logic                       pdtc_lu_hit;

    logic                       pdtc_update;
    logic [19:0]                pdtc_up_pid;
    rv_iommu::pc_t              pdtc_up_content;

    // IOTLB
    logic                       iotlb_access;
    riscv::pte_t                iotlb_lu_1S_content;
    riscv::pte_t                iotlb_lu_2S_content;
    logic                       iotlb_lu_1S_2M;
    logic                       iotlb_lu_1S_1G;
    logic                       iotlb_lu_2S_2M;
    logic                       iotlb_lu_2S_1G;
    logic                       iotlb_lu_hit;

    logic                       iotlb_update;
    logic                       iotlb_up_1S_2M;
    logic                       iotlb_up_1S_1G;
    logic                       iotlb_up_2S_2M;
    logic                       iotlb_up_2S_1G;
    logic [riscv::GPPNW-1:0]    iotlb_up_vpn;
    logic [19:0]                iotlb_up_pscid;
    logic [15:0]                iotlb_up_gscid;
    riscv::pte_t                iotlb_up_1S_content;
    riscv::pte_t                iotlb_up_2S_content;

    // Update bus from PTW to IOTLB
    logic                       ptw_update;
    logic                       ptw_up_1S_2M;
    logic                       ptw_up_1S_1G;
    logic                       ptw_up_2S_2M;
    logic                       ptw_up_2S_1G;
    logic [riscv::GPPNW-1:0]    ptw_up_vpn;
    logic [19:0]                ptw_up_pscid;
    logic [15:0]                ptw_up_gscid;
    riscv::pte_t                ptw_up_1S_content;
    riscv::pte_t                ptw_up_2S_content;

    // Update bus from MSI PTW to IOTLB
    logic                       msi_update;
    logic                       mrifc_update;
    logic                       msi_up_1S_2M;
    logic                       msi_up_1S_1G;
    logic [riscv::GPPNW-1:0]    msi_up_vpn;
    logic [19:0]                msi_up_pscid;
    logic [15:0]                msi_up_gscid;
    riscv::pte_t                msi_up_1S_content;
    rv_iommu::msi_pte_flat_t    msi_up_content;
    rv_iommu::mrifc_entry_t     mrifc_up_msi_content;

    // MRIFC
    logic                       mrifc_lu_hit;
    riscv::pte_t                mrifc_lu_1S_content;
    rv_iommu::mrifc_entry_t     mrifc_lu_msi_content;

    // The IOTLB can be updated from the PTW or from the MSI PTW
    assign iotlb_update         = ptw_update | msi_update;
    assign iotlb_up_1S_2M       = (msi_update) ? (msi_up_1S_2M      )            : (ptw_up_1S_2M       );
    assign iotlb_up_1S_1G       = (msi_update) ? (msi_up_1S_1G      )            : (ptw_up_1S_1G       );
    assign iotlb_up_2S_2M       = (msi_update) ? (1'b0              )            : (ptw_up_2S_2M       );
    assign iotlb_up_2S_1G       = (msi_update) ? (1'b0              )            : (ptw_up_2S_1G       );
    assign iotlb_up_vpn         = (msi_update) ? (msi_up_vpn        )            : (ptw_up_vpn         );
    assign iotlb_up_pscid       = (msi_update) ? (msi_up_pscid      )            : (ptw_up_pscid       );
    assign iotlb_up_gscid       = (msi_update) ? (msi_up_gscid      )            : (ptw_up_gscid       );
    assign iotlb_up_1S_content  = (msi_update) ? (msi_up_1S_content )            : (ptw_up_1S_content  );
    assign iotlb_up_2S_content  = (msi_update) ? (riscv::pte_t'(msi_up_content)) : (ptw_up_2S_content  );

    // first-stage data bus between PTW and MSI PTW
    logic                       gpaddr_is_msi;
    logic [riscv::GPPNW-1:0]    msi_vpn;
    logic [19:0]                msi_pscid;
    logic [15:0]                msi_gscid;
    logic                       msi_1S_2M;
    logic                       msi_1S_1G;
    riscv::pte_t                msi_gpte;

    // MSI address check
    // Input IOVA (GPA) is the address of a virtual IF
    logic   iova_is_msi;
    assign  iova_is_msi = (!en_1S_i && msi_en_i && is_store_i && is_32_bit_i &&
                            ((iova_i[(riscv::GPLEN-1):12] & ~msi_addr_mask_i) == (msi_addr_pattern_i & ~msi_addr_mask_i)));

    // Init PTW
    // Triggered when a hit occurs in the IOTLB and:
    // (i)  first-stage translation is enabled or 
    // (ii) second-stage translation is enabled and the GPA is not MSI
    logic   init_ptw;
    assign  init_ptw = iotlb_access & ~iotlb_lu_hit & (en_1S_i | (en_2S_i & ~iova_is_msi));

    // Init MSI translation
    // Triggered when:
    // (i)  The PTW translates a GVA that maps to an MSI GPA
    // (ii) A miss occurs in both IOTLB and MRIFC, first-stage translation is disabled and the GPA is MSI
    logic   init_msi_trans;
    assign  init_msi_trans = gpaddr_is_msi | (iova_is_msi & iotlb_access & ~(iotlb_lu_hit | mrifc_lu_hit));

    // Bare translation: Both stages are Bare and the address is not an MSI address
    logic   bare_translation;
    assign  bare_translation = first_stage_is_bare & second_stage_is_bare & ~iova_is_msi;

    // Resume and ignore the current translation (used for MRIF processing)
    logic   msiptw_ignore, mrif_handler_ignore;
    assign  ignore_request_o = (msiptw_ignore | mrif_handler_ignore);

    //# Device Directory Table Cache
    rv_iommu_ddtc #(
        .DDTC_ENTRIES       (DDTC_ENTRIES),
        .dc_t               (dc_t        )
    ) i_rv_iommu_ddtc (
        .clk_i              (clk_i          ),  // Clock
        .rst_ni             (rst_ni         ),  // Asynchronous reset active low

        .flush_i            (flush_ddtc_i   ),  // IODIR.INVAL_DDT
        .flush_dv_i         (flush_dv_i     ),  // device_id valid
        .flush_did_i        (flush_did_i    ),  // device_id to be flushed

        // Update signals
        .update_i           (ddtc_update    ),  // update flag
        .up_did_i           (ddtc_up_did    ),  // device ID to be updated
        .up_content_i       (ddtc_up_content),  // DC to be inserted

        // Lookup signals
        .lookup_i           (ddtc_access    ),  // lookup flag
        .lu_did_i           (did_i          ),  // device_id to look for 
        .lu_content_o       (ddtc_lu_content),  // DC found in DDTC
        .lu_hit_o           (ddtc_lu_hit    )   // hit flag
    );
    
    //# Process Directory Table Cache
    rv_iommu_pdtc #(
        .PDTC_ENTRIES       (PDTC_ENTRIES)
    ) i_rv_iommu_pdtc (
        .clk_i              (clk_i          ),  // Clock
        .rst_ni             (rst_ni         ),  // Asynchronous reset active low

        // Flush signals
        .flush_i            (flush_pdtc_i   ),  // IODIR.INVAL_DDT or IODIR.INVAL_PDT
        .flush_dv_i         (flush_dv_i     ),  // flush everything or only entries associated to DID (IODIR.INVAL_DDT)
        .flush_pv_i         (flush_pv_i     ),  // flush entries tagged with DID and PID only (IODIR.INVAL_PDT)
        .flush_did_i        (flush_did_i    ),  // device_id to be flushed
        .flush_pid_i        (flush_pid_i    ),  // process_id to be flushed (if flush_pv_i = 1)

        // Update signals
        .update_i           (pdtc_update    ),  // update flag
        .up_did_i           (ddtc_up_did    ),  // device ID to be inserted
        .up_pid_i           (pdtc_up_pid    ),  // process ID to be inserted
        .up_content_i       (pdtc_up_content),  // PC to be inserted

        // Lookup signals
        .lookup_i           (pdtc_access    ),  // lookup flag
        .lu_did_i           (did_i          ),  // device_id to tag PDTC
        .lu_pid_i           (process_id     ),  // process_id to tag PDTC
        .lu_content_o       (pdtc_lu_content),  // PC found in PDTC
        .lu_hit_o           (pdtc_lu_hit    )   // hit flag
    );


    //# IOTLB: Address Translation Cache
    rv_iommu_iotlb_sv39x4 #(
        .IOTLB_ENTRIES      (IOTLB_ENTRIES)
    ) i_rv_iommu_iotlb_sv39x4 (
        .clk_i              (clk_i      ),  // Clock
        .rst_ni             (rst_ni     ),  // Asynchronous reset active low

        // Flush signals
        .flush_vma_i        (flush_vma_i        ),  // IOTINVAL.VMA
        .flush_gvma_i       (flush_gvma_i       ),  // IOTINVAL.GVMA
        .flush_av_i         (flush_av_i         ),  // ADDR valid
        .flush_gv_i         (flush_gv_i         ),  // GSCID valid
        .flush_pscv_i       (flush_pscv_i       ),  // PSCID valid
        .flush_vpn_i        (flush_vpn_i        ),  // VPN to be flushed
        .flush_gscid_i      (flush_gscid_i      ),  // GSCID identifier to be flushed (VM identifier)
        .flush_pscid_i      (flush_pscid_i      ),  // PSCID identifier to be flushed (address space identifier)

        // Update signals
        .update_i           (iotlb_update       ),
        .up_1S_2M_i         (iotlb_up_1S_2M     ),
        .up_1S_1G_i         (iotlb_up_1S_1G     ),
        .up_2S_2M_i         (iotlb_up_2S_2M     ),
        .up_2S_1G_i         (iotlb_up_2S_1G     ),
        .up_vpn_i           (iotlb_up_vpn       ),
        .up_pscid_i         (iotlb_up_pscid     ),
        .up_gscid_i         (iotlb_up_gscid     ),
        .up_1S_content_i    (iotlb_up_1S_content),
        .up_2S_content_i    (iotlb_up_2S_content),

        // Lookup signals
        .lookup_i           (iotlb_access       ),  // lookup flag
        .lu_iova_i          (iova_i             ),  // IOVA to look for 
        .lu_pscid_i         (pscid              ),  // PSCID to look for
        .lu_gscid_i         (gscid              ),  // GSCID to look for
        .lu_1S_content_o    (iotlb_lu_1S_content),  // first-stage PTE (GPA PPN)
        .lu_2S_content_o    (iotlb_lu_2S_content),  // second-stage PTE (SPA PPN)
        .lu_1S_2M_o         (iotlb_lu_1S_2M     ),
        .lu_1S_1G_o         (iotlb_lu_1S_1G     ),
        .lu_2S_2M_o         (iotlb_lu_2S_2M     ),
        .lu_2S_1G_o         (iotlb_lu_2S_1G     ),
        .en_1S_i            (en_1S              ),  // first-stage enabled
        .en_2S_i            (en_2S              ),  // second-stage enabled
        .lu_hit_o           (iotlb_lu_hit       )   // hit flag
    );

    //# Page Table Walker
    rv_iommu_ptw_sv39x4_pc #(
        .axi_req_t          (axi_req_t ),
        .axi_rsp_t          (axi_rsp_t ),
        .MSITrans           (MSITrans  )
    ) i_rv_iommu_ptw_sv39x4_pc (
        .clk_i                  (clk_i              ),  // Clock
        .rst_ni                 (rst_ni             ),  // Asynchronous reset active low
        
        // Trigger PTW
        .init_ptw_i             (init_ptw           ),  // Trigger PTW

        // Error signaling
        .ptw_active_o           (ptw_active         ),  // Set when PTW is walking memory
        .ptw_error_o            (ptw_error          ),  // set when an error occurred (excluding access errors)
        .ptw_error_2S_o         (is_guest_pf_o      ),  // set when the fault occurred in stage 2
        .ptw_error_2S_int_o     (ptw_error_2S_int   ),  // set when fault occurred during an implicit access for 1st-stage translation
        .cause_code_o           (ptw_cause_code     ),

        .en_1S_i                (ptw_en_1S          ),  // Enable signal for stage 1 translation. Defined by DC/PC
        .en_2S_i                (ptw_en_2S          ),  // Enable signal for stage 2 translation. Defined by DC only
        .is_store_i             (is_store           ),  // Indicate whether this translation was triggered by a store or a load
        .is_rx_i                (is_rx              ),  // Read-for-execute
        .is_32_bit_i            (is_32_bit          ),  // Data is 32-bit wide

        // PTW AXI Master memory interface
        .mem_resp_i             (ptw_axi_resp_i     ),  // Response port from memory
        .mem_req_o              (ptw_axi_req_o      ),  // Request port to memory

        // to IOTLB, update logic
        .update_o               (ptw_update         ),
        .up_1S_2M_o             (ptw_up_1S_2M       ),
        .up_1S_1G_o             (ptw_up_1S_1G       ),
        .up_2S_2M_o             (ptw_up_2S_2M       ),
        .up_2S_1G_o             (ptw_up_2S_1G       ),
        .up_vpn_o               (ptw_up_vpn         ),
        .up_pscid_o             (ptw_up_pscid       ),
        .up_gscid_o             (ptw_up_gscid       ),
        .up_1S_content_o        (ptw_up_1S_content  ),
        .up_2S_content_o        (ptw_up_2S_content  ),

        // IOTLB tags
        .req_iova_i             (iova_i             ),
        .pscid_i                (pscid              ),
        .gscid_i                (gscid              ),

        // MSI translation
        .msi_en_i               (msi_enabled                                ),
        .msi_addr_mask_i        (ddtc_lu_content.msi_addr_mask.mask         ),
        .msi_addr_pattern_i     (ddtc_lu_content.msi_addr_pattern.pattern   ),

        // Bus to send first-stage data to MSI PTW
        .gpaddr_is_msi_o        (gpaddr_is_msi      ),
        .msi_vpn_o              (msi_vpn            ),
        .msi_pscid_o            (msi_pscid          ),
        .msi_gscid_o            (msi_gscid          ),
        .msi_1S_2M_o            (msi_1S_2M          ),
        .msi_1S_1G_o            (msi_1S_1G          ),
        .msi_gpte_o             (msi_gpte           ),

        // CDW implicit translations (Second-stage only)
        .cdw_implicit_access_i  (cdw_implicit_access),
        .pdt_gppn_i             (pdt_gppn           ),
        .cdw_done_o             (cdw_done           ),
        .flush_cdw_o            (flush_cdw          ),

        // from DC/PC
        .iosatp_ppn_i           (iosatp_ppn         ),  // ppn from iosatp
        .iohgatp_ppn_i          (ptw_iohgatp_ppn    ),  // ppn from iohgatp (may be forwarded by the CDW)

        .bad_gpaddr_o           (bad_gpaddr_o       )   // to return the GPA in case of guest page fault
    );

    //# Page Table Walker for MSI Address Translation
    generate
    
    // MSI Translation support enabled
    if (MSITrans != rv_iommu::MSI_DISABLED) begin : gen_msi_support
        rv_iommu_msiptw #(
            .MSITrans           (MSITrans  ),
            .axi_req_t          (axi_req_t ),
            .axi_rsp_t          (axi_rsp_t )
        ) i_rv_iommu_msiptw (
            .clk_i  (clk_i),    // Clock
            .rst_ni (rst_ni),   // Asynchronous reset active low

            // Memory interface
            .mem_resp_i         (msiptw_axi_resp_i  ),
            .mem_req_o          (msiptw_axi_req_o   ),

           // Trigger MSI translation
            .init_msi_trans_i   (init_msi_trans     ),

            // Ignore access (abort without faults)
            .ignore_o           (msiptw_ignore      ),

            .vpn_i              (msi_vpn            ),
            .pscid_i            (msi_pscid          ),
            .gscid_i            (msi_gscid          ),
            .is_1S_2M_i         (msi_1S_2M          ),
            .is_1S_1G_i         (msi_1S_1G          ),
            .gpte_i             (msi_gpte           ),

            // The translation is read-for-execute
            .is_rx_i            (is_rx              ),

            // MSI PT base PPN
            .msiptp_ppn_i       (ddtc_lu_content.msiptp.ppn),

            // MSI address mask
            .msi_addr_mask_i    (ddtc_lu_content.msi_addr_mask.mask),

            // Generic update ports
            .vpn_o              (msi_up_vpn         ),
            .pscid_o            (msi_up_pscid       ),
            .gscid_o            (msi_up_gscid       ),
            .is_1S_2M_o         (msi_up_1S_2M       ),
            .is_1S_1G_o         (msi_up_1S_1G       ),
            .content_1S_o       (msi_up_1S_content  ),            

            // IOTLB update ports
            .iotlb_update_o     (msi_update         ),
            .iotlb_msi_content_o(msi_up_content     ),

            // MRIFC update ports
            .mrifc_update_o     (mrifc_update           ),
            .mrifc_msi_content_o(mrifc_up_msi_content   ),

            // Error signaling
            .error_o            (msiptw_error       ),
            .cause_o            (msiptw_cause_code  )
        );
    end : gen_msi_support

    // MSI translation support disabled
    else begin : gen_msi_support_disabled
        
        // TODO
    end : gen_msi_support_disabled
    endgenerate

    //# MRIF Support for MSI Translation
    generate

    // MRIF Support enabled
    if (MSITrans == rv_iommu::MSI_FLAT_MRIF) begin : gen_mrif_support
        
        // MRIF Handler
        rv_iommu_mrif_handler #(
            .axi_req_t          (axi_req_t ),
            .axi_rsp_t          (axi_rsp_t )
        ) i_rv_iommu_mrif_handler (
            .clk_i  (clk_i),    // Clock
            .rst_ni (rst_ni),   // Asynchronous reset active low

            // Memory interface
            .mem_resp_i     (mrif_handler_axi_resp_i),
            .mem_req_o      (mrif_handler_axi_req_o),

            // Init MRIF processing. MSI data and MRIF cache data are valid.
            .init_mrif_i    (msi_data_valid_i),
            // Abort access (discard without fault)
            .ignore_o       (mrif_handler_ignore),

            // Interrupt identity (MSI data)
            .int_id_i       (msi_data_i),

            // MRIF cache data
            .mrif_addr_i    (mrifc_lu_msi_content.addr),
            .notice_nid_i   (mrifc_lu_msi_content.nid),
            .notice_ppn_i   (mrifc_lu_msi_content.nppn),

            // Error signaling
            .error_o        (mrif_handler_error),
            .cause_o        (mrif_handler_cause_code)
        );

        // MRIF Cache
        rv_iommu_mrifc #(
            .MRIFC_ENTRIES  (MRIFC_ENTRIES)
        ) i_rv_iommu_mrifc (
            .clk_i          (clk_i),    // Clock
            .rst_ni         (rst_ni),   // Asynchronous reset active low

            // Flush signals
            .flush_vma_i        (flush_vma_i            ),  // IOTINVAL.VMA
            .flush_gvma_i       (flush_gvma_i           ),  // IOTINVAL.GVMA
            .flush_av_i         (flush_av_i             ),  // ADDR tag filtering
            .flush_gv_i         (flush_gv_i             ),  // GSCID tag filtering
            .flush_pscv_i       (flush_pscv_i           ),  // PSCID tag filtering
            .flush_vpn_i        (flush_vpn_i            ),  // VPN/GPPN to be flushed
            .flush_gscid_i      (flush_gscid_i          ),  // GSCID to be flushed
            .flush_pscid_i      (flush_pscid_i          ),  // PSCID to be flushed

            // Update signals
            .update_i           (mrifc_update           ),
            .up_1S_2M_i         (msi_up_1S_2M           ),
            .up_1S_1G_i         (msi_up_1S_1G           ),
            .up_vpn_i           (msi_up_vpn             ),
            .up_pscid_i         (msi_up_pscid           ),
            .up_gscid_i         (msi_up_gscid           ),
            .up_1S_content_i    (msi_up_1S_content      ),
            .up_msi_content_i   (mrifc_up_msi_content   ),  // MSI PTE contents

            // Lookup signals
            .lookup_i           (iotlb_access           ),  // lookup flag
            .lu_iova_i          (iova_i                 ),  // IOVA to look for 
            .lu_pscid_i         (pscid                  ),  // PSCID to look for
            .lu_gscid_i         (gscid                  ),  // GSCID to look for
            .en_1S_i            (en_1S                  ),  // first-stage enabled
            .en_2S_i            (en_2S                  ),  // second-stage enabled
            .lu_hit_o           (mrifc_lu_hit           ),  // hit flag
            .lu_1S_content_o    (mrifc_lu_1S_content    ),  // first-stage PTE
            .lu_msi_content_o   (mrifc_lu_msi_content   )   // MSI PTE
        );
    end : gen_mrif_support

    // MRIF Support disabled
    else begin : gen_mrif_support_disabled
        
        // TODO
    end : gen_mrif_support_disabled
    endgenerate

    //# Context Directory Walker
    rv_iommu_cdw_pc #(
        .MSITrans           (MSITrans  ),
        .axi_req_t          (axi_req_t ),
        .axi_rsp_t          (axi_rsp_t )
    ) i_rv_iommu_cdw_ext_pc (
        .clk_i                  (clk_i              ),  // Clock
        .rst_ni                 (rst_ni             ),  // Asynchronous reset active low
        
        // Error signaling
        .cdw_active_o           (cdw_active         ),  // Set when CDW is walking memory
        .cdw_error_o            (cdw_error          ),  // set when an error occurred
        .cause_code_o           (cdw_cause_code     ),  // Fault code as defined by IOMMU and Priv Spec

        // DC config checks
        .caps_ats_i             (capabilities_i.ats.q       ),
        .caps_t2gpa_i           (capabilities_i.t2gpa.q     ),
        .caps_pd20_i            (capabilities_i.pd20.q      ),
        .caps_pd17_i            (capabilities_i.pd17.q      ),
        .caps_pd8_i             (capabilities_i.pd8.q       ),
        .caps_sv32_i            (capabilities_i.sv32.q      ),
        .caps_sv39_i            (capabilities_i.sv39.q      ),
        .caps_sv48_i            (capabilities_i.sv48.q      ), 
        .caps_sv57_i            (capabilities_i.sv57.q      ),
        .fctl_gxl_i             (fctl_i.gxl.q               ),
        .caps_sv32x4_i          (capabilities_i.sv32x4.q    ),
        .caps_sv39x4_i          (capabilities_i.sv39x4.q    ),
        .caps_sv48x4_i          (capabilities_i.sv48x4.q    ),
        .caps_sv57x4_i          (capabilities_i.sv57x4.q    ),
        .caps_msi_flat_i        (capabilities_i.msi_flat.q  ),
        .caps_amo_hwad_i        (capabilities_i.amo_hwad.q  ),
        .caps_end_i             (capabilities_i.endi.q      ),
        .fctl_be_i              (fctl_i.be.q                ),

        // PC checks
        .dc_sxl_i               (ddtc_lu_content.tc.sxl     ),

        // PTW memory interface
        .mem_resp_i             (cdw_axi_resp_i ),      // Response port from memory
        .mem_req_o              (cdw_axi_req_o  ),      // Request port to memory

        // Update logic
        .update_dc_o            (ddtc_update    ),
        .up_did_o               (ddtc_up_did    ),
        .up_dc_content_o        (ddtc_up_content),

        .update_pc_o            (pdtc_update    ),
        .up_pid_o               (pdtc_up_pid    ),
        .up_pc_content_o        (pdtc_up_content),

        // CDCs tags
        .req_did_i              (did_i          ),      // device ID associated with request
        .req_pid_i              (process_id     ),      // process ID associated with request

        // from DDTC / PDTC, to monitor misses
        .ddtc_access_i          (ddtc_access    ),
        .ddtc_hit_i             (ddtc_lu_hit    ),

        .pdtc_access_i          (pdtc_access    ),
        .pdtc_hit_i             (pdtc_lu_hit    ),

        // from regmap
        .ddtp_ppn_i             (ddtp_i.ppn.q       ),  // PPN from ddtp register
        .ddtp_mode_i            (ddtp_i.iommu_mode.q),  // DDT levels and IOMMU mode

        // from DC (for PC walks)
        .en_stage2_i            (en_2S                      ),  // Second-stage translation is enabled
        .pdtp_ppn_i             (ddtc_lu_content.fsc.ppn    ),  // PPN from DC.fsc.PPN
        .pdtp_mode_i            (ddtc_lu_content.fsc.mode   ),  // PDT levels from DC.fsc.MODE

        // CDW implicit translations (Second-stage only)
        .ptw_done_i             (cdw_done               ),
        .flush_i                (flush_cdw              ),
        .pdt_ppn_i              (iotlb_up_2S_content.ppn),
        .cdw_implicit_access_o  (cdw_implicit_access    ),
        .is_ddt_walk_o          (is_ddt_walk            ),
        .pdt_gppn_o             (pdt_gppn               ),
        .iohgatp_ppn_fw_o       (iohgatp_ppn_fw         )  // to forward iohgatp.PPN to PTW when translating pdtp.PPN
    );

    //# Translation logic
    always_comb begin : translation

        ddtc_access         = 1'b0;
        pdtc_access         = 1'b0;
        en_1S               = 1'b0;
        en_2S               = 1'b0;
        gscid               = '0;
        pscid               = '0;
        iosatp_ppn          = '0;
        iohgatp_ppn         = '0;
        iotlb_access        = 1'b0;
        wrap_cause_code     = '0;
        wrap_error          = 1'b0;
        trans_valid_o       = 1'b0;
        spaddr_o            = '0;
        report_always       = 1'b0;

        // A translation is triggered by setting req_trans_i
        if (req_trans_i) begin
    
            //# Input Checks
            // "If ddtp.iommu_mode == Off then stop and report "All inbound transactions disallowed" (cause = 256)."
            if (ddtp_i.iommu_mode.q == 4'b0000) begin
                wrap_cause_code    = rv_iommu::ALL_INB_TRANSACTIONS_DISALLOWED;
                wrap_error   = 1'b1;
                report_always   = 1'b1;
            end

            // "If ddtp.iommu_mode == Bare and any of the following conditions (*) hold then stop and report "Transaction type disallowed" (cause = 260)."
            else if (ddtp_i.iommu_mode.q == 4'b0001) begin
                
                // "(*) If the transaction is a translated request or a PCIe ATS request"
                if (is_translated || is_pcie_tr_req) begin
                    wrap_cause_code    = rv_iommu::TRANS_TYPE_DISALLOWED;
                    wrap_error   = 1'b1;
                    report_always   = 1'b1;
                end

                // " else the translation process is completed with the IOVA as the translated address"
                else begin
                    trans_valid_o   = 1'b1;
                    spaddr_o        = iova_i[riscv::PLEN-1:0];
                end
            end

            // "If the device_id is wider than supported by the IOMMU, then stop and report "Transaction type disallowed" (cause = 260)."
            else if ((ddtp_i.iommu_mode.q == 4'b0011 && (|did_i[23:15])) || (ddtp_i.iommu_mode.q == 4'b0010 && (|did_i[23:6]))) begin
                wrap_cause_code = rv_iommu::TRANS_TYPE_DISALLOWED;
                wrap_error   = 1'b1;
                report_always   = 1'b1;
            end

            // IOMMU is not in bare mode and no errors ocurred. Lookup DDTC
            else ddtc_access = 1'b1;
        end

        //# DDTC Lookup & Hit
        // Access to DDTC and PDTC is automatically triggered when setting req_trans_i if no fault is generated
        // If hit flag is set in the same cycle, we have a DDTC instantaneous hit
        if (ddtc_lu_hit) begin

            // "If any of the following conditions hold then stop and report "Transaction type disallowed" (cause = 260)."
            if (((is_translated || is_pcie_tr_req) && !ddtc_lu_content.tc.en_ats) ||
                (pv_i && !ddtc_lu_content.tc.pdtv) ||
                (pv_i && ddtc_lu_content.tc.pdtv && pid_wider_than_supported)) begin

                wrap_cause_code  = rv_iommu::TRANS_TYPE_DISALLOWED;
                wrap_error = 1'b1;
            end

            // avoid triggering a CDW walk for a PC or a PTW walk when the previous fault occurs 
            else begin

                // Translated request
                if (is_translated) begin

                    // When DC.tc.T2GPA = 0, translated requests are performed using an SPA. Translation process is complete
                    if (!ddtc_lu_content.tc.t2gpa) begin
                        trans_valid_o   = 1'b1;
                        spaddr_o        = iova_i[riscv::PLEN-1:0];
                    end

                    // If DC.tc.T2GPA = 1, translated requests are performed using a GPA. The IOMMU performs second-stage translation
                    else begin
                        // Stage 1 Bare
                        en_2S           = ~second_stage_is_bare;
                        gscid           = ddtc_lu_content.iohgatp.gscid;
                        // PSCID not used since Stage 1 is Bare
                        iohgatp_ppn     = ddtc_lu_content.iohgatp.ppn;
                        // iosatp not used since Stage 1 is Bare
                        iotlb_access    = 1'b1;
                    end
                end

                // Untranslated request
                else begin
                    
                    // No Process Context
                    if (!ddtc_lu_content.tc.pdtv) begin
                        en_1S           = ~first_stage_is_bare;
                        en_2S           = ~second_stage_is_bare;
                        gscid           = ddtc_lu_content.iohgatp.gscid;
                        pscid           = ddtc_lu_content.ta.pscid;
                        iohgatp_ppn     = ddtc_lu_content.iohgatp.ppn;
                        iosatp_ppn      = ddtc_lu_content.fsc.ppn;
                        iotlb_access    = 1'b1;
                    end

                    // Process Context associated
                    else begin
                        
                        // "If DPE is 0 and there is no process_id associated with the transaction, or if pdtp.MODE = Bare"
                        // "perform first-stage translation in Bare mode"
                        if ((!pv_i && !ddtc_lu_content.tc.dpe) || (ddtc_lu_content.fsc.mode == 4'b0000)) begin
                            // Stage 1 Bare
                            en_2S           = ~second_stage_is_bare;
                            gscid           = ddtc_lu_content.iohgatp.gscid;
                            // PSCID not used since Stage 1 is Bare
                            iohgatp_ppn     = ddtc_lu_content.iohgatp.ppn;
                            // iosatp not used since Stage 1 is Bare
                            iotlb_access    = 1'b1;
                        end

                        else pdtc_access = 1'b1;
                    end
                end
            end

            //# PDTC Lookup & Hit
            if (pdtc_lu_hit) begin
                
                // "Hold and stop if the transaction requests supervisor privilege but PC.ta.ENS is not set"
                if (priv_lvl_i && !pdtc_lu_content.ta.ens) begin
                    wrap_cause_code    = rv_iommu::TRANS_TYPE_DISALLOWED;
                    wrap_error   = 1'b1;
                end

                else begin
                    en_1S           = ~first_stage_is_bare;
                    en_2S           = ~second_stage_is_bare;
                    gscid           = ddtc_lu_content.iohgatp.gscid;
                    pscid           = pdtc_lu_content.ta.pscid;
                    iohgatp_ppn     = ddtc_lu_content.iohgatp.ppn;
                    iosatp_ppn      = pdtc_lu_content.fsc.ppn;
                    iotlb_access    = 1'b1;
                end
            end

            //# IOTLB Lookup & Hit
            if (iotlb_lu_hit) begin
                
                trans_valid_o   = 1'b1;

                /*
                    A fault is generated if:
                    - A bit is not set (checked in PTW);
                    - Page is not readable (checked in PTW);
                    - (1): Transaction is a store and page has not write permissions (D bit checked in PTW);
                    - (2): Transaction is read-for-execute and page has not X permissions;
                    - (3): U-mode transaction and PTE has U=0;
                    - (4): S-mode transaction and PTE has U=1 and (SUM=0 or x=1).
                */
                if  ((is_store && (!iotlb_lu_1S_content.w && en_1S)                                                 ) ||    // (1)
                        (is_rx && (!iotlb_lu_1S_content.x && en_1S)                                                 ) ||    // (2)
                        ((!priv_lvl_i) && !iotlb_lu_1S_content.u && en_1S                                           ) ||    // (3)
                        (priv_lvl_i && iotlb_lu_1S_content.u && (!pdtc_lu_content.ta.sum || iotlb_lu_1S_content.x)  )       // (4)
                    ) begin
                        if (is_store)   wrap_cause_code = rv_iommu::STORE_PAGE_FAULT;
                        else            wrap_cause_code = rv_iommu::LOAD_PAGE_FAULT;
                        wrap_error      = 1'b1;
                        trans_valid_o   = 1'b0;
                end

                else if ((is_store && (!iotlb_lu_2S_content.w && en_2S)) || // (1)
                            (is_rx && (!iotlb_lu_2S_content.x && en_2S))    // (2)
                        ) begin
                        if (is_store)   wrap_cause_code = rv_iommu::STORE_GUEST_PAGE_FAULT;
                        else            wrap_cause_code = rv_iommu::LOAD_GUEST_PAGE_FAULT;
                        wrap_error     = 1'b1;
                        trans_valid_o   = 1'b0;
                end 

                //# Address Translation Found
                else begin
                    
                    spaddr_o = {((en_2S) ? (iotlb_lu_2S_content.ppn) : (iotlb_lu_1S_content.ppn)), iova_i[11:0]};

                    // Apply superpage cases
                    if (en_1S && en_2S) begin
                        case ({iotlb_lu_1S_2M, iotlb_lu_1S_1G, iotlb_lu_2S_2M, iotlb_lu_2S_1G})

                            // 1-S: 4k | 2-S: 2M:   {PPN[2], PPN[1],  GPPN[0], OFF}
                            4'b0010:    spaddr_o[20:12] = iotlb_lu_1S_content.ppn[20:12];

                            // 1-S: 2M | 2-S: 2M:   {PPN[2], PPN[1],  VPN[0],  OFF}
                            // 1-S: 1G | 2-S: 2M:   {PPN[2], PPN[1],  VPN[0],  OFF}
                            4'b1010, 4'b0110:   spaddr_o[20:12] = iova_i[20:12];

                            // 1-S: 4k | 2-S: 1G:   {PPN[2], GPPN[1], GPPN[0], OFF}
                            4'b0001:    spaddr_o[29:12] = iotlb_lu_1S_content.ppn[29:12];

                            // 1-S: 1G | 2-S: 1G:   {PPN[2], VPN[1],  VPN[0],  OFF}
                            4'b0101:    spaddr_o[29:12] = iova_i[29:12];

                            // 1-S: 2M | 2-S: 1G:   {PPN[2], GPPN[1], VPN[0],  OFF}
                            4'b1001:    spaddr_o[29:12] = {iotlb_lu_1S_content.ppn[29:21], iova_i[20:12]};
                            
                            default:;
                                // 1-S: 4k | 2-S: 4k:   {PPN[2], PPN[1],  PPN[0],  OFF}
                                // 1-S: 2M | 2-S: 4k:   {PPN[2], PPN[1],  PPN[0],  OFF}
                                // 1-S: 1G | 2-S: 4k:   {PPN[2], PPN[1],  PPN[0],  OFF}
                        endcase
                    end

                    else begin
                        if (iotlb_lu_2S_1G || iotlb_lu_1S_1G)   spaddr_o[29:12] = iova_i[29:12];
                        if (iotlb_lu_2S_2M || iotlb_lu_1S_2M)   spaddr_o[20:12] = iova_i[20:12];
                    end
                end

                /*
                    # Note about IOPMP faults for translated IOVAs:
                    IOPMP access faults are reported as failing AXI transactions. After translating the IOVA,
                    the AXI transaction continues without IOMMU intervention (data is opaque to the IOMMU).
                    If the translated physical address violates an IOPMP check, the requesting device will be
                    responded by the IOPMP with an AXI error.
                */
            end

            // Both stages are Bare and the input address does not correspond to a MSI address
            // Input address is bypassed
            if (iotlb_access && bare_translation) begin
                trans_valid_o   = 1'b1;
                spaddr_o        = iova_i[riscv::PLEN-1:0];
            end
        end
    end

    //# Error routing
    always_comb begin : error_routing

        cause_code_o    = '0;
        trans_error_o   =  ((wrap_error)         |
                           (cdw_error)          |
                           (ptw_error)          |
                           (msiptw_error)       |
                           (mrif_handler_error) |
                           (msi_write_error_i));

        unique case (1'b1)
            wrap_error:         cause_code_o = wrap_cause_code;
            cdw_error:          cause_code_o = cdw_cause_code;
            ptw_error:          cause_code_o = ptw_cause_code;
            msiptw_error:       cause_code_o = msiptw_cause_code;
            mrif_handler_error: cause_code_o = mrif_handler_cause_code;
            msi_write_error_i:  cause_code_o = rv_iommu::MSI_ST_ACCESS_FAULT;
        endcase
    end : error_routing

endmodule