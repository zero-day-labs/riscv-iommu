// Copyright (c) 2023 University of Minho
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
    Author: Manuel Rodríguez, University of Minho
    Date: 06/02/2023

    Description: RISC-V IOMMU Translation Modules Wrapper.
*/

//! NOTES:
/*
    - For now, req_trans_i must be hold high for the entire translation process (whenever walks are needed). If it is cleared, 
      IOTLB hit signal is also cleared even if it has a valid translation. Further on, input signals may be propagated to achieve 
      a stronger implementation (+ HW cost).
*/

module iommu_translation_wrapper import ariane_pkg::*; #(

    parameter int unsigned  IOTLB_ENTRIES       = 4,
    parameter int unsigned  DDTC_ENTRIES        = 4,
    parameter int unsigned  PDTC_ENTRIES        = 4,
    parameter int unsigned  DEVICE_ID_WIDTH     = 24,
    parameter int unsigned  PROCESS_ID_WIDTH    = 20,
    parameter int unsigned  PSCID_WIDTH         = 20,
    parameter int unsigned  GSCID_WIDTH         = 16,

    parameter bit           InclPID             = 0,
    parameter bit           InclMSI_IG          = 0
) (
    input  logic    clk_i,
    input  logic    rst_ni,

    input  logic    req_trans_i,            // Trigger translation

    // Translation request data
    input  logic [DEVICE_ID_WIDTH-1:0]      device_id_i,
    input  logic                            pid_v_i,                // A valid process_id is associated with the request
    input  logic [PROCESS_ID_WIDTH-1:0]     process_id_i,
    input  logic [riscv::VLEN-1:0]          iova_i,
    
    input  logic [iommu_pkg::TTYP_LEN-1:0]  trans_type_i,           //? When not implementing ATS, are all requests untranslated?
    input  riscv::priv_lvl_t                priv_lvl_i,             // Privilege mode associated with the transaction

    // Memory Bus
    input  ariane_axi::resp_t       mem_resp_i,
    output ariane_axi::req_t        mem_req_o,

    // From Regmap
    input  iommu_reg_pkg::iommu_reg2hw_capabilities_reg_t   capabilities_i,
    input  iommu_reg_pkg::iommu_reg2hw_fctl_reg_t           fctl_i,
    input  iommu_reg_pkg::iommu_reg2hw_ddtp_reg_t           ddtp_i,
    // CQ
    input  logic [riscv::PPNW-1:0]      cqb_ppn_i,
    input  logic [4:0]                  cqb_size_i,
    input  logic [31:0]                 cqh_i,
    output logic [31:0]                 cqh_o,
    input  logic [31:0]                 cqt_i,
    // FQ
    input  logic [riscv::PPNW-1:0]      fqb_ppn_i,
    input  logic [4:0]                  fqb_size_i,
    input  logic [31:0]                 fqh_i,
    input  logic [31:0]                 fqt_i,
    output logic [31:0]                 fqt_o,
    // cqcsr
    input  logic                        cq_en_i,
    input  logic                        cq_ie_i,
    input  logic                        cq_mf_i,
    input  logic                        cq_cmd_to_i,    
    input  logic                        cq_cmd_ill_i,
    input  logic                        cq_fence_w_ip_i,
    output logic                        cq_mf_o,
    output logic                        cq_cmd_to_o,
    output logic                        cq_cmd_ill_o,
    output logic                        cq_fence_w_ip_o,
    output logic                        cq_on_o,
    output logic                        cq_busy_o,
    // fqcsr
    input  logic                        fq_en_i,
    input  logic                        fq_ie_i,
    input  logic                        fq_mf_i,
    input  logic                        fq_of_i,
    output logic                        fq_mf_o,
    output logic                        fq_of_o,
    output logic                        fq_on_o,
    output logic                        fq_busy_o,
    // ipsr
    input  logic                        cq_ip_i,
    input  logic                        fq_ip_i,
    output logic                        cq_ip_o,
    output logic                        fq_ip_o,
    // icvec
    input  logic [3:0]                  civ_i,
    input  logic [3:0]                  fiv_i,
    // MSI config table
    input  logic [53:0]                 msi_addr_x_i[16],
    input  logic [31:0]                 msi_data_x_i[16],
    input  logic                        msi_vec_masked_x_i[16],

    // To enable write of error bits to cqcsr and fqcsr
    output logic                        cq_error_wen_o,
    output logic                        fq_error_wen_o,

    // Request status and output data
    output logic                        trans_valid_o,      // Translation completed
    output logic                        is_msi_o,           // Indicate whether the translated address is an MSI address
    output logic [riscv::PLEN-1:0]      translated_addr_o,  // Translated address
    output logic                        trans_error_o,

    output logic                        is_fq_fifo_full_o
);

    // DDTC
    logic                       ddtc_access;
    iommu_pkg::dc_ext_t         ddtc_lu_content;
    logic                       ddtc_lu_hit;

    // PDTC
    logic                       pdtc_access;
    iommu_pkg::pc_t             pdtc_lu_content;
    logic                       pdtc_lu_hit;

    // IOTLB
    logic                       iotlb_access;
    logic [riscv::GPLEN-1:0]    iotlb_lu_gpaddr;
    riscv::pte_t                iotlb_lu_content;
    riscv::pte_t                iotlb_lu_g_content;
    logic                       iotlb_lu_is_s_2M;
    logic                       iotlb_lu_is_s_1G;
    logic                       iotlb_lu_is_g_2M;
    logic                       iotlb_lu_is_g_1G;
    logic                       iotlb_lu_is_msi;
    logic                       iotlb_lu_hit;

    // Bare translation signaled by PTW
    logic is_bare_translation;

    // PTW error
    logic ptw_error;
    logic [(iommu_pkg::CAUSE_LEN-1):0]  ptw_cause_code;

    // CDW error
    logic cdw_error;
    logic [(iommu_pkg::CAUSE_LEN-1):0]  cdw_cause_code;

    // Address translation parameters
    logic en_stage1, en_stage2;
    logic [GSCID_WIDTH-1:0] gscid;
    logic [PSCID_WIDTH-1:0] pscid;
    logic [riscv::PPNW-1:0] iohgatp_ppn, iosatp_ppn;

    // PTW implicit translations for CDW walks
    logic                           cdw_implicit_access;
    logic [riscv::GPPNW-1:0]        pdt_gppn;
    logic                           cdw_done;
    logic                           flush_cdw;
    logic [riscv::PPNW-1:0]         iohgatp_ppn_fw;
    logic                           is_ddt_walk;

    // If DC.tc.DPE is 1 and no valid process_id is given by the device, default value of zero is used
    logic [PROCESS_ID_WIDTH-1:0] process_id;
    assign process_id = (!pid_v_i && ddtc_lu_content.tc.dpe) ? '0 : process_id_i;

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
    assign is_pcie_tr_req = (trans_type_i == iommu_pkg::PCIE_ATS_TRANS_REQ);

    // To determine if transaction is a store
    logic is_store;
    assign is_store = ((&trans_type_i[1:0] == 1'b1) && (!trans_type_i[3]));

    // To determine if transaction is read-for-execute
    logic is_rx;
    assign is_rx = (!trans_type_i[3] && !trans_type_i[1] && trans_type_i[0]);

    // To determine if transaction has supervisor privilege
    logic   is_s_priv;
    assign  is_s_priv   = (priv_lvl_i == riscv::PRIV_LVL_S);

    // Efective iohgatp.ppn field to introduce in the PTW. May need to be forwarded by the CDW
    logic [riscv::PPNW-1:0] ptw_iohgatp_ppn;
    assign ptw_iohgatp_ppn = (is_ddt_walk & cdw_implicit_access) ? iohgatp_ppn_fw : iohgatp_ppn;

    // To select en_stage1 and en_stage2 source for PTW implicit second-stage translations in CDW Walks
    logic   ptw_en_stage1, ptw_en_stage2;
    assign  ptw_en_stage1 = (cdw_implicit_access) ? 1'b0 : en_stage1;
    assign  ptw_en_stage2 = (cdw_implicit_access) ? 1'b1 : en_stage2;

    // Set for faults occurred before DDTC lookup
    logic   report_always;
    // Error/fault signaling according to the spec
    logic                               trans_error;
    logic [(iommu_pkg::CAUSE_LEN-1):0]  cause_code;       // Fault code as defined by IOMMU and Priv Spec
    // To indicate whether the occurring fault has to be reported according to DC.tc.DTF and the fault source
    // If DC.tc.DTF=1, only faults occurred before finding the corresponding DC should be reported
    logic   report_fault;
    logic   msi_write_error;
    assign  report_fault    = (((ddtc_lu_hit & !ddtc_lu_content.tc.dtf) | 
                               (report_always | msi_write_error | (cdw_error & is_ddt_walk))) & trans_error);
    assign  trans_error_o   = trans_error;  // The requesting device needs to know if an error occurred

    logic   is_implicit;
    logic   ptw_error_stage2_int;
    assign  is_implicit = (ptw_error_stage2_int | (flush_cdw & ~is_ddt_walk));

    // To indicate if the IOMMU supports and uses WSI as interrupt generation mechanism
    logic   wsi_en;
    assign  wsi_en = (^capabilities_i.igs.q & fctl_i.wsi.q);

    // To indicate if the IOMMU supports and uses MSI as interrupt generation mechanism
    logic   msi_ig_en;
    assign  msi_ig_en = (!capabilities_i.igs.q[0] & !fctl_i.wsi.q);


    // Update wires
    logic                           ddtc_update;
    logic [DEVICE_ID_WIDTH-1:0]     ddtc_up_did;
    iommu_pkg::dc_ext_t             ddtc_up_content;

    logic                           pdtc_update;
    logic [PROCESS_ID_WIDTH-1:0]    pdtc_up_pid;
    iommu_pkg::pc_t                 pdtc_up_content;

    logic                           iotlb_update;
    logic                           iotlb_up_is_s_2M;
    logic                           iotlb_up_is_s_1G;
    logic                           iotlb_up_is_g_2M;
    logic                           iotlb_up_is_g_1G;
    logic                           iotlb_up_is_msi;
    logic [riscv::GPPNW-1:0]        iotlb_up_vpn;
    logic [PSCID_WIDTH-1:0]         iotlb_up_pscid;
    logic [GSCID_WIDTH-1:0]         iotlb_up_gscid;
    riscv::pte_t                    iotlb_up_content;
    riscv::pte_t                    iotlb_up_g_content;

    // Flush wires
    logic                           flush_ddtc;
    logic                           flush_dv;
    logic [DEVICE_ID_WIDTH-1:0]     flush_did;
    logic                           flush_pdtc;
    logic                           flush_pv;
    logic [PROCESS_ID_WIDTH-1:0]    flush_pid;
    logic                           flush_vma;
    logic                           flush_gvma;
    logic                           flush_av;
    logic                           flush_gv;
    logic                           flush_pscv;
    logic [riscv::GPPNW-1:0]        flush_vpn;
    logic [GSCID_WIDTH-1:0]         flush_gscid;
    logic [PSCID_WIDTH-1:0]         flush_pscid;

    // AXI interfaces
    ariane_axi::resp_t  ptw_axi_resp;
    ariane_axi::req_t   ptw_axi_req;
    ariane_axi::resp_t  cdw_axi_resp;
    ariane_axi::req_t   cdw_axi_req;
    ariane_axi::resp_t  cq_axi_resp;
    ariane_axi::req_t   cq_axi_req;
    ariane_axi::resp_t  fq_axi_resp;
    ariane_axi::req_t   fq_axi_req;
    ariane_axi::resp_t  ig_axi_resp;
    ariane_axi::req_t   ig_axi_req;


    // More wires
    logic                       ptw_error_stage2;   // Set when a guest page fault occurs
    logic [riscv::GPLEN-1:0]    ptw_bad_gpaddr;

    //# Arbitration and mux logic to assign AXI4 Master IF to a module
    mem_if_wrapper i_mem_if_wrapper (

        .clk_i          (clk_i),
        .rst_ni         (rst_ni),

        // External ports: To AXI Bus
        .mem_resp_i     (mem_resp_i),
        .mem_req_o      (mem_req_o),
        
        // From PTW
        .ptw_resp_o     (ptw_axi_resp),
        .ptw_req_i      (ptw_axi_req),

        // From CDW
        .cdw_resp_o     (cdw_axi_resp),
        .cdw_req_i      (cdw_axi_req),

        // From CQ
        .cq_resp_o      (cq_axi_resp),
        .cq_req_i       (cq_axi_req),

        // From FQ
        .fq_resp_o      (fq_axi_resp),
        .fq_req_i       (fq_axi_req),

        .ig_resp_o      (ig_axi_resp),
        .ig_req_i       (ig_axi_req)
    );

    //# Device Directory Table Cache
    iommu_ddtc #(
        .DDTC_ENTRIES       (DDTC_ENTRIES),
        .DEVICE_ID_WIDTH    (DEVICE_ID_WIDTH)
    ) i_iommu_ddtc (
        .clk_i              (clk_i),            // Clock
        .rst_ni             (rst_ni),           // Asynchronous reset active low

        .flush_i            (flush_ddtc),                 // IODIR.INVAL_DDT
        .flush_dv_i         (flush_dv),                 // device_id valid
        .flush_did_i        (flush_did),                 // device_id to be flushed

        // Update signals
        .update_i           (ddtc_update),      // update flag
        .up_did_i           (ddtc_up_did),      // device ID to be updated
        .up_content_i       (ddtc_up_content),  // DC to be inserted

        // Lookup signals
        .lookup_i           (ddtc_access),      // lookup flag
        .lu_did_i           (device_id_i),      // device_id to look for 
        .lu_content_o       (ddtc_lu_content),  // DC found in DDTC
        .lu_hit_o           (ddtc_lu_hit)       // hit flag
    );

    //# Process Directory Table Cache
    if (InclPID) begin : gen_pid_support
        iommu_pdtc #(
            .PDTC_ENTRIES       (PDTC_ENTRIES),
            .DEVICE_ID_WIDTH    (DEVICE_ID_WIDTH),
            .PROCESS_ID_WIDTH   (PROCESS_ID_WIDTH)
        ) i_iommu_pdtc (
            .clk_i              (clk_i),            // Clock
            .rst_ni             (rst_ni),           // Asynchronous reset active low

            // Flush signals
            .flush_i            (flush_pdtc),                 // IODIR.INVAL_DDT or IODIR.INVAL_PDT
            .flush_dv_i         (flush_dv),                 // flush everything or only entries associated to DID (IODIR.INVAL_DDT)
            .flush_pv_i         (flush_pv),                 // flush entries tagged with DID and PID only (IODIR.INVAL_PDT)
            .flush_did_i        (flush_did),                 // device_id to be flushed
            .flush_pid_i        (flush_pid),                 // process_id to be flushed (if flush_pv_i = 1)

            // Update signals
            .update_i           (pdtc_update),      // update flag
            .up_did_i           (ddtc_up_did),      // device ID to be inserted
            .up_pid_i           (pdtc_up_pid),      // process ID to be inserted
            .up_content_i       (pdtc_up_content),  // PC to be inserted

            // Lookup signals
            .lookup_i           (pdtc_access),      // lookup flag
            .lu_did_i           (device_id_i),      // device_id to tag PDTC
            .lu_pid_i           (process_id),       // process_id to tag PDTC
            .lu_content_o       (pdtc_lu_content),  // PC found in PDTC
            .lu_hit_o           (pdtc_lu_hit)       // hit flag
        );
    end
    // No process_id support
    else begin
        assign pdtc_lu_content  = '0;
        assign pdtc_lu_hit      = 1'b0;
    end


    //# IOTLB: Address Translation Cache
    iommu_iotlb_sv39x4 #(
        .IOTLB_ENTRIES      (IOTLB_ENTRIES),
        .PSCID_WIDTH        (PSCID_WIDTH),
        .GSCID_WIDTH        (GSCID_WIDTH)
    ) i_iommu_iotlb_sv39x4 (
        .clk_i              (clk_i),    // Clock
        .rst_ni             (rst_ni),   // Asynchronous reset active low

        // Flush signals
        .flush_vma_i        (flush_vma),         // IOTINVAL.VMA
        .flush_gvma_i       (flush_gvma),         // IOTINVAL.GVMA
        .flush_av_i         (flush_av),         // ADDR valid
        .flush_gv_i         (flush_gv),         // GSCID valid
        .flush_pscv_i       (flush_pscv),         // PSCID valid
        .flush_vpn_i        (flush_vpn),         // VPN to be flushed
        .flush_gscid_i      (flush_gscid),         // GSCID identifier to be flushed (VM identifier)
        .flush_pscid_i      (flush_pscid),         // PSCID identifier to be flushed (address space identifier)

        // Update signals
        .update_i           (iotlb_update),
        .up_is_s_2M_i       (iotlb_up_is_s_2M),
        .up_is_s_1G_i       (iotlb_up_is_s_1G),
        .up_is_g_2M_i       (iotlb_up_is_g_2M),
        .up_is_g_1G_i       (iotlb_up_is_g_1G),
        .up_is_msi_i        (iotlb_up_is_msi),
        .up_vpn_i           (iotlb_up_vpn),
        .up_pscid_i         (iotlb_up_pscid),
        .up_gscid_i         (iotlb_up_gscid),
        .up_content_i       (iotlb_up_content),
        .up_g_content_i     (iotlb_up_g_content),

        // Lookup signals
        .lookup_i           (iotlb_access),         // lookup flag
        .lu_iova_i          (iova_i),               // IOVA to look for 
        .lu_pscid_i         (pscid),                // PSCID to look for
        .lu_gscid_i         (gscid),                // GSCID to look for
        .lu_gpaddr_o        (iotlb_lu_gpaddr),      // GPA to return in case of an exception
        .lu_content_o       (iotlb_lu_content),     // S/VS-stage PTE (GPA PPN)
        .lu_g_content_o     (iotlb_lu_g_content),   // G-stage PTE (SPA PPN)
        .lu_is_s_2M_o       (iotlb_lu_is_s_2M),               
        .lu_is_s_1G_o       (iotlb_lu_is_s_1G),
        .lu_is_g_2M_o       (iotlb_lu_is_g_2M),               
        .lu_is_g_1G_o       (iotlb_lu_is_g_1G),
        .lu_is_msi_o        (iotlb_lu_is_msi),      // IOTLB entry contains a GPA associated with a guest vIMSIC
        .s_stg_en_i         (en_stage1),            // s-stage enabled
        .g_stg_en_i         (en_stage2),            // g-stage enabled
        .lu_hit_o           (iotlb_lu_hit)          // hit flag
    );

    //# Page Table Walker
    iommu_ptw_sv39x4 #(
        .PSCID_WIDTH        (PSCID_WIDTH),
        .GSCID_WIDTH        (GSCID_WIDTH)
    ) i_iommu_ptw_sv39x4 (
        .clk_i              (clk_i),                  // Clock
        .rst_ni             (rst_ni),                 // Asynchronous reset active low
        
        // Error signaling
        .ptw_active_o           (),                     // Set when PTW is walking memory
        .ptw_error_o            (ptw_error),            // set when an error occurred (excluding access errors)
        .ptw_error_stage2_o     (ptw_error_stage2),     // set when the fault occurred in stage 2
        .ptw_error_stage2_int_o (ptw_error_stage2_int), // set when fault occurred during an implicit access for 1st-stage translation
        .cause_code_o           (ptw_cause_code),

        .en_stage1_i            (ptw_en_stage1),        // Enable signal for stage 1 translation. Defined by DC/PC
        .en_stage2_i            (ptw_en_stage2),        // Enable signal for stage 2 translation. Defined by DC only
        .is_store_i             (is_store),             // Indicate whether this translation was triggered by a store or a load
        .is_rx_i                (is_rx),                // Read-for-execute

        // PTW AXI Master memory interface
        .mem_resp_i             (ptw_axi_resp),           // Response port from memory
        .mem_req_o              (ptw_axi_req),            // Request port to memory

        // to IOTLB, update logic
        .update_o               (iotlb_update),
        .up_is_s_2M_o           (iotlb_up_is_s_2M),
        .up_is_s_1G_o           (iotlb_up_is_s_1G),
        .up_is_g_2M_o           (iotlb_up_is_g_2M),
        .up_is_g_1G_o           (iotlb_up_is_g_1G),
        .up_is_msi_o            (iotlb_up_is_msi),
        .up_vpn_o               (iotlb_up_vpn),
        .up_pscid_o             (iotlb_up_pscid),
        .up_gscid_o             (iotlb_up_gscid),
        .up_content_o           (iotlb_up_content),
        .up_g_content_o         (iotlb_up_g_content),

        // IOTLB tags
        .req_iova_i             (iova_i),
        .pscid_i                (pscid),
        .gscid_i                (gscid),

        // MSI translation
        .msi_en_i               (msi_enabled),
        .msiptp_ppn_i           (ddtc_lu_content.msiptp.ppn),
        .msi_addr_mask_i        (ddtc_lu_content.msi_addr_mask.mask),
        .msi_addr_pattern_i     (ddtc_lu_content.msi_addr_pattern.pattern),
        .bare_translation_o     (is_bare_translation),     // both stages are in bare mode and address is not MSI

        // CDW implicit translations (Second-stage only)
        .cdw_implicit_access_i  (cdw_implicit_access),
        .pdt_gppn_i             (pdt_gppn),
        .cdw_done_o             (cdw_done),
        .flush_cdw_o            (flush_cdw),

        // from IOTLB, to monitor misses
        .iotlb_access_i         (iotlb_access),
        .iotlb_hit_i            (iotlb_lu_hit),

        // from DC/PC
        .iosatp_ppn_i           (iosatp_ppn),       // ppn from iosatp
        .iohgatp_ppn_i          (ptw_iohgatp_ppn),  // ppn from iohgatp (may be forwarded by the CDW)

        .bad_gpaddr_o           (ptw_bad_gpaddr)    // to return the GPA in case of guest page fault
    );

    //# Context Directory Walker
    iommu_cdw #(
        .DEVICE_ID_WIDTH        (DEVICE_ID_WIDTH),
        .PROCESS_ID_WIDTH       (PROCESS_ID_WIDTH),
        .InclPID                (InclPID)
    ) i_iommu_cdw (
        .clk_i                  (clk_i),                // Clock
        .rst_ni                 (rst_ni),               // Asynchronous reset active low
        
        // Error signaling
        .cdw_active_o           (),                     // Set when CDW is walking memory
        .cdw_error_o            (cdw_error),            // set when an error occurred
        .cause_code_o           (cdw_cause_code),       // Fault code as defined by IOMMU and Priv Spec

        // DC config checks
        .caps_ats_i             (capabilities_i.ats.q),
        .caps_t2gpa_i           (capabilities_i.t2gpa.q),
        .caps_pd20_i            (capabilities_i.pd20.q),
        .caps_pd17_i            (capabilities_i.pd17.q),
        .caps_pd8_i             (capabilities_i.pd8.q),
        .caps_sv32_i            (capabilities_i.sv32.q),
        .caps_sv39_i            (capabilities_i.sv39.q),
        .caps_sv48_i            (capabilities_i.sv48.q), 
        .caps_sv57_i            (capabilities_i.sv57.q),
        .fctl_gxl_i             (fctl_i.gxl.q),
        .caps_sv32x4_i          (capabilities_i.sv32x4.q),
        .caps_sv39x4_i          (capabilities_i.sv39x4.q),
        .caps_sv48x4_i          (capabilities_i.sv48x4.q),
        .caps_sv57x4_i          (capabilities_i.sv57x4.q),
        .caps_msi_flat_i        (capabilities_i.msi_flat.q),
        .caps_amo_i             (capabilities_i.amo.q),
        .caps_end_i             (capabilities_i.endi.q),
        .fctl_be_i              (fctl_i.be.q),

        // PC checks
        .dc_sxl_i               (ddtc_lu_content.tc.sxl),

        // PTW memory interface
        .mem_resp_i             (cdw_axi_resp),            // Response port from memory
        .mem_req_o              (cdw_axi_req),             // Request port to memory

        // Update logic
        .update_dc_o            (ddtc_update),
        .up_did_o               (ddtc_up_did),
        .up_dc_content_o        (ddtc_up_content),

        .update_pc_o            (pdtc_update),
        .up_pid_o               (pdtc_up_pid),
        .up_pc_content_o        (pdtc_up_content),

        // CDCs tags
        .req_did_i              (device_id_i),          // device ID associated with request
        .req_pid_i              (process_id),           // process ID associated with request

        // from DDTC / PDTC, to monitor misses
        .ddtc_access_i          (ddtc_access),
        .ddtc_hit_i             (ddtc_lu_hit),

        .pdtc_access_i          (pdtc_access),
        .pdtc_hit_i             (pdtc_lu_hit),

        // from regmap
        .ddtp_ppn_i             (ddtp_i.ppn.q),       // PPN from ddtp register
        .ddtp_mode_i            (ddtp_i.iommu_mode.q),      // DDT levels and IOMMU mode

        // from DC (for PC walks)
        .en_stage2_i            (en_stage2),                    // Second-stage translation is enabled
        .pdtp_ppn_i             (ddtc_lu_content.fsc.ppn),      // PPN from DC.fsc.PPN
        .pdtp_mode_i            (ddtc_lu_content.fsc.mode),     // PDT levels from DC.fsc.MODE

        // CDW implicit translations (Second-stage only)
        .ptw_done_i             (cdw_done),
        .flush_i                (flush_cdw),
        .pdt_ppn_i              (iotlb_up_g_content.ppn),
        .cdw_implicit_access_o  (cdw_implicit_access),
        .is_ddt_walk_o          (is_ddt_walk),
        .pdt_gppn_o             (pdt_gppn),
        .iohgatp_ppn_fw_o       (iohgatp_ppn_fw)  // to forward iohgatp.PPN to PTW when translating pdtp.PPN
    );

    //# Command Queue
    cq_handler #(
            .DEVICE_ID_WIDTH    (DEVICE_ID_WIDTH),
            .PROCESS_ID_WIDTH   (PROCESS_ID_WIDTH),
            .PSCID_WIDTH        (PSCID_WIDTH),
            .GSCID_WIDTH        (GSCID_WIDTH)
    ) i_cq_handler (
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),

        // Regmap
        .cq_base_ppn_i          (cqb_ppn_i),        // Base address of the CQ in memory (Should be aligned. See Spec)
        .cq_size_i              (cqb_size_i),        // Size of the CQ as log2-1 (2 entries: 0 | 4 entries: 1 | 8 entries: 2 | ...)

        .cq_en_i                (cq_en_i),          // CQ enable bit from cqcsr, handled by SW
        .cq_ie_i                (cq_ie_i),          // CQ interrupt enable bit from cqcsr, handled by SW

        .cq_tail_i              (cqt_i),            // CQ tail index (SW writes the next CQ entry to cq_base + cq_tail * 16 bytes)
        .cq_head_i              (cqh_i),            // CQ head index (the IOMMU reads the next entry from cq_base + cq_head * 16 bytes)
        .cq_head_o              (cqh_o),

        .cq_on_o                (cq_on_o),          // CQ active bit. Indicates to SW whether the CQ is active or not
        .busy_o                 (cq_busy_o),        // CQ busy bit. Indicates SW that the CQ is in the middle of a state transition, 
                                                    //              so it has to wait to write to cqcsr.

        .cq_mf_i                (cq_mf_i),          // Error bit status 
        .cmd_to_i               (cq_cmd_to_i),    
        .cmd_ill_i              (cq_cmd_ill_i),
        .fence_w_ip_i           (cq_fence_w_ip_i), 

        .error_wen_o            (cq_error_wen_o),   // To enable write of corresponding error bit to regmap
        .cq_mf_o                (cq_mf_o),          // Set when a memory fault occurred during CQ access
        .cmd_to_o               (cq_cmd_to_o),      // The execution of a command lead to a timeout //! Future work for PCIe ATS
        .cmd_ill_o              (cq_cmd_ill_o),     // Illegal or unsupported command was fetched from CQ
        .fence_w_ip_o           (cq_fence_w_ip_o),  // Set to indicate completion of an IOFENCE command
        .cq_ip_o                (cq_ip_o),          // To set cip bit in ipsr register if a fault occurs and cq_ie is set

        .wsi_en_i               (wsi_en),           // To know whether WSI generation is supported

        // DDTC Invalidation
        .flush_ddtc_o           (flush_ddtc),       // Flush DDTC
        .flush_dv_o             (flush_dv),         // Indicates if device_id is valid
        .flush_did_o            (flush_did),        // device_id to tag entries to be flushed

        // PDTC Invalidation
        .flush_pdtc_o           (flush_pdtc),       // Flush PDTC
        .flush_pv_o             (flush_pv),         // This is used to difference between IODIR.INVAL_DDT and IODIR.INVAL_PDT
        .flush_pid_o            (flush_pid),        // process_id to be flushed if PV = 1

        // IOTLB Invalidation
        .flush_vma_o            (flush_vma),        // Flush first-stage PTEs cached entries in IOTLB
        .flush_gvma_o           (flush_gvma),       // Flush second-stage PTEs cached entries in IOTLB 
        .flush_av_o             (flush_av),         // Address valid
        .flush_gv_o             (flush_gv),         // GSCID valid
        .flush_pscv_o           (flush_pscv),       // PSCID valid
        .flush_vpn_o            (flush_vpn),        // IOVA to tag entries to be flushed
        .flush_gscid_o          (flush_gscid),      // GSCID (Guest physical address space identifier) to tag entries to be flushed
        .flush_pscid_o          (flush_pscid),      // PSCID (Guest virtual address space identifier) to tag entries to be flushed

        // Memory Bus
        .mem_resp_i             (cq_axi_resp),
        .mem_req_o              (cq_axi_req)
    );

    /* verilator lint_off WIDTH */
    //# Fault/Event Queue
    fq_handler #(
        .DEVICE_ID_WIDTH        (DEVICE_ID_WIDTH),
        .PROCESS_ID_WIDTH       (PROCESS_ID_WIDTH)
    ) i_fq_handler ( 
        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),

        // Regmap
        .fq_base_ppn_i          (fqb_ppn_i),        // Base address of the FQ in memory (Should be aligned. See Spec)
        .fq_size_i              (fqb_size_i),        // Size of the FQ as log2-1 (2 entries: 0 | 4 entries: 1 | 8 entries: 2 | ...)

        .fq_en_i                (fq_en_i),          // FQ enable bit from fqcsr, handled by SW
        .fq_ie_i                (fq_ie_i),          // FQ interrupt enable bit from fqcsr, handled by SW

        .fq_head_i              (fqh_i),            // FQ head index (SW reads the next entry from fq_base + fq_head * 32 bytes)
        .fq_tail_i              (fqt_i),            // FQ tail index (IOMMU writes the next FQ entry to fq_base + fq_tail * 32 bytes)
        .fq_tail_o              (fqt_o),

        .fq_on_o                (fq_on_o),          // FQ active bit. Indicates to SW whether the FQ is active or not
        .busy_o                 (fq_busy_o),        // FQ busy bit. Indicates SW that the FQ is in the middle of a state transition, 
                                                    //              so it has to wait to write to fqcsr.

        .fq_mf_i                (fq_mf_i),             
        .fq_of_i                (fq_of_i),  

        .error_wen_o            (fq_error_wen_o),   // To enable write of corresponding error bit to regmap
        .fq_mf_o                (fq_mf_o),          // Set when a memory fault occurred during FQ access
        .fq_of_o                (fq_of_o),          // The execution of a command lead to a timeout 
        .fq_ip_o                (fq_ip_o),          // To set ipsr.fip register if a fault occurs and fq_ie is set

        // Event data
        .event_valid_i          (report_fault),     // a fault/event has occurred
        .trans_type_i           ((msi_write_error) ? ('0) : (trans_type_i)),     // transaction type
        .cause_code_i           ((msi_write_error) ? (iommu_pkg::MSI_ST_ACCESS_FAULT) : (cause_code)), // Fault code as defined by IOMMU and Priv Spec
        .iova_i                 ((msi_write_error) ? (ig_axi_req.aw.addr[55:2]) : (iova_i)),  // to report if transaction has an IOVA
        .gpaddr_i               (ptw_bad_gpaddr),   // to report bits [63:2] of the GPA in case of a Guest Page Fault
        .did_i                  (device_id_i),      // device_id associated with the transaction
        .pv_i                   (pid_v_i),          // to indicate if transaction has a valid process_id
        .pid_i                  (process_id),       // process_id associated with the transaction
        .is_supervisor_i        (is_s_priv),        // indicate if transaction has supervisor privilege
        .is_guest_pf_i          (ptw_error_stage2), // indicate if event is a guest page fault
        .is_implicit_i          (is_implicit),      // Guest page fault caused by implicit access for 1st-stage addr translation

        // Memory Bus
        .mem_resp_i             (fq_axi_resp),
        .mem_req_o              (fq_axi_req),

        .is_full_o            (is_fq_fifo_full_o)
    );
    /* verilator lint_on WIDTH */

    //# MSI Interrupt Generation
    if (InclMSI_IG) begin : gen_msi_ig_support

        iommu_msi_ig i_iommu_msi_ig (
            .clk_i              (clk_i),
            .rst_ni             (rst_ni),

            .msi_ig_enabled_i   (msi_ig_en),

            .cip_i              (cq_ip_i),
            .fip_i              (fq_ip_i),

            .civ_i              (civ_i),
            .fiv_i              (fiv_i),

            .msi_addr_x_i       (msi_addr_x_i),
            .msi_data_x_i       (msi_data_x_i),
            .msi_vec_masked_x_i (msi_vec_masked_x_i),

            .msi_write_error_o  (msi_write_error),

            .mem_resp_i         (ig_axi_resp),
            .mem_req_o          (ig_axi_req)
        );
    end

    // Hardwire outputs to zero
    else begin
        assign  msi_write_error = 1'b0;
        assign  ig_axi_req      = '0;
    end


    //# Translation logic

    always_comb begin : translation

        ddtc_access         = 1'b0;
        pdtc_access         = 1'b0;
        en_stage1           = 1'b0;
        en_stage2           = 1'b0;
        gscid               = '0;
        pscid               = '0;
        iosatp_ppn          = '0;
        iohgatp_ppn         = '0;
        iotlb_access        = 1'b0;
        cause_code          = '0;
        trans_error         = 1'b0;
        is_msi_o            = 1'b0;
        trans_valid_o       = 1'b0;
        translated_addr_o   = '0;
        report_always       = 1'b0;

        // A translation is triggered by setting req_trans_i
        if (req_trans_i) begin
    
            //# Input Checks
            // "If ddtp.iommu_mode == Off then stop and report "All inbound transactions disallowed" (cause = 256)."
            if (ddtp_i.iommu_mode.q == 4'b0000) begin
                cause_code    = iommu_pkg::ALL_INB_TRANSACTIONS_DISALLOWED;
                trans_error   = 1'b1;
                report_always   = 1'b1;
            end

            // "If ddtp.iommu_mode == Bare and any of the following conditions (*) hold then stop and report "Transaction type disallowed" (cause = 260)."
            else if (ddtp_i.iommu_mode.q == 4'b0001) begin
                
                // "(*) If the transaction is a translated request or a PCIe ATS request"
                if (is_translated || is_pcie_tr_req) begin
                    cause_code    = iommu_pkg::TRANS_TYPE_DISALLOWED;
                    trans_error   = 1'b1;
                    report_always   = 1'b1;
                end

                // " else the translation process is completed with the IOVA as the translated address"
                else begin
                    trans_valid_o       = 1'b1;
                    translated_addr_o   = iova_i[riscv::PLEN-1:0];
                end
            end

            // This implementation will support MSI address translation, so DC always is presented in extended format

            // "If the device_id is wider than supported by the IOMMU, then stop and report "Transaction type disallowed" (cause = 260)."
            else if ((ddtp_i.iommu_mode.q == 4'b0011 && (|device_id_i[23:15])) || (ddtp_i.iommu_mode.q == 4'b0010 && (|device_id_i[23:6]))) begin
                cause_code = iommu_pkg::TRANS_TYPE_DISALLOWED;
                trans_error   = 1'b1;
                report_always   = 1'b1;
            end

            // IOMMU is not in bare mode and no errors ocurred. Lookup DDTC
            else ddtc_access = 1'b1;
        end

        //# DDTC Lookup
        // Access to DDTC and PDTC is automatically triggered when setting req_trans_i if no fault is generated
        // If hit flag is set in the same cycle, we have a DDTC instantaneous hit
        if (ddtc_lu_hit) begin

            // "If any of the following conditions hold then stop and report "Transaction type disallowed" (cause = 260)."
            if (((is_translated || is_pcie_tr_req) && !ddtc_lu_content.tc.en_ats) ||
                (pid_v_i && !ddtc_lu_content.tc.pdtv) ||
                (pid_v_i && ddtc_lu_content.tc.pdtv && pid_wider_than_supported)) begin

                cause_code = iommu_pkg::TRANS_TYPE_DISALLOWED;
                trans_error   = 1'b1;
            end

            // avoid triggering a CDW walk for a PC or a PTW walk when the previous fault occurs 
            else begin

                // Translated request
                if (is_translated) begin

                    // When DC.tc.T2GPA = 0, translated requests are performed using an SPA. Translation process is complete
                    if (!ddtc_lu_content.tc.t2gpa) begin
                        trans_valid_o       = 1'b1;
                        translated_addr_o   = iova_i[riscv::PLEN-1:0];
                    end

                    // If DC.tc.T2GPA = 1, translated requests are performed using a GPA. The IOMMU performs second-stage translation
                    else begin
                        // Stage 1 Bare
                        en_stage2       = ~second_stage_is_bare;
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
                        en_stage1       = ~first_stage_is_bare;
                        en_stage2       = ~second_stage_is_bare;
                        gscid           = ddtc_lu_content.iohgatp.gscid;
                        pscid           = ddtc_lu_content.ta.pscid;
                        iohgatp_ppn     = ddtc_lu_content.iohgatp.ppn;
                        iosatp_ppn      = ddtc_lu_content.fsc.ppn;
                        iotlb_access    = 1'b1;
                    end

                    // Process Context associated
                    else if (InclPID) begin
                        
                        // "If DPE is 0 and there is no process_id associated with the transaction, or if pdtp.MODE = Bare"
                        // "perform first-stage translation in Bare mode"
                        if ((!pid_v_i && !ddtc_lu_content.tc.dpe) || (ddtc_lu_content.fsc.mode == 4'b0000)) begin
                            // Stage 1 Bare
                            en_stage2       = ~second_stage_is_bare;
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

            //# PDTC Lookup
            if (InclPID) begin
                if (pdtc_lu_hit) begin
                    
                    // "Hold and stop if the transaction requests supervisor privilege but PC.ta.ENS is not set"
                    if (is_s_priv && !pdtc_lu_content.ta.ens) begin
                        cause_code    = iommu_pkg::TRANS_TYPE_DISALLOWED;
                        trans_error   = 1'b1;
                    end

                    else begin
                        en_stage1       = ~first_stage_is_bare;
                        en_stage2       = ~second_stage_is_bare;
                        gscid           = ddtc_lu_content.iohgatp.gscid;
                        pscid           = pdtc_lu_content.ta.pscid;
                        iohgatp_ppn     = ddtc_lu_content.iohgatp.ppn;
                        iosatp_ppn      = pdtc_lu_content.fsc.ppn;
                        iotlb_access    = 1'b1;
                    end
                end
            end

            //# IOTLB Lookup
            if (iotlb_lu_hit) begin
                
                trans_valid_o       = 1'b1;

                //# MSI addr entry
                if (iotlb_lu_is_msi && msi_enabled) begin
                    is_msi_o            = 1'b1;
                    // MSI PTEs contain the PPN in the same position as normal PTEs
                    translated_addr_o   = {iotlb_lu_g_content.ppn, iova_i[11:0]};
                end

                //# Normal entry
                // INFO: IOTLB should not have entries with both stages disabled and MSI flag clear. However, we double-check
                else if (en_stage1 || en_stage2) begin
                    /*
                    A fault is generated if:
                        - A bit is not set (checked in PTW);
                        - Page is not readable (checked in PTW);
                        - (1): Transaction is a store and page has not write permissions (D bit checked in PTW);
                        - (2): Transaction is read-for-execute and page has not X permissions;
                        - (3): U-mode transaction and PTE has U=0;
                        - (4): S-mode transaction and PTE has U=1 and (SUM=0 or x=1).
                    */
                    if ((is_store && ((!iotlb_lu_content.w && en_stage1) || (!iotlb_lu_g_content.w && en_stage2))   ) ||    // (1)
                        (is_rx && ((!iotlb_lu_content.x && en_stage1) || (!iotlb_lu_g_content.x && en_stage2))      ) ||    // (2)
                        ((priv_lvl_i == riscv::PRIV_LVL_U) && !iotlb_lu_content.u && en_stage1                      ) ||    // (3)
                        (is_s_priv && iotlb_lu_content.u && (!pdtc_lu_content.ta.sum || iotlb_lu_content.x)         )       // (4)
                        ) begin
                            if (is_store)   cause_code = iommu_pkg::STORE_PAGE_FAULT;
                            else            cause_code = iommu_pkg::LOAD_PAGE_FAULT;
                            trans_error   = 1'b1;
                            trans_valid_o   = 1'b0;
                    end 

                    //# Address Translation Found
                    else begin
                        
                        translated_addr_o = {((en_stage2) ? iotlb_lu_g_content.ppn : iotlb_lu_content.ppn), iova_i[11:0]};

                        // Apply superpage cases
                        if (en_stage1 && en_stage2) begin
                            case ({iotlb_lu_is_s_2M, iotlb_lu_is_s_1G, iotlb_lu_is_g_2M, iotlb_lu_is_g_1G})

                                // 1-S: 4k | 2-S: 2M:   {PPN[2], PPN[1],  GPPN[0], OFF}
                                4'b0010:    translated_addr_o[20:12] = iotlb_lu_content.ppn[20:12];

                                // 1-S: 2M | 2-S: 2M:   {PPN[2], PPN[1],  VPN[0],  OFF}
                                // 1-S: 1G | 2-S: 2M:   {PPN[2], PPN[1],  VPN[0],  OFF}
                                4'b1010, 4'b0110:   translated_addr_o[20:12] = iova_i[20:12];

                                // 1-S: 4k | 2-S: 1G:   {PPN[2], GPPN[1], GPPN[0], OFF}
                                4'b0001:    translated_addr_o[29:12] = iotlb_lu_content.ppn[29:12];

                                // 1-S: 1G | 2-S: 1G:   {PPN[2], VPN[1],  VPN[0],  OFF}
                                4'b0101:    translated_addr_o[29:12] = iova_i[29:12];

                                // 1-S: 2M | 2-S: 1G:   {PPN[2], GPPN[1], VPN[0],  OFF}
                                4'b1001:    translated_addr_o[29:12] = {iotlb_lu_content.ppn[29:21], iova_i[20:12]};
                                
                                default:;
                                    // 1-S: 4k | 2-S: 4k:   {PPN[2], PPN[1],  PPN[0],  OFF}
                                    // 1-S: 2M | 2-S: 4k:   {PPN[2], PPN[1],  PPN[0],  OFF}
                                    // 1-S: 1G | 2-S: 4k:   {PPN[2], PPN[1],  PPN[0],  OFF}
                            endcase
                        end

                        else begin
                            if (iotlb_lu_is_g_1G || iotlb_lu_is_s_1G)   translated_addr_o[29:12] = iova_i[29:12];
                            if (iotlb_lu_is_g_2M || iotlb_lu_is_s_2M)   translated_addr_o[20:12] = iova_i[20:12];
                        end
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

            // No stage is enabled and input address does not correspond to a MSI address
            // (This condition and an IOTLB hit should be mutually exclusive)
            // Input address is bypassed
            if (is_bare_translation) begin
                trans_valid_o       = 1'b1;
                translated_addr_o = iova_i[riscv::PLEN-1:0];
            end
        end

        //# Check for errors
        // If we had to walk memory is because we had a miss. As we had an exception,
        // the corresponding cache/TLB was not updated, and translation was never set to valid
        if (ptw_error || cdw_error || msi_write_error) begin
            cause_code    = (cdw_error) ? cdw_cause_code : ptw_cause_code;
            trans_error   = 1'b1;
        end
    end

endmodule