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
    Date: 02/03/2023

    Description: RISC-V IOMMU Top Module.
*/

module riscv_iommu #(
    parameter int unsigned  IOTLB_ENTRIES       = 4,
    parameter int unsigned  DDTC_ENTRIES        = 4,
    parameter int unsigned  PDTC_ENTRIES        = 4,
    parameter int unsigned  DEVICE_ID_WIDTH     = 24,
    parameter int unsigned  PROCESS_ID_WIDTH    = 20,
    parameter int unsigned  PSCID_WIDTH         = 20,
    parameter int unsigned  GSCID_WIDTH         = 16,

    // Include process_id
    parameter bit           InclPID             = 0,
    // Include IOMMU WSI generation support
    parameter bit           InclWSI_IG          = 1,
    // Include IOMMU MSI generation support
    parameter bit           InclMSI_IG          = 0,

    /// AXI Bus Addr width.
    parameter int   ADDR_WIDTH      = -1,
    /// AXI Bus data width.
    parameter int   DATA_WIDTH      = -1,
    /// AXI ID width
    parameter int   ID_WIDTH        = -1,
    /// AXI user width
    parameter int   USER_WIDTH      = -1,
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
    /// AXI-Lite request struct type.
    parameter type  axi_lite_req_t  = logic,
    /// AXI-Lite response struct type.
    parameter type  axi_lite_resp_t = logic,
    /// Regbus request struct type.
    parameter type  reg_req_t       = logic,
    /// Regbus response struct type.
    parameter type  reg_rsp_t       = logic
) (
    input  logic clk_i,
    input  logic rst_ni,

    // Translation Request Interface (Slave)
    input  axi_req_t    dev_tr_req_i,
    output axi_rsp_t    dev_tr_resp_o,

    // Translation Completion Interface (Master)
    input  axi_req_t    dev_comp_resp_i,
    output axi_rsp_t    dev_comp_req_o,

    // Implicit Memory Accesses Interface (Master)
    input  axi_req_t    mem_resp_i,
    output axi_rsp_t    mem_req_o,

    // Programming Interface (Slave) (AXI4 Full -> AXI4-Lite -> Reg IF)
    input  axi_req_t    prog_req_i,
    output axi_rsp_t    prog_resp_o,

    output logic [15:0] wsi_wires_o
);

    // To trigger an address translation. Do NOT set if the requested AXI transaction exceeds a 4kiB address boundary
    logic   allow_request;

    // To classify transaction. Used by boundary check logic
    logic   ar_request, aw_request;

    // Transaction request parameters, selected from AW or AR
    logic [riscv::VLEN-1:0]         iova;
    logic [DEVICE_ID_WIDTH-1:0]     device_id;
    logic [iommu_pkg::TTYP_LEN-1:0] trans_type;
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

    // Boundary violation
    logic                           bound_violation;

    // AXI request bus used to intercept AxADDR and AxVALID parameters, and connect to the demux slave port
    ariane_axi_soc_pkg::req_t       axi_aux_req;

    // Memory-Mapped Register Interface connections
    iommu_reg_pkg::iommu_reg2hw_t   reg2hw;
    iommu_reg_pkg::iommu_hw2reg_t   hw2reg;

    logic                           cq_error_wen;
    logic                           fq_error_wen;
    logic [53:0]                    msi_addr_x[16];
    logic [31:0]                    msi_data_x[16];
    logic                           msi_vec_masked_x[16];

    // WE signals
    assign  hw2reg.cqh.de               = 1'b1;
    assign  hw2reg.fqt.de               = 1'b1;
    assign  hw2reg.cqcsr.cqmf.de        = cq_error_wen;
    assign  hw2reg.cqcsr.cmd_to.de      = cq_error_wen;
    assign  hw2reg.cqcsr.cmd_ill.de     = cq_error_wen;
    assign  hw2reg.cqcsr.fence_w_ip.de  = cq_error_wen;
    assign  hw2reg.cqcsr.cqon.de        = 1'b1;
    assign  hw2reg.cqcsr.busy.de        = 1'b1;
    assign  hw2reg.cqcsr.fqmf.de        = fq_error_wen; 
    assign  hw2reg.cqcsr.fqof.de        = fq_error_wen;
    assign  hw2reg.cqcsr.fqon.de        = 1'b1;
    assign  hw2reg.cqcsr.busy.de        = 1'b1;
    assign  hw2reg.ipsr.cip.de          = hw2reg.ipsr.cip.d;
    assign  hw2reg.ipsr.fip.de          = hw2reg.ipsr.fip.d;

    assign  msi_addr_x = '{
        reg2hw.msi_addr_0.addr.q,
        reg2hw.msi_addr_1.addr.q,
        reg2hw.msi_addr_2.addr.q,
        reg2hw.msi_addr_3.addr.q,
        reg2hw.msi_addr_4.addr.q,
        reg2hw.msi_addr_5.addr.q,
        reg2hw.msi_addr_6.addr.q,
        reg2hw.msi_addr_7.addr.q,
        reg2hw.msi_addr_8.addr.q,
        reg2hw.msi_addr_9.addr.q,
        reg2hw.msi_addr_10.addr.q,
        reg2hw.msi_addr_11.addr.q,
        reg2hw.msi_addr_12.addr.q,
        reg2hw.msi_addr_13.addr.q,
        reg2hw.msi_addr_14.addr.q,
        reg2hw.msi_addr_15.addr.q
    };

    assign  msi_data_x = '{
        reg2hw.msi_data_0.q,
        reg2hw.msi_data_1.q,
        reg2hw.msi_data_2.q,
        reg2hw.msi_data_3.q,
        reg2hw.msi_data_4.q,
        reg2hw.msi_data_5.q,
        reg2hw.msi_data_6.q,
        reg2hw.msi_data_7.q,
        reg2hw.msi_data_8.q,
        reg2hw.msi_data_9.q,
        reg2hw.msi_data_10.q,
        reg2hw.msi_data_11.q,
        reg2hw.msi_data_12.q,
        reg2hw.msi_data_13.q,
        reg2hw.msi_data_14.q,
        reg2hw.msi_data_15.q
    };

    assign  msi_vec_masked_x = '{
        reg2hw.msi_vec_ctl_0.q,
        reg2hw.msi_vec_ctl_1.q,
        reg2hw.msi_vec_ctl_2.q,
        reg2hw.msi_vec_ctl_3.q,
        reg2hw.msi_vec_ctl_4.q,
        reg2hw.msi_vec_ctl_5.q,
        reg2hw.msi_vec_ctl_6.q,
        reg2hw.msi_vec_ctl_7.q,
        reg2hw.msi_vec_ctl_8.q,
        reg2hw.msi_vec_ctl_9.q,
        reg2hw.msi_vec_ctl_10.q,
        reg2hw.msi_vec_ctl_11.q,
        reg2hw.msi_vec_ctl_12.q,
        reg2hw.msi_vec_ctl_13.q,
        reg2hw.msi_vec_ctl_14.q,
        reg2hw.msi_vec_ctl_15.q
    };

    // Error slave AXI bus
    ariane_axi_soc_pkg::req_t       error_req;
    ariane_axi_soc_pkg::resp_t      error_rsp;

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
    assign axi_aux_req.aw_valid     = (trans_valid | trans_error | bound_violation) & aw_request;

    assign axi_aux_req.aw.id        = dev_tr_req_i.aw.id;
    assign axi_aux_req.aw.addr      = spaddr;               // translated address
    assign axi_aux_req.aw.len       = dev_tr_req_i.aw.len;
    assign axi_aux_req.aw.size      = dev_tr_req_i.aw.size;
    assign axi_aux_req.aw.burst     = dev_tr_req_i.aw.burst;
    assign axi_aux_req.aw.lock      = dev_tr_req_i.aw.lock;
    assign axi_aux_req.aw.cache     = dev_tr_req_i.aw.cache;
    assign axi_aux_req.aw.prot      = dev_tr_req_i.aw.prot;
    assign axi_aux_req.aw.qos       = dev_tr_req_i.aw.qos;
    assign axi_aux_req.aw.region    = dev_tr_req_i.aw.region;
    assign axi_aux_req.aw.atop      = dev_tr_req_i.aw.atop;
    assign axi_aux_req.aw.user      = dev_tr_req_i.aw.user;

    // W
    assign axi_aux_req.w            = dev_tr_req_i.w;
    assign axi_aux_req.w_valid      = dev_tr_req_i.w_valid;

    // B
    assign axi_aux_req.b_ready      = dev_tr_req_i.b_ready;

    // AR
    assign axi_aux_req.ar_valid     = (trans_valid | trans_error | bound_violation) & ar_request;

    assign axi_aux_req.ar.id        = dev_tr_req_i.ar.id;
    assign axi_aux_req.ar.addr      = spaddr;               // translated address
    assign axi_aux_req.ar.len       = dev_tr_req_i.ar.len;
    assign axi_aux_req.ar.size      = dev_tr_req_i.ar.size;
    assign axi_aux_req.ar.burst     = dev_tr_req_i.ar.burst;
    assign axi_aux_req.ar.lock      = dev_tr_req_i.ar.lock;
    assign axi_aux_req.ar.cache     = dev_tr_req_i.ar.cache;
    assign axi_aux_req.ar.prot      = dev_tr_req_i.ar.prot;
    assign axi_aux_req.ar.qos       = dev_tr_req_i.ar.qos;
    assign axi_aux_req.ar.region    = dev_tr_req_i.ar.region;
    assign axi_aux_req.ar.atop      = dev_tr_req_i.ar.atop;
    assign axi_aux_req.ar.user      = dev_tr_req_i.ar.user;

    // R
    assign axi_aux_req.r_ready      = dev_tr_req_i.r_ready;

    //# WSI Interrupt Generation
    if (InclWSI_IG) begin : gen_wsi_ig_support
        
        iommu_wsi_ig i_iommu_wsi_ig (
            // fctl.wsi
            .wsi_en_i       (reg2hw.fctl.wsi.q),

            // ipsr
            .cip_i          (reg2hw.ipsr.cip.q),
            .fip_i          (reg2hw.ipsr.fip.q),

            // icvec
            .civ_i          (reg2hw.icvec.civ.q),
            .fiv_i          (reg2hw.icvec.fiv.q),

            // interrupt wires
            .wsi_wires_o    (wsi_wires_o)
        );
    end

    // Hardwire WSI wires to 0
    else begin
        assign wsi_wires_o  = '0;
    end

    iommu_translation_wrapper #(
        .IOTLB_ENTRIES      (IOTLB_ENTRIES),
        .DDTC_ENTRIES       (DDTC_ENTRIES),
        .PDTC_ENTRIES       (PDTC_ENTRIES),
        .DEVICE_ID_WIDTH    (DEVICE_ID_WIDTH),
        .PROCESS_ID_WIDTH   (PROCESS_ID_WIDTH),
        .PSCID_WIDTH        (PSCID_WIDTH),
        .GSCID_WIDTH        (GSCID_WIDTH),
        .InclPID            (InclPID),
        .InclMSI_IG         (InclMSI_IG),
        .ArianeCfg          (ArianeCfg)
    ) i_translation_wrapper (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),

        .req_trans_i    (allow_request),        // Trigger translation

        // Translation request data
        .device_id_i    (device_id),            // AxID
        .pid_v_i        (1'b0),                 // We are not using process id by now
        .process_id_i   ('0),                   // Set to zero
        .iova_i         (iova),                 // AxADDR
        
        .trans_type_i   (trans_type),           // Always untranslated requests as PCIe is not implemented
        .priv_lvl_i     (riscv::PRIV_LVL_S),    // Always U-mode as we do not use process_id (See Spec)

        // Memory Bus
        .mem_resp_i     (mem_resp_i),           // Simply connect AXI channels
        .mem_req_o      (mem_req_o),

        // From Regmap
        .capabilities_i (reg2hw.capabilities),
        .fctl_i         (reg2hw.fctl),
        .ddtp_i         (reg2hw.ddtp),
        // CQ
        .cqb_ppn_i      (reg2hw.cqb.ppn.q),
        .cqb_size_i     (reg2hw.cqb.log2sz_1.q),
        .cqh_i          (reg2hw.cqh.q),
        .cqh_o          (hw2reg.cqh.d),     // WE always set to 1
        .cqt_i          (reg2hw.cqt.q),
        // FQ
        .fqb_ppn_i      (reg2hw.fqb.ppn.q),
        .fqb_size_i     (reg2hw.fqb.log2sz_1.q),
        .fqh_i          (reg2hw.fqh.q),
        .fqt_i          (reg2hw.fqt.q),
        .fqt_o          (hw2reg.fqt.d),     // WE always set to 1
        // cqcsr
        .cq_en_i        (reg2hw.cqcsr.cqen.q),
        .cq_ie_i        (reg2hw.cqcsr.cie.q),
        .cq_mf_i        (reg2hw.cqcsr.cqmf.q),
        .cq_cmd_to_i    (reg2hw.cqcsr.cmd_to.q),    
        .cq_cmd_ill_i   (reg2hw.cqcsr.cmd_ill.q),
        .cq_fence_w_ip_i(reg2hw.cqcsr.fence_w_ip.q),
        .cq_mf_o        (hw2reg.cqcsr.cqmf.d),      // WE driven by cq_error_wen
        .cq_cmd_to_o    (hw2reg.cqcsr.cmd_to.d),
        .cq_cmd_ill_o   (hw2reg.cqcsr.cmd_ill.d),
        .cq_fence_w_ip_o(hw2reg.cqcsr.fence_w_ip.d),
        .cq_on_o        (hw2reg.cqcsr.cqon.d),      // WE always set to 1
        .cq_busy_o      (hw2reg.cqcsr.busy.d),
        // fqcsr
        .fq_en_i        (reg2hw.fqcsr.fqen.q),
        .fq_ie_i        (reg2hw.fqcsr.fie.q),
        .fq_mf_i        (reg2hw.fqcsr.fqmf.q),
        .fq_of_i        (reg2hw.fqcsr.fqof.q),
        .fq_mf_o        (hw2reg.cqcsr.fqmf.d),      // WE driven by fq_error_wen
        .fq_of_o        (hw2reg.cqcsr.fqof.d),
        .fq_on_o        (hw2reg.cqcsr.fqon.d),      // WE always set to 1
        .fq_busy_o      (hw2reg.cqcsr.busy.d),
        // ipsr
        .cq_ip_i        (reg2hw.ipsr.cip.q),
        .fq_ip_i        (reg2hw.ipsr.fip.q),
        .cq_ip_o        (hw2reg.ipsr.cip.d),        // WE driven by itself
        .fq_ip_o        (hw2reg.ipsr.fip.d),        // WE driven by itself
        // icvec
        .civ_i          (reg2hw.icvec.civ.q),
        .fiv_i          (reg2hw.icvec.fiv.q),
        // msi_cfg_tbl
        .msi_addr_x_i       (msi_addr_x),
        .msi_data_x_i       (msi_data_x),
        .msi_vec_masked_x_i (msi_vec_masked_x),

        // To enable write of error bits to cqcsr and fqcsr
        .cq_error_wen_o (cq_error_wen),
        .fq_error_wen_o (fq_error_wen),

        .trans_valid_o      (trans_valid),  // Translation successfully completed
        .is_msi_o           (),             // Indicate whether the translated address is an MSI address
        .translated_addr_o  (spaddr),       // Translated address
        .trans_error_o      (trans_error)   // Translation error
    );

    iommu_regmap_if #(
        .ADDR_WIDTH      (ADDR_WIDTH      ),
        .DATA_WIDTH      (DATA_WIDTH      ),
        .ID_WIDTH        (ID_WIDTH        ),
        .USER_WIDTH      (USER_WIDTH      ),
        .BUFFER_DEPTH    (4               ), // Max 4 outstanding transaction at the programming interface
        .DECOUPLE_W      (1               ), // Channel W is decoupled with registers
        .axi_req_t       (axi_req_t       ),
        .axi_rsp_t       (axi_rsp_t       ),
        .axi_lite_req_t  (axi_lite_req_t  ),
        .axi_lite_resp_t (axi_lite_resp_t ),
        .reg_req_t       (reg_req_t       ),
        .reg_rsp_t       (reg_rsp_t       )
    ) i_iommu_regmap_if (
        .clk_i           (clk_i           ),
        .rst_ni          (rst_ni          ),

        .prog_req_i      (prog_req_i      ),
        .prog_resp_o     (prog_resp_o     ),

        .reg2hw_o        (reg2hw          ),
        .hw2reg_i        (hw2reg          )
    );

    //# Channel selection
    // Monitor incoming request and select parameters according to the source channel
    always_comb begin : channel_selection
        
        // Default values
        ar_request      = 1'b0;
        aw_request      = 1'b0;
        iova            = '0;
        device_id       = '0;
        trans_type      = iommu_pkg::NONE;
        burst_type      = '0;
        burst_length    = '0;
        n_bytes         = '0;

        // AR request received (this way we are giving priority to read transactions)
        if (dev_tr_req_i.ar_valid) begin

            ar_request  = 1'b1;

            iova            =  dev_tr_req_i.ar.addr;
            device_id       =  dev_tr_req_i.ar.id;
            // ARPROT[2] indicates data access (r) when LOW, instruction access (rx) when HIGH
            trans_type      = (dev_tr_req_i.ar.prot[2]) ? (iommu_pkg::UNTRANSLATED_RX) : (iommu_pkg::UNTRANSLATED_R);
            burst_type      =  dev_tr_req_i.ar.burst;
            burst_length    =  dev_tr_req_i.ar.len;
            n_bytes         =  dev_tr_req_i.ar.size;
        end

        // AW request received
        else if (dev_tr_req_i.aw_valid) begin

            aw_request  = 1'b1;

            iova            = dev_tr_req_i.aw.addr;
            device_id       = dev_tr_req_i.aw.id;
            trans_type      = iommu_pkg::UNTRANSLATED_W;
            burst_type      = dev_tr_req_i.aw.burst;
            burst_length    = dev_tr_req_i.aw.len;
            n_bytes         = dev_tr_req_i.aw.size;
        end
    end

    //# Boundary Check
    // In order to send error response, we need to set the corresponding valid signal and select the error slave in the AXI Demux.
    // To do that, we may OR the translation error flag from the translation wrapper with another flag to indicate a 4kiB cross
    // and trigger the error response
    always_comb begin : boundary_check

        allow_request   = 1'b0;
        bound_violation = 1'b0;

        // Request received
        if (ar_request || aw_request) begin

            // Consider burst type, N of beats and size of the beat (always 64 bits) to calculate number of bytes accessed:
            case (burst_type)

                // BURST_FIXED: The final address is Start Addr + 8 (ex: ARADDR + 8)
                axi_pkg::BURST_FIXED: begin
                    // May be optimized with bitwise AND
                    if (((iova & 12'hfff) + (1'b1 << n_bytes)) < (1'b1 << 12)) begin
                        allow_request   = 1'b1;     // Allow transaction
                    end

                    // Boundary violation
                    else begin
                        bound_violation = 1'b1;
                    end
                end

                // BURST_WRAP: The final address is the Wrap Boundary (Lower address) + size of the transfer
                axi_pkg::BURST_WRAP: begin
                    // wrap_boundary = (start_address/(number_bytes*burst_length)) * (number_bytes*burst_length)
                    // address_n = wrap_boundary + (number_bytes * burst_length)
                    logic [riscv::PLEN-1:0] wrap_boundary;

                    // by spec, N of transfers must be {2, 4, 8, 16}
                    // So, ARLEN must be {1, 3, 7, 15}
                    logic [2:0] log2_len;
                    case (burst_length)
                        8'd1: log2_len = 3'b001;
                        8'd3: log2_len = 3'b010;
                        8'd7: log2_len = 3'b011;
                        8'd15: log2_len = 3'b100;
                        default: log2_len = 3'b111;  // invalid
                    endcase

                    // The lowest address within a wrapping burst
                    // Wrap_Boundary = (INT(Start_Address / (Burst_Length x Number_Bytes))) x (Burst_Length x Number_Bytes)
                    wrap_boundary = (iova >> (log2_len + n_bytes)) << (log2_len + n_bytes);

                    // Check if the highest address crosses a 4 kiB boundary (Highest Addr - Lower Addr >= 4kiB)
                    // Highest addr = Wrap_Boundary + (Burst_Length x Number_Bytes)
                    if (!(&log2_len) && 
                         (((wrap_boundary & 12'hfff) + ((burst_length + 1) << n_bytes)) < (1'b1 << 12))) begin
                        allow_request  = 1'b1;     // Allow transaction
                    end
                    
                    // Boundary violation
                    else begin
                        bound_violation = 1'b1;
                    end

                end

                // BURST_INCR: The final address is Start Addr + Burst_Length x Number_Bytes
                axi_pkg::BURST_INCR: begin
                    // check if burst is within 4K range
                    if (((iova & 12'hfff) + ((burst_length + 1) << n_bytes)) < (1'b1 << 12)) begin
                        allow_request  = 1'b0;     // Allow transaction
                    end

                    // Boundary violation
                    else begin
                        bound_violation = 1'b1;
                    end
                end
            endcase
        end
    end

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
    ) axi_demux (
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
    
endmodule