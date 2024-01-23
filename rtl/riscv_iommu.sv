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

    // Include process_id support
    parameter bit               InclPC          = 0,
    // Include MSI translation support
    parameter bit               InclMSITrans    = 0,
    // Include AXI4 address boundary check
    parameter bit               InclBC          = 0,
    
    // Interrupt Generation Support
    parameter rv_iommu::igs_t   IGS             = rv_iommu::WSI_ONLY,
    // Number of interrupt vectors supported
    parameter int unsigned      N_INT_VEC       = 16,
    // Number of Performance monitoring event counters (set to zero to disable HPM)
    parameter int unsigned      N_IOHPMCTR      = 0,     // max 31

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
    parameter type  axi_req_mmu_t   = logic,
    /// Regbus request struct type.
    parameter type  reg_req_t       = logic,
    /// Regbus response struct type.
    parameter type  reg_rsp_t       = logic
) (
    input  logic clk_i,
    input  logic rst_ni,

    // Translation Request Interface (Slave)
    input  axi_req_mmu_t    dev_tr_req_i,
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
    logic   allow_request;
    // The current transaction violates the AXI4 4-kiB address boundary limit
    logic bound_violation;

    // To classify transaction as read or write
    logic   ar_request, aw_request;

    // Transaction parameters
    logic [riscv::VLEN-1:0]         iova;
    logic [23:0]                    did;
    logic                           pv;
    logic [19:0]                    pid;
    logic [15:0]                    gscid;
    logic [19:0]                    pscid;
    logic [rv_iommu::TTYP_LEN-1:0]  trans_type;
    logic                           priv_lvl;

    // To calculate transaction size
    // AxBURST
    axi_pkg::burst_t                burst_type;
    // AxLEN
    axi_pkg::len_t                  burst_length;
    // AxSIZE
    axi_pkg::size_t                 n_bytes;

    // Translation output wires
    // Success
    logic                               trans_valid;    // translation success
    logic [riscv::PLEN-1:0]             spaddr;         // translated address
    // Error
    logic                               trans_error;    // translation error
    logic                               is_guest_pf;    // guest page fault occurred
    logic                               is_implicit;    // guest page fault caused by implicit access for 1st-stage translation
    logic                               report_fault;   // enable signal to report fault through FQ
    logic [(rv_iommu::CAUSE_LEN-1):0]   cause_code;     // fault code defined by translation logic
    logic [riscv::SVX-1:0]              bad_gpaddr;     // to report bits [63:2] of the GPA in case of a Guest Page Fault
    logic                               msi_write_error;    // An error occurred when writing an MSI generated by the IOMMU

    // HPM event flags wires
    logic iotlb_miss;
    logic ddt_walk;
    logic pdt_walk;
    logic s1_ptw;
    logic s2_ptw;

    // We must wait for the FQ to write a record for a given error before letting the error slave respond to a subsequent request
    logic is_fq_fifo_full;

    // IOATC flush wires
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

    // Register IF bus between Programming IF and SW IF wrapper
    reg_req_t   regmap_req;
    reg_rsp_t   regmap_resp;

    // AXI buses directed to Data Structures Interface
    // PTW
    axi_rsp_t   ptw_axi_resp;
    axi_req_t   ptw_axi_req;
    // CDW
    axi_rsp_t   cdw_axi_resp;
    axi_req_t   cdw_axi_req;
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

    // AW
    // AWVALID is set on translation success or when an error occurs
    /* 
        On success, the AXI demux connects the AXI bus to the Master IF. Since the translation is 
        triggered by the original AWVALID signal (when bound check is passed), it will remain set 
        until a handshake occurs. After the handshake, the translation request signal (driven by AWVALID)
        is cleared, and thus, the translation success bit will also go low.

        If a translation error occurs, or an address boundary violation is detected, AWVALID is set in the
        aux bus, but the demux is connected to the error slave, so this will respond to the device with an error msg.
        Similarly to the previous case, the error signal stays set until the AW handshake occurs.

        After the AW handshake, communication through AXI bus is directly handled by the AXI demux for W, R and B channels 
    */
    assign axi_aux_req.aw_valid                 = (trans_valid | (trans_error & !is_fq_fifo_full) | bound_violation) & aw_request;

    assign axi_aux_req.aw.id                    = dev_tr_req_i.aw.id;
    assign axi_aux_req.aw.addr[riscv::PLEN-1:0] = (aw_request & trans_valid) ? (spaddr) : ('0);  // translated address
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
    assign axi_aux_req.w            = dev_tr_req_i.w;
    assign axi_aux_req.w_valid      = dev_tr_req_i.w_valid;

    // B
    assign axi_aux_req.b_ready      = dev_tr_req_i.b_ready;

    // AR
    assign axi_aux_req.ar_valid                 = (trans_valid | (trans_error & !is_fq_fifo_full) | bound_violation) & ar_request;

    assign axi_aux_req.ar.id                    = dev_tr_req_i.ar.id;
    assign axi_aux_req.ar.addr[riscv::PLEN-1:0] = (ar_request & trans_valid) ? (spaddr) : ('0);  // translated address
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

        .clk_i          (clk_i),
        .rst_ni         (rst_ni),

        // To IOMMU ext port
        .ds_resp_i     (ds_resp_i),
        .ds_req_o      (ds_req_o),
        
        // From Translation logic wrapper
        // PTW
        .ptw_resp_o     (ptw_axi_resp),
        .ptw_req_i      (ptw_axi_req),

        // CDW
        .cdw_resp_o     (cdw_axi_resp),
        .cdw_req_i      (cdw_axi_req),

        // From SW Interface wrapper
        // CQ
        .cq_resp_o      (cq_axi_resp),
        .cq_req_i       (cq_axi_req),

        // FQ
        .fq_resp_o      (fq_axi_resp),
        .fq_req_i       (fq_axi_req),

        // MSI IG
        .msi_ig_resp_o  (msi_ig_axi_resp),
        .msi_ig_req_i   (msi_ig_axi_req)
    );

    //# Translation logic wrapper
    rv_iommu_translation_wrapper #(
        .IOTLB_ENTRIES  (IOTLB_ENTRIES),
        .DDTC_ENTRIES   (DDTC_ENTRIES ),
        .PDTC_ENTRIES   (PDTC_ENTRIES ),
        .InclPC         (InclPC       ),
        .InclMSITrans   (InclMSITrans ),

        .axi_req_t      (axi_req_t  ),
        .axi_rsp_t      (axi_rsp_t  )
    ) i_rv_iommu_translation_wrapper (
        .clk_i          (clk_i  ),
        .rst_ni         (rst_ni ),

        .req_trans_i    (allow_request & !is_fq_fifo_full), // Trigger translation

        // Translation request data
        .did_i          (did    ),  // AxMMUSID
        .pv_i           (pv     ),  // AxMMUSSIDV
        .pid_i          (pid    ),  // AxMMUSSID
        .iova_i         (iova   ),  // AxADDR
        .gscid_o        (gscid  ),  // GSCID
        .pscid_o        (pscid  ),  // PSCID
        
        .trans_type_i   (trans_type ),  // Transaction type
        .priv_lvl_i     (priv_lvl   ),  // Priviledge level (S/U)

        // AXI ports directed to Data Structures Interface
        // CDW
        .cdw_axi_resp_i (cdw_axi_resp),
        .cdw_axi_req_o  (cdw_axi_req),
        // PTW
        .ptw_axi_resp_i (ptw_axi_resp),
        .ptw_axi_req_o  (ptw_axi_req),

        // From Regmap
        .capabilities_i (capabilities),
        .fctl_i         (fctl        ),
        .ddtp_i         (ddtp        ),

        // Request status and output data
        .trans_valid_o      (trans_valid),  // Translation successfully completed
        .spaddr_o           (spaddr),       // Translated address
        .is_msi_o           (),             // Indicate whether the translated address is an MSI address
        // Error
        .trans_error_o      (trans_error),  // Translation error
        .report_fault_o     (report_fault), // To report fault through FQ
        .cause_code_o       (cause_code),   // Fault code defined by translation logic
        .is_guest_pf_o      (is_guest_pf),  // indicate if event is a guest page fault
        .is_implicit_o      (is_implicit),  // Guest page fault caused by implicit access for 1st-stage addr translation
        .bad_gpaddr_o       (bad_gpaddr),   // to report bits [63:2] of the GPA in case of a Guest Page Fault
        .msi_write_error_i  (msi_write_error), // An error occurred when writing an MSI generated by the IOMMU

        // HPM event flags from translation modules
        .iotlb_miss_o       (iotlb_miss ),  // IOTLB miss
        .ddt_walk_o         (ddt_walk   ),  // DDT Walk
        .pdt_walk_o         (pdt_walk   ),  // PDT Walk
        .s1_ptw_o           (s1_ptw     ),  // first-stage PTW
        .s2_ptw_o           (s2_ptw     ),  // second-stage PTW

        // IOATC Invalidation control
        // DDTC Invalidation
        .flush_ddtc_i       (flush_ddtc),   // Flush DDTC
        .flush_dv_i         (flush_dv),     // Indicates if device_id is valid
        .flush_did_i        (flush_did),    // device_id to tag entries to be flushed
        // PDTC Invalidation
        .flush_pdtc_i       (flush_pdtc),   // Flush PDTC
        .flush_pv_i         (flush_pv),     // This is used to difference between IODIR.INVAL_DDT and IODIR.INVAL_PDT
        .flush_pid_i        (flush_pid),    // process_id to be flushed if PV = 1
        // IOTLB Invalidation
        .flush_vma_i        (flush_vma),    // Flush first-stage PTEs cached entries in IOTLB
        .flush_gvma_i       (flush_gvma),   // Flush second-stage PTEs cached entries in IOTLB 
        .flush_av_i         (flush_av),     // Address valid
        .flush_gv_i         (flush_gv),     // GSCID valid
        .flush_pscv_i       (flush_pscv),   // PSCID valid
        .flush_vpn_i        (flush_vpn),    // IOVA to tag entries to be flushed
        .flush_gscid_i      (flush_gscid),  // GSCID (Guest physical address space identifier) to tag entries to be flushed
        .flush_pscid_i      (flush_pscid)   // PSCID (Guest virtual address space identifier) to tag entries to be flushed
    );

    //# Software Interface Wrapper
    rv_iommu_sw_if_wrapper #(
        .InclMSITrans   (InclMSITrans),
        .IGS            (IGS         ),
        .N_INT_VEC      (N_INT_VEC   ),
        .N_IOHPMCTR     (N_IOHPMCTR  ),

        .axi_req_t      (axi_req_t  ),
        .axi_rsp_t      (axi_rsp_t  ),
        .reg_req_t      (reg_req_t  ),
        .reg_rsp_t      (reg_rsp_t  )
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

        .capabilities_o     (capabilities),
        .fctl_o             (fctl),
        .ddtp_o             (ddtp),

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
        .trans_type_i       (trans_type),       // transaction type
        .did_i              (did),              // device_id associated with the transaction
        .pv_i               (pv),               // to indicate if transaction has a valid process_id
        .pid_i              (pid),              // process_id associated with the transaction
        .iova_i             (iova),             // IOVA associated with the request
        .gscid_i            (gscid),            // GSCID
        .pscid_i            (pscid),            // PSCID
        .is_supervisor_i    (priv_lvl),         // indicate if transaction has supervisor privilege (only if pid valid)
        .is_guest_pf_i      (is_guest_pf),      // indicate if event is a guest page fault
        .is_implicit_i      (is_implicit),      // Guest page fault caused by implicit access for 1st-stage addr translation
        
        // Error signals
        .report_fault_i     (report_fault),     // To signal a translation fault/event
        .cause_code_i       (cause_code),       // Fault code defined by translation logic
        .bad_gpaddr_i       (bad_gpaddr),       // to report bits [63:2] of the GPA in case of a Guest Page Fault
        .msi_write_error_o  (msi_write_error),  // An error occurred when writing an MSI generated by the IOMMU

        // HPM Event flags
        .tr_request_i       (ar_request | aw_request),  // Untranslated Request
        .iotlb_miss_i       (iotlb_miss             ),  // IOTLB miss
        .ddt_walk_i         (ddt_walk               ),  // DDT Walk (DDTC miss)
        .pdt_walk_i         (pdt_walk               ),  // PDT Walk (PDTC miss)
        .s1_ptw_i           (s1_ptw                 ),  // First-stage PT walk
        .s2_ptw_i           (s2_ptw                 ),  // Second-stage PT walk

        // FQ FIFO is full
        .is_fq_fifo_full_o  (is_fq_fifo_full),

        // Interrupt wires
        .wsi_wires_o        (wsi_wires_o)
    );

    //# Channel selection
    // Monitor incoming request and select parameters according to the source channel
    always_comb begin : channel_selection
        
        // Default values
        ar_request      = 1'b0;
        aw_request      = 1'b0;
        iova            = '0;
        did             = '0;
        pv              = 1'b0;
        pid             = '0;
        trans_type      = rv_iommu::NONE;
        priv_lvl        = 1'b0;
        burst_type      = '0;
        burst_length    = '0;
        n_bytes         = '0;

        // AR request received (this way we are giving priority to read transactions)
        if (dev_tr_req_i.ar_valid) begin

            ar_request      =  1'b1;

            // Tags
            iova            =  dev_tr_req_i.ar.addr;
            // AXI DVM extension for SMMU
            did             =  dev_tr_req_i.ar.stream_id;
            pv              =  dev_tr_req_i.ar.ss_id_valid;
            pid             =  dev_tr_req_i.ar.substream_id;
            // ARPROT[2] indicates data access (r) when LOW, instruction access (rx) when HIGH
            trans_type      = (dev_tr_req_i.ar.prot[2]) ? (rv_iommu::UNTRANSLATED_RX) : (rv_iommu::UNTRANSLATED_R);
            priv_lvl        =  dev_tr_req_i.ar.prot[0]; // AxPROT[0] indicates privileged transaction (supervisor lvl) when set
            burst_type      =  dev_tr_req_i.ar.burst;
            burst_length    =  dev_tr_req_i.ar.len;
            n_bytes         =  dev_tr_req_i.ar.size;
        end

        // AW request received
        else if (dev_tr_req_i.aw_valid) begin

            aw_request  = 1'b1;

            // Tags
            iova            =  dev_tr_req_i.aw.addr;
            // AXI DVM extension for SMMU
            did             =  dev_tr_req_i.aw.stream_id;
            pv              =  dev_tr_req_i.aw.ss_id_valid;
            pid             =  dev_tr_req_i.aw.substream_id;

            trans_type      =  rv_iommu::UNTRANSLATED_W;
            priv_lvl        =  dev_tr_req_i.aw.prot[0];
            burst_type      =  dev_tr_req_i.aw.burst;
            burst_length    =  dev_tr_req_i.aw.len;
            n_bytes         =  dev_tr_req_i.aw.size;
        end
    end

    //# Boundary Check
    // In order to send error response, we need to set the corresponding valid signal and select the error slave in the AXI Demux.
    // To do that, we may OR the translation error flag from the translation wrapper with another flag to indicate a 4kiB cross
    // and trigger the error response
    generate
    if (InclBC) begin : gen_axi4_bc

        rv_iommu_axi4_bc i_rv_iommu_axi4_bc
        (
            // AxVALID
            .request_i          (ar_request | aw_request),
            // AxADDR
            .addr_i             ( iova                  ),
            // AxBURST
            .burst_type_i       ( burst_type            ),
            // AxLEN
            .burst_length_i     ( burst_length          ),
            // AxSIZE
            .n_bytes_i          ( n_bytes               ),

            // To indicate valid requests or boundary violations
            .allow_request_o    ( allow_request         ),
            .bound_violation_o  ( bound_violation       )
        );
    end : gen_axi4_bc

    // AXI4 boundaru checks may be performed outside the IOMMU IP.
    // In this scenario, there's no need to include this logic.
    else begin : gen_axi4_bc_disabled

        assign allow_request   = (ar_request | aw_request);
        assign bound_violation = 1'b0;
    end : gen_axi4_bc_disabled
    endgenerate

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
        .NoMstPorts     ( 2             ),
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
        .test_i         ( 1'b0   ),         // if 1, explicit error return for unmapped register access
        .slv_aw_select_i( trans_valid & aw_request     ),
        .slv_ar_select_i( trans_valid & ar_request     ),
        .slv_req_i      ( axi_aux_req                  ),
        .slv_resp_o     ( dev_tr_resp_o                ),
        .mst_reqs_o     ( {dev_comp_req_o, error_req}  ),  // { 1: mst, 0: error }
        .mst_resps_i    ( {dev_comp_resp_i, error_rsp} )   // { 1: mst, 0: error }
    );

    axi_err_slv #(
      .AxiIdWidth   (ID_WIDTH               ),
      .req_t        (axi_req_t              ),
      .resp_t       (axi_rsp_t              ),
      .Resp         (axi_pkg::RESP_SLVERR   ),      // error generated by this slave
      .RespWidth    (DATA_WIDTH             ),      // data response width, gets zero extended or truncated to r.data.
      .RespData     (64'hCA11AB1EBADCAB1E   ),      // hexvalue for data return value
      .ATOPs        (1'b1),                         // Activate support for ATOPs.
      .MaxTrans     (1)                             // Maximum # of accepted transactions before stalling
  ) i_axi_err_slv (
      .clk_i        (clk_i      ),
      .rst_ni       (rst_ni     ),
      .test_i       (1'b0       ),
      .slv_req_i    (error_req  ),
      .slv_resp_o   (error_rsp  )
  );

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