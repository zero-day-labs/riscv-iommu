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

module riscv_iommu #(
    parameter int unsigned IOTLB_ENTRIES = 4,
    parameter int unsigned DDTC_ENTRIES = 4,
    parameter int unsigned PDTC_ENTRIES = 4,
    parameter int unsigned DEVICE_ID_WIDTH = 24,
    parameter int unsigned PROCESS_ID_WIDTH  = 20,
    parameter int unsigned PSCID_WIDTH = 20,
    parameter int unsigned GSCID_WIDTH = 16,
    parameter ariane_pkg::ariane_cfg_t ArianeCfg = ariane_pkg::ArianeDefaultConfig
) (
    input  logic clk_i,
    input  logic rst_ni

    // Translation Request Interface (Slave)
    input  ariane_axi_soc_pkg::req_t        dev_tr_req_i,
    output ariane_axi_soc_pkg::resp_t       dev_tr_resp_o,

    // Translation Completion Interface (Master)
    input  ariane_axi_soc_pkg::resp_t       dev_comp_resp_i,
    output ariane_axi_soc_pkg::req_t        dev_comp_req_o,

    // Implicit Memory Accesses Interface (Master)
    input  ariane_axi_soc_pkg::resp_t       mem_resp_i,
    output ariane_axi_soc_pkg::req_t        mem_req_o,

    // Programming Interface (Slave) (Have to be converted to AXI Lite)
    input  ariane_axi_soc_pkg::req_t        prog_req_i,
    output ariane_axi_soc_pkg::resp_t       prog_resp_o
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

    // Error slave AXI bus
    ariane_axi_soc_pkg::req_t       error_req;
    ariane_axi_soc_pkg::resp_t      error_rsp;

    // AW
    // AWVALID is set on translation success or when an error occurs
    /* 
        On success, the AXI demux connects the AXI bus to the Master IF. Since the translation is 
        triggered by the original AWVALID signal (when bound check is passed), it will remain set 
        until a handshake occurs. After the handshake, the translation request signal (driven by AWVALID)
        is cleared, and thus, the translation success will also go low.

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

    iommu_translation_wrapper #(
        .IOTLB_ENTRIES      (IOTLB_ENTRIES),
        .DDTC_ENTRIES       (DDTC_ENTRIES),
        .PDTC_ENTRIES       (PDTC_ENTRIES),
        .DEVICE_ID_WIDTH    (DEVICE_ID_WIDTH),
        .PROCESS_ID_WIDTH   (PROCESS_ID_WIDTH),
        .PSCID_WIDTH        (PSCID_WIDTH),
        .GSCID_WIDTH        (GSCID_WIDTH),
        .ArianeCfg          (ArianeCfg)
    ) translation_wrapper (
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
        .capabilities_i (),
        .fctl_i         (),
        .ddtp_i         (),
        // CQ
        .cqb_ppn_i      (),
        .cqb_size_i     (),
        .cqh_i          (),
        .cqh_o          (),
        .cqt_i          (),
        // FQ
        .fqb_ppn_i      (),
        .fqb_size_i     (),
        .fqh_i          (),
        .fqt_i          (),
        .fqt_o          (),
        // cqcsr
        .cq_en_i        (),
        .cq_ie_i        (),
        .cq_mf_i        (),
        .cq_cmd_to_i    (),    
        .cq_cmd_ill_    (),
        .cq_fence_w_ip_i(),
        .cq_mf_o        (),
        .cq_cmd_to_o    (),
        .cq_cmd_ill_    (),
        .cq_fence_w_ip_o(),
        .cq_on_o        (),
        .cq_busy        (),
        // fqcsr
        .fq_en_i        (),
        .fq_ie_i        (),
        .fq_mf_i        (),
        .fq_of_i        (),
        .fq_mf_o        (),
        .fq_of_o        (),
        .fq_on_o        (),
        .fq_busy_o      (),
        //ipsr
        .cq_ip_o        (),
        .fq_ip_o        (),

        // To enable write of error bits to cqcsr and fqcsr
        .cq_error_wen_o (),
        .fq_error_wen_o (),

        .trans_valid_o      (trans_valid),     // Translation successfully completed
        .is_msi_o           (),     // Indicate whether the translated address is an MSI address
        .translated_addr_o  (spaddr),     // Translated address
        .trans_error_o      (trans_error)      // Translation error
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
        .AxiIdWidth (ariane_soc::IdWidth),
        // AXI channel structs
        .aw_chan_t  ( ariane_axi_soc::aw_chan_t ),
        .w_chan_t   ( ariane_axi_soc::w_chan_t  ),
        .b_chan_t   ( ariane_axi_soc::b_chan_t  ),
        .ar_chan_t  ( ariane_axi_soc::ar_chan_t ),
        .r_chan_t   ( ariane_axi_soc::r_chan_t  ),
        // AXI request/response
        .req_t      ( ariane_axi_soc::req_t     ),
        .resp_t     ( ariane_axi_soc::resp_t    ),
        .NoMstPorts (2),
        .MaxTrans   (32'd2),                //? Not quite sure these values are right
        .AxiLookBits(ariane_soc::IdWidth),  // Assuming same value as AXI ID width
        .FallThrough(1'b0),
        .SpillAw    (1'b0),
        .SpillW     (1'b0),
        .SpillB     (1'b0),
        .SpillAr    (1'b0),
        .SpillR     (1'b0)
    ) axi_demux (
        .clk_i          (clk_i),
        .rst_ni         (rst_ni),
        .test_i         (1'b0),         // if 1, explicit error return for unmapped register access
        .slv_aw_select_i(trans_valid & aw_request),
        .slv_ar_select_i(trans_valid & ar_request),
        .slv_req_i      (axi_aux_req),
        .slv_resp_o     (dev_tr_resp_o),
        .mst_reqs_o     ({dev_comp_req_o, error_req}),  // { 1: mst, 0: error }
        .mst_resps_i    ({dev_comp_resp_i, error_rsp})   // { 1: mst, 0: error }
    );

    axi_err_slv #(
      .AxiIdWidth   (ariane_soc::IdWidth),
      .req_t        (ariane_axi_soc::req_t),
      .resp_t       (ariane_axi_soc::resp_t),
      .Resp         (axi_pkg::RESP_SLVERR),         // error generated by this slave
      .RespWidth    (ariane_axi_soc::DataWidth),    // data response width, gets zero extended or truncated to r.data.
      .RespData     (64'hCA11AB1EBADCAB1E),         // hexvalue for data return value
      .ATOPs        (1'b1),                         // Activate support for ATOPs.
      .MaxTrans     (1)                             // Maximum # of accepted transactions before stalling
  ) i_axi_err_slv (
      .clk_i        (clk_i),
      .rst_ni       (rst_ni),
      .test_i       (1'b0),
      .slv_req_i    (error_req),
      .slv_resp_o   (error_rsp)
  );
    
endmodule