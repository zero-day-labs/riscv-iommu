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
// Date: 02/03/2023
// Acknowledges: SSRC - Technology Innovation Institute (TII)
//
// Description: RISC-V IOMMU Top Module.

/* verilator lint_off WIDTH */

module riscv_iommu #(
    // Number of IOTLB entries
    parameter int unsigned  IOTLB_ENTRIES       = 4,
    // Number of DDTC entries
    parameter int unsigned  DDTC_ENTRIES        = 4,
    // Number of PDTC entries
    parameter int unsigned  PDTC_ENTRIES        = 4,
    // Number of MRIF cache entries (if supported)
    parameter int unsigned  MRIFC_ENTRIES       = 4,

    // Include process_id support
    parameter bit                   InclPC      = 0,
    // Include AXI4 address boundary check
    parameter bit                   InclBC      = 0,
    // Include debug register interface
    parameter bit                   InclDBG     = 0,
    
    // MSI translation support
    parameter rv_iommu::msi_trans_t MSITrans    = rv_iommu::MSI_DISABLED,
    // Interrupt Generation Support
    parameter rv_iommu::igs_t       IGS         = rv_iommu::WSI_ONLY,
    // Number of interrupt vectors supported
    parameter int unsigned          N_INT_VEC   = 16,
    // Number of Performance monitoring event counters (set to zero to disable HPM)
    parameter int unsigned          N_IOHPMCTR  = 0,     // max 31

    /// AXI Bus Addr width.
    parameter int   ADDR_WIDTH      = -1,
    /// AXI Bus data width.
    parameter int   DATA_WIDTH      = -1,
    /// AXI ID width
    parameter int   ID_WIDTH        = -1,
    /// AXI ID width
    parameter int   ID_SLV_WIDTH    = -1,
    /// AXI user width
    parameter int   USER_WIDTH      = 1,
    /// AXI AW Channel struct type
    parameter type aw_chan_t        = logic,
    /// AXI W Channel struct type
    parameter type w_chan_t         = logic,
    /// AXI B Channel struct type
    parameter type b_chan_t         = logic,
    /// AXI AR Channel struct type
    parameter type ar_chan_t        = logic,
    /// AXI R Channel struct type
    parameter type r_chan_t         = logic,
    /// AXI Full request struct type
    parameter type  axi_req_t       = logic,
    /// AXI Full response struct type
    parameter type  axi_rsp_t       = logic,
    /// AXI Full Slave request struct type
    parameter type  axi_req_slv_t   = logic,
    /// AXI Full Slave response struct type
    parameter type  axi_rsp_slv_t   = logic,
    /// AXI Full request struct type w/ DVM extension for SMMU
    parameter type  axi_req_iommu_t = logic,
    /// Regbus request struct type.
    parameter type  reg_req_t       = logic,
    /// Regbus response struct type.
    parameter type  reg_rsp_t       = logic
) (
    input  logic clk_i,
    input  logic rst_ni,

    // Translation Request Interface (Slave)
    input  axi_req_iommu_t  dev_tr_req_i,
    output axi_rsp_t        dev_tr_resp_o,

    // Translation Completion Interface (Master)
    input  axi_rsp_t        dev_comp_resp_i,
    output axi_req_t        dev_comp_req_o,

    // Data Structures Interface (Master)
    input  axi_rsp_t        ds_resp_i,
    output axi_req_t        ds_req_o,

    // Programming Interface (Slave) (AXI4 + ATOP => Reg IF)
    input  axi_req_slv_t    prog_req_i,
    output axi_rsp_slv_t    prog_resp_o,

    output logic [(N_INT_VEC-1):0] wsi_wires_o
);

    // To trigger an address translation. Only set after verifying AXI4 boundary limits
    logic   request_ongoing;
    // The current transaction violates the AXI4 4-kiB address boundary limit
    logic   bound_violation;
    // A debug translation is ongoing
    logic   dbg_ongoing_q, dbg_ongoing_n;

    // To classify transaction as read or write
    enum logic [1:0] {
        IDLE,
        READ,
        WRITE
    } request_type_q, request_type_n;

    // Transaction parameters
    // Final parameters. Selected between AR/AW requests and DBG IF requests
    logic [riscv::VLEN-1:0]         iova;
    logic [23:0]                    did;
    logic                           pv;
    logic [19:0]                    pid;
    logic [rv_iommu::TTYP_LEN-1:0]  ttype;
    logic                           priv;
    // AR/AW requests parameters
    logic [riscv::VLEN-1:0]         trans_iova;
    logic [23:0]                    trans_did;
    logic                           trans_pv;
    logic [19:0]                    trans_pid;
    logic [rv_iommu::TTYP_LEN-1:0]  trans_type;
    logic                           trans_priv;

    logic [15:0]                    gscid;
    logic [19:0]                    pscid;

    // AXI size parameters. To boundary check logic
    // AxBURST
    axi_pkg::burst_t                burst_type;
    // AxLEN
    axi_pkg::len_t                  burst_length;
    // AxSIZE
    axi_pkg::size_t                 n_bytes;

    // Translation output wires
    // Success
    logic                               trans_valid;        // Translation process successfully finished
    logic [riscv::PLEN-1:0]             spaddr;             // Translated address
    logic                               is_superpage;       // The PTW fetched a PTE representing a superpage
    // Error
    logic                               trans_error;        // Translation process finished with an error
    logic                               is_guest_pf;        // The PTW detected a guest page fault
    logic                               is_implicit;        // The guest page fault was caused by implicit access for 1st-stage translation
    logic                               report_fault;       // enable signal to report fault through FQ
    logic [(rv_iommu::CAUSE_LEN-1):0]   cause_code;         // Code of the occurred fault
    logic [riscv::SVX-1:0]              bad_gpaddr;         // GPA that caused the GPF. Sent through FQ
    logic                               msi_write_error;    // An error occurred when writing an MSI generated by the IOMMU
    // Ignore (discard)
    logic                               ignore_request;     // Ignore request. Set AxVALID with the AXI demux connected to the resp slave

    // HPM event flags wires
    logic iotlb_miss;
    logic ddt_walk;
    logic pdt_walk;
    logic s1_ptw;
    logic s2_ptw;

    // If the FQ FIFO is full and a fault occurs, we must wait until there is space in the FIFO before setting AxVALID.
    // Otherwise, the parameters of the faulting transaction are lost
    logic is_fq_fifo_full;

    // IOATC flush wires. CQ -> IOATCs
    logic                       flush_ddtc;
    logic                       flush_dv;
    logic [23:0]                flush_did;

    logic                       flush_pdtc;
    logic                       flush_pv;
    logic [19:0]                flush_pid;

    logic                       flush_vma;
    logic                       flush_gvma;
    logic                       flush_av;
    logic                       flush_gv;
    logic                       flush_pscv;
    logic [riscv::GPPNW-1:0]    flush_vpn;
    logic [15:0]                flush_gscid;
    logic [19:0]                flush_pscid;

    // Register wires required by translation logic
    rv_iommu_reg_pkg::iommu_reg2hw_capabilities_reg_t   capabilities;
    rv_iommu_reg_pkg::iommu_reg2hw_fctl_reg_t           fctl;
    rv_iommu_reg_pkg::iommu_reg2hw_ddtp_reg_t           ddtp;

    // Debug Interface register wires
    rv_iommu_reg_pkg::iommu_reg2hw_tr_req_iova_reg_t    dbg_if_iova;
    rv_iommu_reg_pkg::iommu_hw2reg_tr_response_reg_t    dbg_if_resp;
    rv_iommu_reg_pkg::iommu_reg2hw_tr_req_ctl_reg_t     dbg_if_ctl;
    rv_iommu_reg_pkg::iommu_hw2reg_tr_req_ctl_reg_t     dbg_if_ctl_busy;

    // Register IF bus between Programming IF and SW IF wrapper (Regmap)
    reg_req_t   regmap_req;
    reg_rsp_t   regmap_resp;

    // AXI buses directed to Data Structures Interface
    // PTW
    axi_rsp_t   ptw_axi_resp;
    axi_req_t   ptw_axi_req;
    // CDW
    axi_rsp_t   cdw_axi_resp;
    axi_req_t   cdw_axi_req;
    // MSI PTW
    axi_rsp_t   msiptw_axi_resp;
    axi_req_t   msiptw_axi_req;
    // MRIF handler
    axi_rsp_t   mrif_handler_axi_resp;
    axi_req_t   mrif_handler_axi_req;
    // CQ
    axi_rsp_t   cq_axi_resp;
    axi_req_t   cq_axi_req;
    // FQ
    axi_rsp_t   fq_axi_resp;
    axi_req_t   fq_axi_req;
    // MSI IG
    axi_rsp_t   msi_ig_axi_resp;
    axi_req_t   msi_ig_axi_req;

    // AXI request bus used to intercept AxADDR and AxVALID parameters, and connect to the demux slave port
    axi_req_t   axi_aux_req;

    // Error slave AXI bus
    axi_req_t   error_req;
    axi_rsp_t   error_rsp;

    // Transaction output logic
    logic [1:0] demux_aw_select_n, demux_aw_select_q;
    logic [1:0] demux_ar_select_n, demux_ar_select_q;

    // Gather all possible outputs and resume AXI translation request
    logic   resume_aw_n, resume_aw_q;
    logic   resume_ar_n, resume_ar_q;

    // Connect the aux AXI bus to the translation request interface
    // AW
    assign axi_aux_req.aw_valid                 = resume_aw_q;

    assign axi_aux_req.aw.id                    = dev_tr_req_i.aw.id;
    assign axi_aux_req.aw.addr[riscv::PLEN-1:0] = spaddr;                   // translated address
    assign axi_aux_req.aw.len                   = dev_tr_req_i.aw.len;
    assign axi_aux_req.aw.size                  = dev_tr_req_i.aw.size;
    assign axi_aux_req.aw.burst                 = dev_tr_req_i.aw.burst;
    assign axi_aux_req.aw.lock                  = dev_tr_req_i.aw.lock;
    assign axi_aux_req.aw.cache                 = dev_tr_req_i.aw.cache;
    assign axi_aux_req.aw.prot                  = dev_tr_req_i.aw.prot;
    assign axi_aux_req.aw.qos                   = dev_tr_req_i.aw.qos;
    assign axi_aux_req.aw.region                = dev_tr_req_i.aw.region;
    assign axi_aux_req.aw.atop                  = dev_tr_req_i.aw.atop;
    assign axi_aux_req.aw.user                  = dev_tr_req_i.aw.user;

    // W
    assign axi_aux_req.w                        = dev_tr_req_i.w;
    assign axi_aux_req.w_valid                  = dev_tr_req_i.w_valid;

    // B
    assign axi_aux_req.b_ready                  = dev_tr_req_i.b_ready;

    // AR
    assign axi_aux_req.ar_valid                 = resume_ar_q;

    assign axi_aux_req.ar.id                    = dev_tr_req_i.ar.id;
    assign axi_aux_req.ar.addr[riscv::PLEN-1:0] = spaddr;                   // translated address
    assign axi_aux_req.ar.len                   = dev_tr_req_i.ar.len;
    assign axi_aux_req.ar.size                  = dev_tr_req_i.ar.size;
    assign axi_aux_req.ar.burst                 = dev_tr_req_i.ar.burst;
    assign axi_aux_req.ar.lock                  = dev_tr_req_i.ar.lock;
    assign axi_aux_req.ar.cache                 = dev_tr_req_i.ar.cache;
    assign axi_aux_req.ar.prot                  = dev_tr_req_i.ar.prot;
    assign axi_aux_req.ar.qos                   = dev_tr_req_i.ar.qos;
    assign axi_aux_req.ar.region                = dev_tr_req_i.ar.region;
    assign axi_aux_req.ar.user                  = dev_tr_req_i.ar.user;

    // R
    assign axi_aux_req.r_ready                  = dev_tr_req_i.r_ready;

    // Select transaction parameters source: TR request / DBG IF
    // Priority is given to normal translations
    // If a debug translation is ongoing and a normal translation is triggered, we wait for the debug translation to complete.
    generate
        
    /*
        DBG IF support is included. When tr_req_ctl.go is set by SW and no normal request is being processed, 
        transaction parameters are taken from the DBG IF registers. Otherwise, transaction parameters are taken from AXI bus
        A single bit register is set when a DBG translation is started, and cleared when finished
    */
    if (InclDBG) begin : gen_dbg_if

        always_comb begin

            // Response registers
            dbg_if_resp.fault.d     = trans_error;
            dbg_if_resp.pbmt.d      = '0;
            dbg_if_resp.s.d         = is_superpage;
            dbg_if_resp.ppn.d       = spaddr[riscv::PLEN-1:12];

            dbg_if_resp.fault.de    = 1'b0;
            dbg_if_resp.pbmt.de     = 1'b0;
            dbg_if_resp.s.de        = 1'b0;
            dbg_if_resp.ppn.de      = 1'b0;

            // To indicate completion
            dbg_if_ctl_busy.go.d    = 1'b0;
            dbg_if_ctl_busy.go.de   = 1'b0;

            dbg_ongoing_n           = dbg_ongoing_q;

            // DBG IF request received and no normal translation is starting / ongoing
            if (dbg_if_ctl.go.q & ~(request_ongoing | dev_tr_req_i.ar_valid | dev_tr_req_i.aw_valid)) begin

                // Indicate that a debug translation is ongoing
                dbg_ongoing_n = 1'b1;
                
                // Set translation parameters from DBG IF registers
                iova    = {dbg_if_iova.vpn.q, 12'b0};
                did     = dbg_if_ctl.did.q;
                pv      = dbg_if_ctl.pv.q;
                pid     = dbg_if_ctl.pid.q;
                priv    = dbg_if_ctl.priv.q;

                // RWX values
                case ({dbg_if_ctl.exe.q, dbg_if_ctl.nw.q})
                    2'b00: ttype = rv_iommu::UNTRANSLATED_W;
                    2'b01: ttype = rv_iommu::UNTRANSLATED_R;
                    2'b10: ttype = rv_iommu::UNTRANSLATED_RX;
                    2'b11: ttype = rv_iommu::UNTRANSLATED_RX;
                endcase

                // Debug request finished
                if (trans_valid | trans_error) begin
                    
                    // Update response register
                    dbg_if_resp.fault.de    = 1'b1;
                    dbg_if_resp.s.de        = 1'b1;
                    dbg_if_resp.ppn.de      = 1'b1;

                    // Clear busy register to indicate completion
                    dbg_if_ctl_busy.go.de   = 1'b1;

                    // Clear control flag
                    dbg_ongoing_n           = 1'b0;
                end
            end

            // Normal translation request
            else begin
                
                iova    = trans_iova;
                did     = trans_did;
                pv      = trans_pv;
                pid     = trans_pid;
                ttype   = trans_type;
                priv    = trans_priv;
            end
        end

        always_ff @(posedge clk_i or negedge rst_ni) begin
            if (~rst_ni) begin
                dbg_ongoing_q   <= 1'b0;
            end

            else begin
                dbg_ongoing_q   <= dbg_ongoing_n;
            end
            
        end
    end : gen_dbg_if
        
    /*
        DBG IF support is not included. Transaction parameters are taken from the TR IF
    */
    else begin : gen_dbg_if_disabled
        
        assign iova                     = trans_iova;
        assign did                      = trans_did;
        assign pv                       = trans_pv;
        assign pid                      = trans_pid;
        assign ttype                    = trans_type;
        assign priv                     = trans_priv;

        assign dbg_if_resp.fault.d      = 1'b0;
        assign dbg_if_resp.pbmt.d       = '0;
        assign dbg_if_resp.s.d          = 1'b0;
        assign dbg_if_resp.ppn.d        = '0;

        assign dbg_if_resp.fault.de     = 1'b0;
        assign dbg_if_resp.pbmt.de      = 1'b0;
        assign dbg_if_resp.s.de         = 1'b0;
        assign dbg_if_resp.ppn.de       = 1'b0;

        assign dbg_if_ctl_busy.go.d     = 1'b0;
        assign dbg_if_ctl_busy.go.de    = 1'b0;

        assign dbg_ongoing_q            = 1'b0;
        assign dbg_ongoing_n            = 1'b0;
        
    end : gen_dbg_if_disabled
    endgenerate

    //# Programming Interface
    rv_iommu_prog_if #(
        .ADDR_WIDTH     (ADDR_WIDTH     ),
        .DATA_WIDTH     (DATA_WIDTH     ),
        .ID_WIDTH       (ID_SLV_WIDTH   ),
        .USER_WIDTH     (USER_WIDTH     ),
        .axi_req_t      (axi_req_slv_t  ),
        .axi_rsp_t      (axi_rsp_slv_t  ),
        .reg_req_t      (reg_req_t      ),
        .reg_rsp_t      (reg_rsp_t      )
    ) i_rv_iommu_prog_if (
        .clk_i          (clk_i          ),
        .rst_ni         (rst_ni         ),

        // From IOMMU ext port
        .prog_req_i     (prog_req_i     ),
        .prog_resp_o    (prog_resp_o    ),

        // To SW interface wrapper
        .regmap_req_o   (regmap_req     ),
        .regmap_resp_i  (regmap_resp    )
    );

    //# Data Structures Interface
    rv_iommu_ds_if #(
        .aw_chan_t      ( aw_chan_t ),
		.w_chan_t       ( w_chan_t	),
		.b_chan_t       ( b_chan_t	),
		.ar_chan_t      ( ar_chan_t ),
		.r_chan_t       ( r_chan_t	),
        .axi_req_t      ( axi_req_t ),
        .axi_rsp_t      ( axi_rsp_t )
    ) i_rv_iommu_ds_if (

        .clk_i                  (clk_i),
        .rst_ni                 (rst_ni),

        // To IOMMU ext port
        .ds_resp_i              (ds_resp_i),
        .ds_req_o               (ds_req_o),
        
        // From Translation logic wrapper
        // PTW
        .ptw_resp_o             (ptw_axi_resp),
        .ptw_req_i              (ptw_axi_req),

        // CDW
        .cdw_resp_o             (cdw_axi_resp),
        .cdw_req_i              (cdw_axi_req),

        // MSI PTW
        .msiptw_resp_o          (msiptw_axi_resp),
        .msiptw_req_i           (msiptw_axi_req),

        // MRIF handler
        .mrif_handler_resp_o    (mrif_handler_axi_resp),
        .mrif_handler_req_i     (mrif_handler_axi_req),

        // From SW Interface wrapper
        // CQ
        .cq_resp_o              (cq_axi_resp),
        .cq_req_i               (cq_axi_req),

        // FQ
        .fq_resp_o              (fq_axi_resp),
        .fq_req_i               (fq_axi_req),

        // MSI IG
        .msi_ig_resp_o          (msi_ig_axi_resp),
        .msi_ig_req_i           (msi_ig_axi_req)
    );

    //# Translation logic wrapper
    rv_iommu_translation_wrapper #(
        .IOTLB_ENTRIES  (IOTLB_ENTRIES),
        .DDTC_ENTRIES   (DDTC_ENTRIES ),
        .PDTC_ENTRIES   (PDTC_ENTRIES ),
        .MRIFC_ENTRIES  (MRIFC_ENTRIES),
        .InclPC         (InclPC       ),
        .MSITrans       (MSITrans     ),

        .axi_req_t      (axi_req_t  ),
        .axi_rsp_t      (axi_rsp_t  )
    ) i_rv_iommu_translation_wrapper (
        .clk_i          (clk_i  ),
        .rst_ni         (rst_ni ),

        .req_trans_i    (request_ongoing),                    // Trigger normal translation (if no DBG translation is ongoing)
        .req_dbg_i      (dbg_if_ctl.go.q & ~request_ongoing), // Trigger debug translation  (if no normal translation is ongoing)

        // Translation request data
        .did_i          (did        ),  // AxMMUSID / DBG IF
        .pv_i           (pv         ),  // AxMMUSSIDV / DBG IF
        .pid_i          (pid        ),  // AxMMUSSID / DBG IF
        .iova_i         (iova       ),  // AxADDR / DBG IF
        .gscid_o        (gscid      ),  // GSCID
        .pscid_o        (pscid      ),  // PSCID
        
        .trans_type_i   (ttype      ),  // Transaction type
        .priv_lvl_i     (priv       ),  // Priviledge level (S/U)

        // AXI ports directed to Data Structures Interface
        // CDW
        .cdw_axi_resp_i         (cdw_axi_resp   ),
        .cdw_axi_req_o          (cdw_axi_req    ),
        // PTW
        .ptw_axi_resp_i         (ptw_axi_resp   ),
        .ptw_axi_req_o          (ptw_axi_req    ),
        // MSI PTW
        .msiptw_axi_resp_i      (msiptw_axi_resp),
        .msiptw_axi_req_o       (msiptw_axi_req ),
        // MRIF handler
        .mrif_handler_axi_resp_i(mrif_handler_axi_resp  ),
        .mrif_handler_axi_req_o (mrif_handler_axi_req   ),

        // From Regmap
        .capabilities_i     (capabilities   ),
        .fctl_i             (fctl           ),
        .ddtp_i             (ddtp           ),

        // Request status and output data
        .trans_valid_o      (trans_valid),  // Translation successfully completed
        .spaddr_o           (spaddr),       // Translated address
        .is_superpage_o     (is_superpage), // Superpage PTE (used by DBG IF)
        // Error
        .trans_error_o      (trans_error    ),  // Translation error
        .report_fault_o     (report_fault   ),  // Report fault through FQ
        .cause_code_o       (cause_code     ),  // Fault code in case of error
        .is_guest_pf_o      (is_guest_pf    ),  // Guest page fault detected by PTW
        .is_implicit_o      (is_implicit    ),  // Guest page fault caused by implicit access for 1st-stage addr translation
        .bad_gpaddr_o       (bad_gpaddr     ),  // to report GPA in case of a Guest Page Fault (to FQ)
        .msi_write_error_i  (msi_write_error),  // An error occurred when writing an MSI generated by the IOMMU

        // HPM event flags from translation modules
        .iotlb_miss_o       (iotlb_miss ),  // IOTLB miss
        .ddt_walk_o         (ddt_walk   ),  // DDT Walk
        .pdt_walk_o         (pdt_walk   ),  // PDT Walk
        .s1_ptw_o           (s1_ptw     ),  // first-stage PTW
        .s2_ptw_o           (s2_ptw     ),  // second-stage PTW

        // IOATC Invalidation control
        // DDTC Invalidation
        .flush_ddtc_i       (flush_ddtc     ),  // Flush DDTC
        .flush_dv_i         (flush_dv       ),  // Indicates if device_id is valid
        .flush_did_i        (flush_did      ),  // device_id to tag entries to be flushed
        // PDTC Invalidation
        .flush_pdtc_i       (flush_pdtc     ),  // Flush PDTC
        .flush_pv_i         (flush_pv       ),  // This is used to difference between IODIR.INVAL_DDT and IODIR.INVAL_PDT
        .flush_pid_i        (flush_pid      ),  // process_id to be flushed if PV = 1
        // IOTLB Invalidation
        .flush_vma_i        (flush_vma      ),  // Flush first-stage PTEs cached entries in IOTLB
        .flush_gvma_i       (flush_gvma     ),  // Flush second-stage PTEs cached entries in IOTLB 
        .flush_av_i         (flush_av       ),  // Address valid
        .flush_gv_i         (flush_gv       ),  // GSCID valid
        .flush_pscv_i       (flush_pscv     ),  // PSCID valid
        .flush_vpn_i        (flush_vpn      ),  // IOVA to tag entries to be flushed
        .flush_gscid_i      (flush_gscid    ),  // GSCID (Guest physical address space identifier) to tag entries to be flushed
        .flush_pscid_i      (flush_pscid    ),  // PSCID (Guest virtual address space identifier) to tag entries to be flushed

        // MRIF Control
        .ignore_request_o   (ignore_request             ),  // Ignore AXI request, as the transaction was to an MRIF
        .msi_data_valid_i   (dev_tr_req_i.w_valid       ),  // Data present in AWDATA is valid (for MRIF purposes)
        .msi_data_i         (dev_tr_req_i.w.data[31:0]  )   // MSI data
    );

    //# Software Interface Wrapper
    rv_iommu_sw_if_wrapper #(
        .MSITrans           (MSITrans   ),
        .IGS                (IGS        ),
        .N_INT_VEC          (N_INT_VEC  ),
        .N_IOHPMCTR         (N_IOHPMCTR ),
        .InclPC             (InclPC     ),
        .InclDBG            (InclDBG    ),
        .axi_req_t          (axi_req_t  ),
        .axi_rsp_t          (axi_rsp_t  ),
        .reg_req_t          (reg_req_t  ),
        .reg_rsp_t          (reg_rsp_t  )
    ) i_rv_iommu_sw_if_wrapper (
        .clk_i              (clk_i),
        .rst_ni             (rst_ni),
        
        // From Prog IF
        .regmap_req_i       (regmap_req),
        .regmap_resp_o      (regmap_resp),

        // AXI ports directed to Data Structures Interface
        // CQ
        .cq_axi_resp_i      (cq_axi_resp),
        .cq_axi_req_o       (cq_axi_req),
        // FQ
        .fq_axi_resp_i      (fq_axi_resp),
        .fq_axi_req_o       (fq_axi_req),
        // MSI IG
        .msi_ig_axi_resp_i  (msi_ig_axi_resp),
        .msi_ig_axi_req_o   (msi_ig_axi_req),

        // Registers required by translation logic
        .capabilities_o     (capabilities),
        .fctl_o             (fctl),
        .ddtp_o             (ddtp),

        // DBG IF registers
        .dbg_if_iova_o      (dbg_if_iova),
        .dbg_if_resp_i      (dbg_if_resp),
        .dbg_if_ctl_o       (dbg_if_ctl),
        .dbg_if_ctl_i       (dbg_if_ctl_busy),

        // IOATC Invalidation control
        // DDTC Invalidation
        .flush_ddtc_o       (flush_ddtc),   // Flush DDTC
        .flush_dv_o         (flush_dv),     // Indicates if device_id is valid
        .flush_did_o        (flush_did),    // device_id to tag entries to be flushed
        // PDTC Invalidation
        .flush_pdtc_o       (flush_pdtc),   // Flush PDTC
        .flush_pv_o         (flush_pv),     // This is used to difference between IODIR.INVAL_DDT and IODIR.INVAL_PDT
        .flush_pid_o        (flush_pid),    // process_id to be flushed if PV = 1
        // IOTLB Invalidation
        .flush_vma_o        (flush_vma),    // Flush first-stage PTEs cached entries in IOTLB
        .flush_gvma_o       (flush_gvma),   // Flush second-stage PTEs cached entries in IOTLB 
        .flush_av_o         (flush_av),     // Address valid
        .flush_gv_o         (flush_gv),     // GSCID valid
        .flush_pscv_o       (flush_pscv),   // PSCID valid
        .flush_vpn_o        (flush_vpn),    // IOVA to tag entries to be flushed
        .flush_gscid_o      (flush_gscid),  // GSCID (Guest physical address space identifier) to tag entries to be flushed
        .flush_pscid_o      (flush_pscid),  // PSCID (Guest virtual address space identifier) to tag entries to be flushed

        // Request data
        .trans_type_i       (ttype),            // transaction type
        .did_i              (did),              // device_id associated with the transaction
        .pv_i               (pv),               // to indicate if transaction has a valid process_id
        .pid_i              (pid),              // process_id associated with the transaction
        .iova_i             (iova),             // IOVA associated with the request
        .gscid_i            (gscid),            // GSCID
        .pscid_i            (pscid),            // PSCID
        .is_supervisor_i    (priv),             // indicate if transaction has supervisor privilege (only if pid valid)
        .is_guest_pf_i      (is_guest_pf),      // indicate if event is a guest page fault
        .is_implicit_i      (is_implicit),      // Guest page fault caused by implicit access for 1st-stage addr translation
        
        // Error signals
        .report_fault_i     (report_fault),     // To signal a translation fault/event
        .cause_code_i       (cause_code),       // Fault code defined by translation logic
        .bad_gpaddr_i       (bad_gpaddr),       // to report bits [63:2] of the GPA in case of a Guest Page Fault
        .msi_write_error_o  (msi_write_error),  // An error occurred when writing an MSI generated by the IOMMU

        // HPM Event flags
        .tr_request_i       ( (request_type_q != IDLE) | dbg_ongoing_q  ),  // Untranslated Request (DBG IF requests included)
        .iotlb_miss_i       ( iotlb_miss                                ),  // IOTLB miss
        .ddt_walk_i         ( ddt_walk                                  ),  // DDT Walk (DDTC miss)
        .pdt_walk_i         ( pdt_walk                                  ),  // PDT Walk (PDTC miss)
        .s1_ptw_i           ( s1_ptw                                    ),  // First-stage PT walk
        .s2_ptw_i           ( s2_ptw                                    ),  // Second-stage PT walk

        // FQ FIFO is full
        .is_fq_fifo_full_o  (is_fq_fifo_full),

        // Interrupt wires
        .wsi_wires_o        (wsi_wires_o)
    );

    //# Boundary Check
    // In order to send error response, we need to set the corresponding valid signal and select the error slave in the AXI Demux.
    // To do that, we may OR the translation error flag from the translation wrapper with another flag to indicate a 4kiB cross
    // and trigger the error response
    generate
    if (InclBC) begin : gen_axi4_bc

        rv_iommu_axi4_bc i_rv_iommu_axi4_bc
        (
            // AxVALID
            .request_i          (request_type_q != IDLE),
            // AxADDR
            .addr_i             ( trans_iova            ),
            // AxBURST
            .burst_type_i       ( burst_type            ),
            // AxLEN
            .burst_length_i     ( burst_length          ),
            // AxSIZE
            .n_bytes_i          ( n_bytes               ),

            // To indicate valid requests or boundary violations
            .allow_request_o    ( request_ongoing       ),
            .bound_violation_o  ( bound_violation       )
        );
    end : gen_axi4_bc

    // AXI4 boundary checks may be performed outside the IOMMU IP.
    // In this scenario, there's no need to include this logic.
    else begin : gen_axi4_bc_disabled

        assign request_ongoing   = (request_type_q != IDLE);
        assign bound_violation = 1'b0;
    end : gen_axi4_bc_disabled
    endgenerate

    // Connect slaves to AXI demux
    // Depends on MRIF support
    generate
    // Generate transaction ignoring mechanism
    if (MSITrans == rv_iommu::MSI_FLAT_MRIF) begin : gen_mrif_support

        // Bus to ignore (discard) requests
        axi_req_t   ignore_req;
        axi_rsp_t   ignore_rsp;

        // AXI Success / Abort / Error AXI demux
        axi_demux #(
            .AxiIdWidth     (ID_WIDTH       ),
            // AXI channel structs
            .aw_chan_t      ( aw_chan_t     ),
            .w_chan_t       ( w_chan_t      ),
            .b_chan_t       ( b_chan_t      ),
            .ar_chan_t      ( ar_chan_t     ),
            .r_chan_t       ( r_chan_t      ),
            // AXI request/response
            .req_t          ( axi_req_t     ),
            .resp_t         ( axi_rsp_t     ),
            .NoMstPorts     ( 3             ),  // MRIF supports adds ignoring mechanism
            .AxiLookBits    ( ID_WIDTH      ),  // Assuming same value as AXI ID width
            .FallThrough    ( 1'b0          ),
            .SpillAw        ( 1'b0          ),
            .SpillW         ( 1'b0          ),
            .SpillB         ( 1'b0          ),
            .SpillAr        ( 1'b0          ),
            .SpillR         ( 1'b0          )
        ) i_iommu_axi_demux (
            .clk_i          ( clk_i  ),
            .rst_ni         ( rst_ni ),
            .test_i         ( 1'b0   ),
            .slv_aw_select_i( demux_aw_select_q ),
            .slv_ar_select_i( demux_ar_select_q ),
            .slv_req_i      ( axi_aux_req       ),
            .slv_resp_o     ( dev_tr_resp_o     ),
            .mst_reqs_o     ( {ignore_req, dev_comp_req_o, error_req}  ),  // { 2: ignore slave (MRIF), 1: comp IF, 0: error slave }
            .mst_resps_i    ( {ignore_rsp, dev_comp_resp_i, error_rsp} )   // { 2: ignore slave (MRIF), 1: comp IF, 0: error slave }
        );

        axi_err_slv #(
            .AxiIdWidth   (ID_WIDTH           ),
            .req_t        (axi_req_t          ),
            .resp_t       (axi_rsp_t          ),
            .Resp         (axi_pkg::RESP_OKAY ),  // this slave responds with OKAY to continue MRIF transactions
            .RespWidth    (DATA_WIDTH         ),  // data response width, gets zero extended or truncated to r.data.
            .RespData     (64'h0              ),  // return zero for reads
            .ATOPs        (1'b1),                 // Activate support for ATOPs.
            .MaxTrans     (1)                     // Maximum # of accepted transactions before stalling
        ) i_iommu_axi_ignore_slv (
            .clk_i        (clk_i      ),
            .rst_ni       (rst_ni     ),
            .test_i       (1'b0       ),
            .slv_req_i    (ignore_req ),
            .slv_resp_o   (ignore_rsp )
        );
    end : gen_mrif_support

    // Do not generate transaction ignoring mechanism
    else begin : gen_mrif_support_disabled

        // AXI Success / Error AXI demux
        axi_demux #(
            .AxiIdWidth     (ID_WIDTH       ),
            // AXI channel structs
            .aw_chan_t      ( aw_chan_t     ),
            .w_chan_t       ( w_chan_t      ),
            .b_chan_t       ( b_chan_t      ),
            .ar_chan_t      ( ar_chan_t     ),
            .r_chan_t       ( r_chan_t      ),
            // AXI request/response
            .req_t          ( axi_req_t     ),
            .resp_t         ( axi_rsp_t     ),
            .NoMstPorts     ( 2             ),  // MRIF supports adds ignoring mechanism
            .AxiLookBits    ( ID_WIDTH      ),  // Assuming same value as AXI ID width
            .FallThrough    ( 1'b0          ),
            .SpillAw        ( 1'b0          ),
            .SpillW         ( 1'b0          ),
            .SpillB         ( 1'b0          ),
            .SpillAr        ( 1'b0          ),
            .SpillR         ( 1'b0          )
        ) i_iommu_axi_demux (
            .clk_i          ( clk_i  ),
            .rst_ni         ( rst_ni ),
            .test_i         ( 1'b0   ),
            .slv_aw_select_i( demux_aw_select_q[0]  ),
            .slv_ar_select_i( demux_ar_select_q[0]  ),
            .slv_req_i      ( axi_aux_req           ),
            .slv_resp_o     ( dev_tr_resp_o         ),
            .mst_reqs_o     ( {dev_comp_req_o, error_req}   ),  // { 1: comp IF, 0: error slave }
            .mst_resps_i    ( {dev_comp_resp_i, error_rsp}  )   // { 1: comp IF, 0: error slave }
        );
    end : gen_mrif_support_disabled
    endgenerate

    // IOMMU Error Slave
    axi_err_slv #(
        .AxiIdWidth   (ID_WIDTH               ),
        .req_t        (axi_req_t              ),
        .resp_t       (axi_rsp_t              ),
        .Resp         (axi_pkg::RESP_SLVERR   ),      // error generated by this slave
        .RespWidth    (DATA_WIDTH             ),      // data response width, gets zero extended or truncated to r.data.
        .RespData     (64'hCA11AB1EBADCAB1E   ),      // hexvalue for data return value
        .ATOPs        (1'b1),                         // Activate support for ATOPs.
        .MaxTrans     (1)                             // Maximum # of accepted transactions before stalling
    ) i_iommu_axi_err_slv (
        .clk_i        (clk_i      ),
        .rst_ni       (rst_ni     ),
        .test_i       (1'b0       ),
        .slv_req_i    (error_req  ),
        .slv_resp_o   (error_rsp  )
  );

  //# Transaction control
    // Monitor incoming request and select parameters according to the source channel
    always_comb begin : transaction_control_comb
        
        // Default values
        request_type_n  = request_type_q;

        demux_aw_select_n   = demux_aw_select_q;
        demux_ar_select_n   = demux_ar_select_q;
        resume_aw_n         = resume_aw_q;
        resume_ar_n         = resume_ar_q;

        trans_iova      = '0;
        trans_did       = '0;
        trans_pv        = 1'b0;
        trans_pid       = '0;
        trans_type      = rv_iommu::NONE;
        trans_priv      = 1'b0;

        burst_type      = '0;
        burst_length    = '0;
        n_bytes         = '0;

        case (request_type_q)
            IDLE: begin
                
                // AR request received (this way we are giving priority to read transactions)
                if (dev_tr_req_i.ar_valid & ~dbg_ongoing_q) begin
                    request_type_n  = READ;
                end

                // AW request received
                else if (dev_tr_req_i.aw_valid & ~dbg_ongoing_q) begin
                    request_type_n  = WRITE;
                end
            end

            READ: begin
                
                // Tags
                trans_iova      =  dev_tr_req_i.ar.addr;
                // AXI DVM extension for SMMU
                trans_did       =  dev_tr_req_i.ar.stream_id;
                trans_pv        =  dev_tr_req_i.ar.ss_id_valid;
                trans_pid       =  dev_tr_req_i.ar.substream_id;
                // ARPROT[2] indicates data access (r) when LOW, instruction access (rx) when HIGH
                trans_type      = (dev_tr_req_i.ar.prot[2]) ? (rv_iommu::UNTRANSLATED_RX) : (rv_iommu::UNTRANSLATED_R);
                trans_priv      =  dev_tr_req_i.ar.prot[0]; // AxPROT[0] indicates privileged transaction (supervisor lvl) when set

                burst_type      =  dev_tr_req_i.ar.burst;
                burst_length    =  dev_tr_req_i.ar.len;
                n_bytes         =  dev_tr_req_i.ar.size;
                    
                // Successful translation. Connect AXI demux to Comp IF
                if (trans_valid) begin
                    resume_ar_n         = 1'b1;
                    demux_ar_select_n   = 2'b01;
                end

                // Translation / boundary error. Connect AXI demux to err slave 
                else if ((trans_error & !is_fq_fifo_full) || bound_violation) begin
                    resume_ar_n         = 1'b1;
                    demux_ar_select_n   = 2'b00;
                end

                // MRIF transaction Connect AXI demux to ignore slave 
                else if (ignore_request) begin
                    resume_ar_n         = 1'b1;
                    demux_ar_select_n   = 2'b10;
                end

                // We need to wait for ARREADY to go high
                if (dev_tr_resp_o.ar_ready) begin
                    request_type_n      = IDLE;
                    resume_ar_n         = 1'b0;
                end
            end

            WRITE: begin
                
                // Tags
                trans_iova      =  dev_tr_req_i.aw.addr;
                // AXI DVM extension for SMMU
                trans_did       =  dev_tr_req_i.aw.stream_id;
                trans_pv        =  dev_tr_req_i.aw.ss_id_valid;
                trans_pid       =  dev_tr_req_i.aw.substream_id;
                trans_type      =  rv_iommu::UNTRANSLATED_W;
                trans_priv      =  dev_tr_req_i.aw.prot[0];

                burst_type      =  dev_tr_req_i.aw.burst;
                burst_length    =  dev_tr_req_i.aw.len;
                n_bytes         =  dev_tr_req_i.aw.size;
                    
                // Successful translation. Connect AXI demux to Comp IF
                if (trans_valid) begin
                    resume_aw_n         = 1'b1;
                    demux_aw_select_n   = 2'b01;
                end

                // Translation / boundary error. Connect AXI demux to err slave 
                else if ((trans_error & !is_fq_fifo_full) || bound_violation) begin
                    resume_aw_n         = 1'b1;
                    demux_aw_select_n   = 2'b00;
                end

                // MRIF transaction Connect AXI demux to ignore slave 
                else if (ignore_request) begin
                    resume_aw_n         = 1'b1;
                    demux_aw_select_n   = 2'b10;
                end

                // We need to wait for AWREADY to go high
                if (dev_tr_resp_o.aw_ready) begin
                    request_type_n      = IDLE;
                    resume_aw_n         = 1'b0;
                end
            end

            default: request_type_n  = IDLE;
        endcase
    end : transaction_control_comb

    // Sequential logic for transaction control
    always_ff @(posedge clk_i or negedge rst_ni) begin : transaction_control_seq
        if (~rst_ni) begin
            resume_aw_q         <= 1'b0;
            resume_ar_q         <= 1'b0;
            demux_aw_select_q   <= 1'b0;
            demux_ar_select_q   <= 1'b0;
            request_type_q      <= IDLE;
        end

        else begin

            resume_aw_q         <= resume_aw_n;
            resume_ar_q         <= resume_ar_n;
            demux_aw_select_q   <= demux_aw_select_n;
            demux_ar_select_q   <= demux_ar_select_n;
            request_type_q      <= request_type_n;
        end
    end : transaction_control_seq

    //pragma translate_off
    `ifndef VERILATOR

    initial begin : p_assertions
        assert ((IGS == rv_iommu::WSI_ONLY) || (IGS == rv_iommu::MSI_ONLY) || (IGS == rv_iommu::BOTH))
        else begin $error("RISC-V IOMMU: At least one Interrupt Generation method must be supported (WSI/MSI)."); $stop(); end

        assert ((ADDR_WIDTH >= 1) && (DATA_WIDTH >= 1) && (ID_WIDTH >= 1) && (ID_SLV_WIDTH >= 1) && (USER_WIDTH >= 1))
        else begin $error("RISC-V IOMMU: Invalid AXI parameter width"); $stop(); end

        assert ((N_INT_VEC == 1) || (N_INT_VEC == 2) || (N_INT_VEC == 4) || (N_INT_VEC == 8) || (N_INT_VEC == 16))
        else begin $error("RISC-V IOMMU: Number of interrupt vectors MUST be a power of two and max 16"); $stop(); end

        assert (N_IOHPMCTR <= 31)
        else begin $error("RISC-V IOMMU: HPM may only support up to 31 event counters."); $stop(); end
    end

    `endif
    //pragma translate_on
    
endmodule

/* verilator lint_off WIDTH */