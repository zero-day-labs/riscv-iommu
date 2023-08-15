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

`include "riscv_pkg.sv"
`include "iommu_pkg.sv"
`include "axi_pkg.sv"
`include "ariane_axi_pkg.sv"
`include "ariane_axi_soc_pkg.sv"
`include "iommu_reg_pkg.sv"

module riscv_iommu #(
    parameter int unsigned  IOTLB_ENTRIES       = 4,
    parameter int unsigned  DDTC_ENTRIES        = 4,
    parameter int unsigned  PDTC_ENTRIES        = 4,

    // Include process_id
    parameter bit               InclPID             = 0,
    // Include AXI4 address boundary check
    parameter bit               InclBC              = 1,
    
    // Interrupt Generation Support
    parameter rv_iommu::igs_t   IGS                 = rv_iommu::WSI_ONLY,
    // Number of interrupt vectors supported
    parameter int unsigned      N_INT_VEC           = 16,
    // Number of Performance monitoring event counters (set to zero to disable HPM)
    parameter int unsigned      N_IOHPMCTR          = 0,     // max 31

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
    /// Regbus request struct type.
    parameter type  reg_req_t       = logic,
    /// Regbus response struct type.
    parameter type  reg_rsp_t       = logic,

    // DO NOT MODIFY MANUALLY
    parameter int unsigned LOG2_INTVEC = $clog2(N_INT_VEC)
) (
    input  logic clk_i,
    input  logic rst_ni,

    // Translation Request Interface (Slave)
    input  axi_req_t    dev_tr_req_i,
    output axi_rsp_t    dev_tr_resp_o,

    // Translation Completion Interface (Master)
    input  axi_rsp_t    dev_comp_resp_i,
    output axi_req_t    dev_comp_req_o,

    // Implicit Memory Accesses Interface (Master)
    input  axi_rsp_t    mem_resp_i,
    output axi_req_t    mem_req_o,

    // Programming Interface (Slave) (AXI4 + ATOP => Reg IF)
    input  axi_req_slv_t    prog_req_i,
    output axi_rsp_slv_t    prog_resp_o,

    output logic [(N_INT_VEC-1):0] wsi_wires_o
);

    // To trigger an address translation. Do NOT set if the requested AXI transaction exceeds a 4kiB address boundary
    logic   allow_request;

    // To classify transaction. Used by boundary check logic
    logic   ar_request, aw_request;

    // Transaction request parameters, selected from AW or AR
    logic [riscv::VLEN-1:0]         iova;
    logic [23:0]                    device_id;
    logic [rv_iommu::TTYP_LEN-1:0] trans_type;
    // AxBURST
    axi_pkg::burst_t                burst_type;
    // AxLEN
    axi_pkg::len_t                  burst_length;
    // AxSIZE
    axi_pkg::size_t                 n_bytes;

    // Translation output signals
    logic                           trans_valid;
    logic                           trans_error;
    logic [riscv::PLEN-1:0]         spaddr;
    logic                           iotlb_miss;
    logic                           ddt_walk;
    logic                           pdt_walk;
    logic                           s1_ptw;
    logic                           s2_ptw;
    logic [15:0]                    gscid;
    logic [19:0]                    pscid;

    // Boundary violation
    logic                           bound_violation;

    // AXI request bus used to intercept AxADDR and AxVALID parameters, and connect to the demux slave port
    ariane_axi_soc::req_t           axi_aux_req;

    // Memory-Mapped Register Interface connections
    iommu_reg_pkg::iommu_reg2hw_t   reg2hw;
    iommu_reg_pkg::iommu_hw2reg_t   hw2reg;

    logic                           cq_error_wen;
    logic                           fq_error_wen;
    logic [53:0]                    msi_addr_x[16];
    logic [31:0]                    msi_data_x[16];
    logic                           msi_vec_masked_x[16];

    // We must wait for the FQ to write a record for a given error before letting the error slave respond to a subsequent request
    logic                           is_fq_fifo_full;

    // Interrupt vectors
    logic [(LOG2_INTVEC-1):0]   intv[3];
    assign intv = '{
        reg2hw.icvec.civ.q,  // CQ
        reg2hw.icvec.fiv.q,  // FQ
        reg2hw.icvec.pmiv.q  // HPM
    };

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

    // Error slave AXI bus
    axi_req_t  error_req;
    axi_rsp_t  error_rsp;

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

    //# WSI Interrupt Generation
    if ((IGS == rv_iommu::WSI_ONLY) || (IGS == rv_iommu::BOTH)) begin : gen_wsi_ig_support
        
        iommu_wsi_ig #(
            .N_INT_VEC  (N_INT_VEC  ),
            .N_INT_SRCS (3          )
        ) i_iommu_wsi_ig (
            // fctl.wsi
            .wsi_en_i       (reg2hw.fctl.wsi.q  ),

            // ipsr
            .intp_i          ({reg2hw.ipsr.pmip.q,reg2hw.ipsr.fip.q,reg2hw.ipsr.cip.q}),

            // icvec
            .intv_i          (intv              ),

            // interrupt wires
            .wsi_wires_o    (wsi_wires_o        )
        );
    end

    // Hardwire WSI wires to 0
    else begin : gen_wsi_support_disabled
        assign wsi_wires_o  = '0;
    end

    iommu_translation_wrapper #(
        .IOTLB_ENTRIES      (IOTLB_ENTRIES      ),
        .DDTC_ENTRIES       (DDTC_ENTRIES       ),
        .PDTC_ENTRIES       (PDTC_ENTRIES       ),
        .N_INT_VEC          (N_INT_VEC          ),
        .InclPID            (InclPID            ),
        .IGS                (IGS                )
    ) i_translation_wrapper (
        .clk_i          (clk_i  ),
        .rst_ni         (rst_ni ),

        .req_trans_i    (allow_request & !is_fq_fifo_full),        // Trigger translation

        // Translation request data
        .device_id_i    (device_id  ),          // AxID
        .pid_v_i        (1'b0       ),          // We are not using process id by now
        .process_id_i   ('0         ),          // Set to zero
        .iova_i         (iova       ),          // AxADDR
        
        .trans_type_i   (trans_type         ),  // Always untranslated requests as PCIe is not implemented
        .priv_lvl_i     (riscv::PRIV_LVL_U  ),  // Always U-mode as we do not use process_id (See Spec)

        // Memory Bus
        .mem_resp_i     (mem_resp_i ),           // Simply connect AXI channels
        .mem_req_o      (mem_req_o  ),

        // From Regmap
        .capabilities_i (reg2hw.capabilities),
        .fctl_i         (reg2hw.fctl        ),
        .ddtp_i         (reg2hw.ddtp        ),
        // CQ
        .cqb_ppn_i      (reg2hw.cqb.ppn.q       ),
        .cqb_size_i     (reg2hw.cqb.log2sz_1.q  ),
        .cqh_i          (reg2hw.cqh.q           ),
        .cqh_o          (hw2reg.cqh.d           ),     // WE always set to 1
        .cqt_i          (reg2hw.cqt.q           ),
        // FQ
        .fqb_ppn_i      (reg2hw.fqb.ppn.q       ),
        .fqb_size_i     (reg2hw.fqb.log2sz_1.q  ),
        .fqh_i          (reg2hw.fqh.q           ),
        .fqt_i          (reg2hw.fqt.q           ),
        .fqt_o          (hw2reg.fqt.d           ),     // WE always set to 1
        // cqcsr
        .cq_en_i        (reg2hw.cqcsr.cqen.q        ),
        .cq_ie_i        (reg2hw.cqcsr.cie.q         ),
        .cq_mf_i        (reg2hw.cqcsr.cqmf.q        ),
        .cq_cmd_to_i    (reg2hw.cqcsr.cmd_to.q      ),    
        .cq_cmd_ill_i   (reg2hw.cqcsr.cmd_ill.q     ),
        .cq_fence_w_ip_i(reg2hw.cqcsr.fence_w_ip.q  ),
        .cq_mf_o        (hw2reg.cqcsr.cqmf.d        ),      // WE driven by cq_error_wen
        .cq_cmd_to_o    (hw2reg.cqcsr.cmd_to.d      ),
        .cq_cmd_ill_o   (hw2reg.cqcsr.cmd_ill.d     ),
        .cq_fence_w_ip_o(hw2reg.cqcsr.fence_w_ip.d  ),
        .cq_on_o        (hw2reg.cqcsr.cqon.d        ),      // WE always set to 1
        .cq_busy_o      (hw2reg.cqcsr.busy.d        ),
        // fqcsr
        .fq_en_i        (reg2hw.fqcsr.fqen.q),
        .fq_ie_i        (reg2hw.fqcsr.fie.q ),
        .fq_mf_i        (reg2hw.fqcsr.fqmf.q),
        .fq_of_i        (reg2hw.fqcsr.fqof.q),
        .fq_mf_o        (hw2reg.fqcsr.fqmf.d),      // WE driven by fq_error_wen
        .fq_of_o        (hw2reg.fqcsr.fqof.d),
        .fq_on_o        (hw2reg.fqcsr.fqon.d),      // WE always set to 1
        .fq_busy_o      (hw2reg.fqcsr.busy.d),
        // ipsr
        .cq_ip_i        (reg2hw.ipsr.cip.q),
        .fq_ip_i        (reg2hw.ipsr.fip.q),
        .hpm_ip_i       (reg2hw.ipsr.pmip.q),
        .cq_ip_o        (hw2reg.ipsr.cip.d),        // WE driven by itself
        .fq_ip_o        (hw2reg.ipsr.fip.d),        // WE driven by itself
        // icvec
        .civ_i          (reg2hw.icvec.civ.q),
        .fiv_i          (reg2hw.icvec.fiv.q),
        .pmiv_i         (reg2hw.icvec.pmiv.q),
        // msi_cfg_tbl
        .msi_addr_x_i       (msi_addr_x),
        .msi_data_x_i       (msi_data_x),
        .msi_vec_masked_x_i (msi_vec_masked_x),

        // To enable write of error bits to cqcsr and fqcsr
        .cq_error_wen_o     (cq_error_wen),
        .fq_error_wen_o     (fq_error_wen),

        .trans_valid_o      (trans_valid),  // Translation successfully completed
        .is_msi_o           (),             // Indicate whether the translated address is an MSI address
        .translated_addr_o  (spaddr),       // Translated address
        .trans_error_o      (trans_error),  // Translation error

        // to HPM
        .iotlb_miss_o       (iotlb_miss ),   // IOTLB miss
        .ddt_walk_o         (ddt_walk   ),
        .pdt_walk_o         (pdt_walk   ),
        .s1_ptw_o           (s1_ptw     ),
        .s2_ptw_o           (s2_ptw     ),
        .gscid_o            (gscid      ),
        .pscid_o            (pscid      ),

        .is_fq_fifo_full_o  (is_fq_fifo_full)
    );

    iommu_regmap_if #(
        .ADDR_WIDTH     (ADDR_WIDTH     ),
        .DATA_WIDTH     (DATA_WIDTH     ),
        .ID_WIDTH       (ID_SLV_WIDTH   ),
        .USER_WIDTH     (USER_WIDTH     ),
        .IGS            (IGS            ),
        .N_INT_VEC      (N_INT_VEC      ),
        .N_IOHPMCTR     (N_IOHPMCTR     ),
        .axi_req_t      (axi_req_slv_t  ),
        .axi_rsp_t      (axi_rsp_slv_t  ),
        .reg_req_t      (reg_req_t      ),
        .reg_rsp_t      (reg_rsp_t      )
    ) i_iommu_regmap_if (
        .clk_i          (clk_i          ),
        .rst_ni         (rst_ni         ),

        .prog_req_i     (prog_req_i     ),
        .prog_resp_o    (prog_resp_o    ),

        .reg2hw_o       (reg2hw         ),
        .hw2reg_i       (hw2reg         )
    );

    //# Hardware Performance Monitor
    if (N_IOHPMCTR > 0) begin : gen_hpm

        iommu_hpm #(
            // Number of Performance monitoring event counters (set to zero to disable HPM)
            .N_IOHPMCTR     (N_IOHPMCTR) // max 31
        ) i_iommu_hpm (
            .clk_i          (clk_i  ),
            .rst_ni         (rst_ni ),

            // Event indicators
            .tr_request_i   ( ar_request || aw_request ),
            .iotlb_miss_i   ( iotlb_miss               ),
            .ddt_walk_i     ( ddt_walk                 ),
            .pdt_walk_i     ( pdt_walk                 ),
            .s1_ptw_i       ( s1_ptw                   ),
            .s2_ptw_i       ( s2_ptw                   ),

            // ID filters
            .did_i          (device_id  ),     // device_id associated with event
            .pid_i          ('0         ),     // process_id associated with event
            .pscid_i        (pscid      ),     // PSCID 
            .gscid_i        (gscid      ),     // GSCID
            .pid_v_i        (1'b0       ),     // process_id is valid

            // from HPM registers
            .iocountinh_i   (reg2hw.iocountinh),    // inhibit 63-bit cycles counter
            .iohpmcycles_i  (reg2hw.iohpmcycles),   // clock cycle counter register
            .iohpmctr_i     (reg2hw.iohpmctr),      // event counters
            .iohpmevt_i     (reg2hw.iohpmevt),      // event configuration registers

            // to HPM registers
            .iohpmcycles_o  (hw2reg.iohpmcycles),   // clock cycle counter value
            .iohpmctr_o     (hw2reg.iohpmctr),      // event counters value
            .iohpmevt_o     (hw2reg.iohpmevt),      // event configuration registers

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

    //# Channel selection
    // Monitor incoming request and select parameters according to the source channel
    always_comb begin : channel_selection
        
        // Default values
        ar_request      = 1'b0;
        aw_request      = 1'b0;
        iova            = '0;
        device_id       = '0;
        trans_type      = rv_iommu::NONE;
        burst_type      = '0;
        burst_length    = '0;
        n_bytes         = '0;

        // AR request received (this way we are giving priority to read transactions)
        if (dev_tr_req_i.ar_valid) begin

            ar_request      =  1'b1;
            iova            =  dev_tr_req_i.ar.addr;
            device_id       =  dev_tr_req_i.ar.id;
            // ARPROT[2] indicates data access (r) when LOW, instruction access (rx) when HIGH
            trans_type      = (dev_tr_req_i.ar.prot[2]) ? (rv_iommu::UNTRANSLATED_RX) : (rv_iommu::UNTRANSLATED_R);
            burst_type      =  dev_tr_req_i.ar.burst;
            burst_length    =  dev_tr_req_i.ar.len;
            n_bytes         =  dev_tr_req_i.ar.size;
        end

        // AW request received
        else if (dev_tr_req_i.aw_valid) begin

            aw_request  = 1'b1;

            iova            = dev_tr_req_i.aw.addr;
            device_id       = dev_tr_req_i.aw.id;
            trans_type      = rv_iommu::UNTRANSLATED_W;
            burst_type      = dev_tr_req_i.aw.burst;
            burst_length    = dev_tr_req_i.aw.len;
            n_bytes         = dev_tr_req_i.aw.size;
        end
    end

    //# Boundary Check
    // In order to send error response, we need to set the corresponding valid signal and select the error slave in the AXI Demux.
    // To do that, we may OR the translation error flag from the translation wrapper with another flag to indicate a 4kiB cross
    // and trigger the error response
    if (InclBC) begin : gen_axi4_bc

        axi4_boundary_check i_axi4_boundary_check 
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
        .NoMstPorts     (2              ),
        .AxiLookBits    (ID_WIDTH       ),  // Assuming same value as AXI ID width
        .FallThrough    (1'b0           ),
        .SpillAw        (1'b0           ),
        .SpillW         (1'b0           ),
        .SpillB         (1'b0           ),
        .SpillAr        (1'b0           ),
        .SpillR         (1'b0           )
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