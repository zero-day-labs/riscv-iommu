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
// Date: 20/09/2023
// Acknowledges: SSRC - Technology Innovation Institute (TII)
//
// Description: RISC-V IOMMU Software Interface Wrapper.
//              Contains all modules from the software interface of the RISC-V IOMMU.
//              Register Map, HPM, CQ Handler, FQ Handler, WSI IG, MSI IG.

module rv_iommu_sw_if_wrapper #(

    // MSI translation support
    parameter rv_iommu::msi_trans_t MSITrans = rv_iommu::MSI_DISABLED,
    // Interrupt Generation Support
    parameter rv_iommu::igs_t       IGS = rv_iommu::WSI_ONLY,
    // Number of interrupt vectors supported
    parameter int unsigned          N_INT_VEC = 16,
    // Number of Performance monitoring event counters (set to zero to disable HPM)
    parameter int unsigned          N_IOHPMCTR = 0, // max 31
    // Include process_id support
    parameter bit                   InclPC = 0,
    // Include debug register interface
    parameter bit                   InclDBG = 0,

    /// AXI Full request struct type
    parameter type  axi_req_t       = logic,
    /// AXI Full response struct type
    parameter type  axi_rsp_t       = logic,
    /// Regbus request struct type.
    parameter type  reg_req_t = logic,
    /// Regbus response struct type.
    parameter type  reg_rsp_t = logic,

    // DO NOT MODIFY
    parameter int unsigned LOG2_INTVEC  = $clog2(N_INT_VEC)
) (
    input  logic clk_i,
    input  logic rst_ni,
    
    // From Prog IF
    input  reg_req_t regmap_req_i,
    output reg_rsp_t regmap_resp_o,

    // AXI ports directed to Data Structures Interface
    // CQ
    input  axi_rsp_t    cq_axi_resp_i,
    output axi_req_t    cq_axi_req_o,
    // FQ
    input  axi_rsp_t    fq_axi_resp_i,
    output axi_req_t    fq_axi_req_o,
    // MSI IG
    input  axi_rsp_t    msi_ig_axi_resp_i,
    output axi_req_t    msi_ig_axi_req_o,

    // Register values required by translation logic
    output rv_iommu_reg_pkg::iommu_reg2hw_capabilities_reg_t    capabilities_o,
    output rv_iommu_reg_pkg::iommu_reg2hw_fctl_reg_t            fctl_o,
    output rv_iommu_reg_pkg::iommu_reg2hw_ddtp_reg_t            ddtp_o,

    // Debug register IF
    output rv_iommu_reg_pkg::iommu_reg2hw_tr_req_iova_reg_t     dbg_if_iova_o,
    input  rv_iommu_reg_pkg::iommu_hw2reg_tr_response_reg_t     dbg_if_resp_i,
    output rv_iommu_reg_pkg::iommu_reg2hw_tr_req_ctl_reg_t      dbg_if_ctl_o,
    input  rv_iommu_reg_pkg::iommu_hw2reg_tr_req_ctl_reg_t      dbg_if_ctl_i,

    // IOATC Invalidation control (from CQ Handler to IOATC)
    // DDTC Invalidation
    output logic                        flush_ddtc_o,   // Flush DDTC
    output logic                        flush_dv_o,     // Indicates if device_id is valid
    output logic [23:0]                 flush_did_o,    // device_id to tag entries to be flushed
    // PDTC Invalidation
    output logic                        flush_pdtc_o,   // Flush PDTC
    output logic                        flush_pv_o,     // This is used to difference between IODIR.INVAL_DDT and IODIR.INVAL_PDT
    output logic [19:0]                 flush_pid_o,    // process_id to be flushed if PV = 1
    // IOTLB Invalidation
    output logic                        flush_vma_o,    // Flush first-stage PTEs cached entries in IOTLB
    output logic                        flush_gvma_o,   // Flush second-stage PTEs cached entries in IOTLB 
    output logic                        flush_av_o,     // Address valid
    output logic                        flush_gv_o,     // GSCID valid
    output logic                        flush_pscv_o,   // PSCID valid
    output logic [riscv::GPPNW-1:0]     flush_vpn_o,    // IOVA to tag entries to be flushed
    output logic [15:0]                 flush_gscid_o,  // GSCID (Guest physical address space identifier) to tag entries to be flushed
    output logic [19:0]                 flush_pscid_o,  // PSCID (Guest virtual address space identifier) to tag entries to be flushed
    
    // Request data
    input  logic [rv_iommu::TTYP_LEN-1:0]   trans_type_i,       // transaction type
    input  logic [23:0]                     did_i,              // device_id associated with the transaction
    input  logic                            pv_i,               // to indicate if transaction has a valid process_id
    input  logic [19:0]                     pid_i,              // process_id associated with the transaction
    input  logic [riscv::VLEN-1:0]          iova_i,             // IOVA associated with the request
    input  logic [15:0]                     gscid_i,            // GSCID
    input  logic [19:0]                     pscid_i,            // PSCID
    input  logic                            is_supervisor_i,    // indicate if transaction has supervisor privilege (only if pid valid)
    input  logic                            is_guest_pf_i,      // indicate if event is a guest page fault
    input  logic                            is_implicit_i,      // Guest page fault caused by implicit access for 1st-stage addr translation
    
    // Error signals
    input  logic                                report_fault_i, // To signal a translation fault/event
    input  logic [(rv_iommu::CAUSE_LEN-1):0]    cause_code_i,   // Fault code defined by translation logic
    input  logic [riscv::SVX-1:0]               bad_gpaddr_i,   // to report bits [63:2] of the GPA in case of a Guest Page Fault
    output logic                                msi_write_error_o,  // An error occurred when writing an MSI generated by the IOMMU

    // HPM Event flags
    input  logic tr_request_i,  // Untranslated Request
    input  logic iotlb_miss_i,  // IOTLB miss
    input  logic ddt_walk_i,    // DDT Walk (DDTC miss)
    input  logic pdt_walk_i,    // PDT Walk (PDTC miss)
    input  logic s1_ptw_i,      // First-stage PT walk
    input  logic s2_ptw_i,      // Second-stage PT walk

    // FQ FIFO is full
    output logic                    is_fq_fifo_full_o,

    // Interrupt wires
    output logic [(N_INT_VEC-1):0]  wsi_wires_o
);

    // Register values
    rv_iommu_reg_pkg::iommu_reg2hw_t 	reg2hw; 
    rv_iommu_reg_pkg::iommu_hw2reg_t 	hw2reg;

    // Register values required by translation logic
    assign capabilities_o   = reg2hw.capabilities;
    assign fctl_o           = reg2hw.fctl;
    assign ddtp_o           = reg2hw.ddtp;

    // Debug Interface registers
    assign dbg_if_iova_o        = reg2hw.tr_req_iova;
    assign dbg_if_ctl_o         = reg2hw.tr_req_ctl;
    assign hw2reg.tr_req_ctl    = dbg_if_ctl_i;         // Go/Busy bit
    assign hw2reg.tr_response   = dbg_if_resp_i;        // Response

    // WE signal for cqcsr/fqcsr error bits
    logic   cq_error_wen;
    logic   fq_error_wen;

    // To indicate if the IOMMU supports and uses WSI as interrupt generation mechanism
    logic   wsi_en;
    assign  wsi_en = (^reg2hw.capabilities.igs.q & reg2hw.fctl.wsi.q);

    // To indicate if the IOMMU supports and uses MSI as interrupt generation mechanism
    logic   msi_ig_en;
    assign  msi_ig_en = ((reg2hw.capabilities.igs.q inside {2'b00, 2'b10}) & (!reg2hw.fctl.wsi.q));

    // An error occurred when writing an MSI generated by the IOMMU
    logic msi_write_error;
    assign msi_write_error_o = msi_write_error;

    // WE signals
    assign  hw2reg.cqh.de               = 1'b1;
    assign  hw2reg.fqt.de               = 1'b1;
    assign  hw2reg.cqcsr.cqmf.de        = cq_error_wen;
    assign  hw2reg.cqcsr.cmd_to.de      = cq_error_wen;
    assign  hw2reg.cqcsr.cmd_ill.de     = cq_error_wen;
    assign  hw2reg.cqcsr.fence_w_ip.de  = cq_error_wen;
    assign  hw2reg.cqcsr.cqon.de        = 1'b1;
    assign  hw2reg.cqcsr.busy.de        = 1'b1;
    assign  hw2reg.fqcsr.fqmf.de        = fq_error_wen; 
    assign  hw2reg.fqcsr.fqof.de        = fq_error_wen;
    assign  hw2reg.fqcsr.fqon.de        = 1'b1;
    assign  hw2reg.fqcsr.busy.de        = 1'b1;
    assign  hw2reg.ipsr.cip.de          = hw2reg.ipsr.cip.d;
    assign  hw2reg.ipsr.fip.de          = hw2reg.ipsr.fip.d;
    assign  hw2reg.ipsr.pmip.de         = hw2reg.ipsr.pmip.d;

    // Interrupt vectors
    // Priority is defined by the order of the vector: The lower the index, the higher the priority
    logic [(LOG2_INTVEC-1):0]   intv[3];
    assign intv = '{
        reg2hw.icvec.civ.q[(LOG2_INTVEC-1):0],  // CQ
        reg2hw.icvec.fiv.q[(LOG2_INTVEC-1):0],  // FQ
        reg2hw.icvec.pmiv.q[(LOG2_INTVEC-1):0]  // HPM
    };

    // MSI config table registers wires
    logic [53:0]    msi_addr_x[16];
    logic [31:0]    msi_data_x[16];
    logic           msi_vec_masked_x[16];

    assign  msi_addr_x = '{
        reg2hw.msi_addr[0].addr.q,
        reg2hw.msi_addr[1].addr.q,
        reg2hw.msi_addr[2].addr.q,
        reg2hw.msi_addr[3].addr.q,
        reg2hw.msi_addr[4].addr.q,
        reg2hw.msi_addr[5].addr.q,
        reg2hw.msi_addr[6].addr.q,
        reg2hw.msi_addr[7].addr.q,
        reg2hw.msi_addr[8].addr.q,
        reg2hw.msi_addr[9].addr.q,
        reg2hw.msi_addr[10].addr.q,
        reg2hw.msi_addr[11].addr.q,
        reg2hw.msi_addr[12].addr.q,
        reg2hw.msi_addr[13].addr.q,
        reg2hw.msi_addr[14].addr.q,
        reg2hw.msi_addr[15].addr.q
    };

    assign  msi_data_x = '{
        reg2hw.msi_data[0].data.q,
        reg2hw.msi_data[1].data.q,
        reg2hw.msi_data[2].data.q,
        reg2hw.msi_data[3].data.q,
        reg2hw.msi_data[4].data.q,
        reg2hw.msi_data[5].data.q,
        reg2hw.msi_data[6].data.q,
        reg2hw.msi_data[7].data.q,
        reg2hw.msi_data[8].data.q,
        reg2hw.msi_data[9].data.q,
        reg2hw.msi_data[10].data.q,
        reg2hw.msi_data[11].data.q,
        reg2hw.msi_data[12].data.q,
        reg2hw.msi_data[13].data.q,
        reg2hw.msi_data[14].data.q,
        reg2hw.msi_data[15].data.q
    };

    assign  msi_vec_masked_x = '{
        reg2hw.msi_vec_ctl[0].m.q,
        reg2hw.msi_vec_ctl[1].m.q,
        reg2hw.msi_vec_ctl[2].m.q,
        reg2hw.msi_vec_ctl[3].m.q,
        reg2hw.msi_vec_ctl[4].m.q,
        reg2hw.msi_vec_ctl[5].m.q,
        reg2hw.msi_vec_ctl[6].m.q,
        reg2hw.msi_vec_ctl[7].m.q,
        reg2hw.msi_vec_ctl[8].m.q,
        reg2hw.msi_vec_ctl[9].m.q,
        reg2hw.msi_vec_ctl[10].m.q,
        reg2hw.msi_vec_ctl[11].m.q,
        reg2hw.msi_vec_ctl[12].m.q,
        reg2hw.msi_vec_ctl[13].m.q,
        reg2hw.msi_vec_ctl[14].m.q,
        reg2hw.msi_vec_ctl[15].m.q
    };

    //# Register map module
    rv_iommu_regmap #(
        .DATA_WIDTH     ( 32         ),
        .MSITrans       ( MSITrans   ),
        .IGS            ( IGS        ),
        .N_INT_VEC      ( N_INT_VEC  ),
        .N_IOHPMCTR     ( N_IOHPMCTR ),
        .InclPC         ( InclPC     ),
        .InclDBG        ( InclDBG    ),
        .reg_req_t      ( reg_req_t  ),
        .reg_rsp_t      ( reg_rsp_t  )
    ) i_rv_iommu_regmap (
        .clk_i      (clk_i),
        .rst_ni     (rst_ni),

        .reg_req_i  (regmap_req_i),
        .reg_rsp_o  (regmap_resp_o),

        .reg2hw     (reg2hw),
        .hw2reg     (hw2reg),
        
        .devmode_i  (1'b0)
    );

    //# Command Queue
    rv_iommu_cq_handler #(
        .axi_req_t      (axi_req_t  ),
        .axi_rsp_t      (axi_rsp_t  )
    ) i_rv_iommu_cq_handler (
        .clk_i                  (clk_i      ),
        .rst_ni                 (rst_ni     ),

        // Regmap
        .cq_base_ppn_i          (reg2hw.cqb.ppn.q       ),  // Base address of the CQ in memory (Should be aligned. See Spec)
        .cq_size_i              (reg2hw.cqb.log2sz_1.q  ),  // Size of the CQ as log2-1 (2 entries: 0 | 4 entries: 1 | 8 entries: 2 | ...)

        .cq_en_i                (reg2hw.cqcsr.cqen.q    ),  // CQ enable bit from cqcsr, handled by SW
        .cq_ie_i                (reg2hw.cqcsr.cie.q     ),  // CQ interrupt enable bit from cqcsr, handled by SW

        .cq_tail_i              (reg2hw.cqt.q           ),  // CQ tail index (SW writes the next CQ entry to cq_base + cq_tail * 16 bytes)
        .cq_head_i              (reg2hw.cqh.q           ),  // CQ head index (the IOMMU reads the next entry from cq_base + cq_head * 16 bytes)
        .cq_head_o              (hw2reg.cqh.d           ),

        .cq_on_o                (hw2reg.cqcsr.cqon.d    ), // CQ active bit. Indicates to SW whether the CQ is active or not
        .busy_o                 (hw2reg.cqcsr.busy.d    ), // CQ busy bit. Indicates SW that the CQ is in the middle of a state transition, 
                                                           //              so it has to wait to write to cqcsr.

        .cq_mf_i                (reg2hw.cqcsr.cqmf.q    ),  // Error bit status 
        .cmd_to_i               (reg2hw.cqcsr.cmd_to.q  ),    
        .cmd_ill_i              (reg2hw.cqcsr.cmd_ill.q ),
        .fence_w_ip_i           (reg2hw.cqcsr.fence_w_ip.q), 

        .error_wen_o            (cq_error_wen           ),  // To enable write of corresponding error bit to regmap
        .cq_mf_o                (hw2reg.cqcsr.cqmf.d    ),  // Set when a memory fault occurred during CQ access
        .cmd_to_o               (hw2reg.cqcsr.cmd_to.d  ),  // The execution of a command lead to a timeout
        .cmd_ill_o              (hw2reg.cqcsr.cmd_ill.d ),  // Illegal or unsupported command was fetched from CQ
        .fence_w_ip_o           (hw2reg.cqcsr.fence_w_ip.d),  // Set to indicate completion of an IOFENCE command
        .cq_ip_o                (hw2reg.ipsr.cip.d      ),  // To set cip bit in ipsr register if a fault occurs and cq_ie is set

        .wsi_en_i               (wsi_en         ),  // To know whether WSI generation is supported

        // DDTC Invalidation
        .flush_ddtc_o           (flush_ddtc_o   ),  // Flush DDTC
        .flush_dv_o             (flush_dv_o     ),  // Indicates if device_id is valid
        .flush_did_o            (flush_did_o    ),  // device_id to tag entries to be flushed

        // PDTC Invalidation
        .flush_pdtc_o           (flush_pdtc_o   ),  // Flush PDTC
        .flush_pv_o             (flush_pv_o     ),  // This is used to difference between IODIR.INVAL_DDT and IODIR.INVAL_PDT
        .flush_pid_o            (flush_pid_o    ),  // process_id to be flushed if PV = 1

        // IOTLB Invalidation
        .flush_vma_o            (flush_vma_o    ),  // Flush first-stage PTEs cached entries in IOTLB
        .flush_gvma_o           (flush_gvma_o   ),  // Flush second-stage PTEs cached entries in IOTLB 
        .flush_av_o             (flush_av_o     ),  // Address valid
        .flush_gv_o             (flush_gv_o     ),  // GSCID valid
        .flush_pscv_o           (flush_pscv_o   ),  // PSCID valid
        .flush_vpn_o            (flush_vpn_o    ),  // IOVA to tag entries to be flushed
        .flush_gscid_o          (flush_gscid_o  ),  // GSCID (Guest physical address space identifier) to tag entries to be flushed
        .flush_pscid_o          (flush_pscid_o  ),  // PSCID (Guest virtual address space identifier) to tag entries to be flushed

        // Memory Bus
        .mem_resp_i             (cq_axi_resp_i    ),
        .mem_req_o              (cq_axi_req_o     )
    );

    /* verilator lint_off WIDTH */
    //# Fault/Event Queue
    rv_iommu_fq_handler #(
        .axi_req_t      (axi_req_t  ),
        .axi_rsp_t      (axi_rsp_t  )
    ) i_rv_iommu_fq_handler ( 
        .clk_i                  (clk_i      ),
        .rst_ni                 (rst_ni     ),

        // Regmap
        .fq_base_ppn_i          (reg2hw.fqb.ppn.q       ),  // Base address of the FQ in memory (Should be aligned. See Spec)
        .fq_size_i              (reg2hw.fqb.log2sz_1.q  ),  // Size of the FQ as log2-1 (2 entries: 0 | 4 entries: 1 | 8 entries: 2 | ...)

        .fq_en_i                (reg2hw.fqcsr.fqen.q    ),  // FQ enable bit from fqcsr, handled by SW
        .fq_ie_i                (reg2hw.fqcsr.fie.q     ),  // FQ interrupt enable bit from fqcsr, handled by SW

        .fq_head_i              (reg2hw.fqh.q           ),  // FQ head index (SW reads the next entry from fq_base + fq_head * 32 bytes)
        .fq_tail_i              (reg2hw.fqt.q           ),  // FQ tail index (IOMMU writes the next FQ entry to fq_base + fq_tail * 32 bytes)
        .fq_tail_o              (hw2reg.fqt.d           ),

        .fq_on_o                (hw2reg.fqcsr.fqon.d    ),  // FQ active bit. Indicates to SW whether the FQ is active or not
        .busy_o                 (hw2reg.fqcsr.busy.d    ),  // FQ busy bit. Indicates SW that the FQ is in the middle of a state transition, 
                                                //              so it has to wait to write to fqcsr.

        .fq_mf_i                (reg2hw.fqcsr.fqmf.q    ),             
        .fq_of_i                (reg2hw.fqcsr.fqof.q    ),  

        .error_wen_o            (fq_error_wen           ),  // To enable write of corresponding error bit to regmap
        .fq_mf_o                (hw2reg.fqcsr.fqmf.d    ),  // Set when a memory fault occurred during FQ access
        .fq_of_o                (hw2reg.fqcsr.fqof.d    ),  // The execution of a command lead to a timeout 
        .fq_ip_o                (hw2reg.ipsr.fip.d      ),  // To set ipsr.fip register if a fault occurs and fq_ie is set

        // Event data
        .event_valid_i          (report_fault_i     ),  // a fault/event has occurred
        .trans_type_i           ((msi_write_error) ? ('0) : (trans_type_i)),                            // transaction type
        .cause_code_i           (cause_code_i),         // Fault code as defined by IOMMU and Priv Spec
        .iova_i                 ((msi_write_error) ? (msi_ig_axi_req_o.aw.addr[55:2]) : (iova_i)),            // to report if transaction has an IOVA
        .gpaddr_i               (bad_gpaddr_i       ),  // to report bits [63:2] of the GPA in case of a Guest Page Fault
        .did_i                  (did_i              ),  // device_id associated with the transaction
        .pv_i                   (pv_i               ),  // to indicate if transaction has a valid process_id
        .pid_i                  (pid_i              ),  // process_id associated with the transaction
        .is_supervisor_i        (is_supervisor_i    ),  // indicate if transaction has supervisor privilege
        .is_guest_pf_i          (is_guest_pf_i      ),  // indicate if event is a guest page fault
        .is_implicit_i          (is_implicit_i      ),  // Guest page fault caused by implicit access for 1st-stage addr translation

        // Memory Bus
        .mem_resp_i             (fq_axi_resp_i    ),
        .mem_req_o              (fq_axi_req_o     ),

        .is_full_o              (is_fq_fifo_full_o)
    );
    /* verilator lint_on WIDTH */

    //# MSI Interrupt Generation
    generate
        if ((IGS == rv_iommu::MSI_ONLY) || (IGS == rv_iommu::BOTH)) begin : gen_msi_ig_support

            rv_iommu_msi_ig #(
                .N_INT_VEC          (N_INT_VEC  ),
                .N_INT_SRCS         (3          ),

                .axi_req_t          (axi_req_t  ),
                .axi_rsp_t          (axi_rsp_t  )
            ) i_rv_iommu_msi_ig (
                .clk_i              (clk_i      ),
                .rst_ni             (rst_ni     ),

                .msi_ig_enabled_i   (msi_ig_en  ),

                // Indexes in IV and IP vectors must be consistent!
                // 2: HPM; 1: FQ; 0: CQ
                .intp_i             ({reg2hw.ipsr.pmip.q,reg2hw.ipsr.fip.q,reg2hw.ipsr.cip.q}),
                .intv_i             (intv       ),

                .msi_addr_x_i       (msi_addr_x       ),
                .msi_data_x_i       (msi_data_x       ),
                .msi_vec_masked_x_i (msi_vec_masked_x ),

                .msi_write_error_o  (msi_write_error  ),

                .mem_resp_i         (msi_ig_axi_resp_i),
                .mem_req_o          (msi_ig_axi_req_o )
            );
        end

        // Hardwire outputs to zero
        else begin
            assign  msi_write_error  = 1'b0;
            assign  msi_ig_axi_req_o = '0;
        end
    endgenerate

    //# Hardware Performance Monitor
    generate
    if (N_IOHPMCTR > 0) begin : gen_hpm

        rv_iommu_hpm #(
            // Number of Performance monitoring event counters (set to zero to disable HPM)
            .N_IOHPMCTR     (N_IOHPMCTR) // max 31
        ) i_rv_iommu_hpm (
            .clk_i          (clk_i  ),
            .rst_ni         (rst_ni ),

            // Event indicators
            .tr_request_i   ( tr_request_i ),   // Untranslated request
            .iotlb_miss_i   ( iotlb_miss_i ),   // IOTLB miss
            .ddt_walk_i     ( ddt_walk_i   ),   // DDT Walk (DDTC miss)
            .pdt_walk_i     ( pdt_walk_i   ),   // PDT Walk (PDTC miss)
            .s1_ptw_i       ( s1_ptw_i     ),   // first-stage PT walk
            .s2_ptw_i       ( s2_ptw_i     ),   // second-stage PT walk

            // ID filters
            .did_i          ( did_i   ),     // device_id associated with event
            .pid_i          ( pid_i   ),     // process_id associated with event
            .pscid_i        ( pscid_i ),     // PSCID 
            .gscid_i        ( gscid_i ),     // GSCID
            .pid_v_i        ( pv_i    ),     // process_id is valid

            // from HPM registers
            .iocountinh_i   (reg2hw.iocountinh              ),  // inhibit 63-bit cycles counter
            .iohpmcycles_i  (reg2hw.iohpmcycles             ),  // clock cycle counter register
            .iohpmctr_i     (reg2hw.iohpmctr[N_IOHPMCTR-1:0]),  // event counters
            .iohpmevt_i     (reg2hw.iohpmevt[N_IOHPMCTR-1:0]),  // event configuration registers

            // to HPM registers
            .iohpmcycles_o  (hw2reg.iohpmcycles             ),  // clock cycle counter value
            .iohpmctr_o     (hw2reg.iohpmctr[N_IOHPMCTR-1:0]),  // event counters value
            .iohpmevt_o     (hw2reg.iohpmevt[N_IOHPMCTR-1:0]),  // event configuration registers

            .hpm_ip_o       (hw2reg.ipsr.pmip.d)    // HPM IP bit. WE driven by itself
        );
    end : gen_hpm

    else begin : gen_hpm_disabled

        // hardwire outputs to 0
        assign hw2reg.iohpmcycles   = '0;
        assign hw2reg.iohpmctr      = '0;
        assign hw2reg.iohpmevt      = '0;
        assign hw2reg.ipsr.pmip.d   = '0;
    end : gen_hpm_disabled
    endgenerate

    //# WSI Interrupt Generation
    generate
    if ((IGS == rv_iommu::WSI_ONLY) || (IGS == rv_iommu::BOTH)) begin : gen_wsi_ig_support
        
        rv_iommu_wsi_ig #(
            .N_INT_VEC  (N_INT_VEC  ),
            .N_INT_SRCS (3          )
        ) i_rv_iommu_wsi_ig (
            // fctl.wsi
            .wsi_en_i   ( reg2hw.fctl.wsi.q ),

            // ipsr
            .intp_i     ( {reg2hw.ipsr.pmip.q,reg2hw.ipsr.fip.q,reg2hw.ipsr.cip.q} ),

            // icvec
            .intv_i     ( intv              ),

            // interrupt wires
            .wsi_wires_o( wsi_wires_o       )
        );
    end : gen_wsi_ig_support

    // Hardwire WSI wires to 0
    else begin : gen_wsi_support_disabled
        assign wsi_wires_o  = '0;
    end : gen_wsi_support_disabled
    endgenerate
    
endmodule