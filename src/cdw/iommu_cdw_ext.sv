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
// Date: 19/01/2023
//
// Description: RISC-V IOMMU Hardware Context Directory Walker (CDW) for IOMMU implementations 
//              WITHOUT Process Context and WITH MSI translation support.
//              This module walks memory to locate Device Contexts in extended format, and updates the external DDTC.

//# Disabled verilator_lint_off WIDTH

module iommu_cdw_ext (
    input  logic                    clk_i,                  // Clock
    input  logic                    rst_ni,                 // Asynchronous reset active low
    
    // Error signaling
    output logic                                cdw_active_o,           // Set when PTW is walking memory
    output logic                                cdw_error_o,            // set when an error occurred
    output logic [(rv_iommu::CAUSE_LEN-1):0]    cause_code_o,           // Fault code as defined by IOMMU and Priv Spec

    // Leaf checks
    // DC checks
    input  logic        caps_ats_i,
    input  logic        caps_t2gpa_i,
    input  logic        caps_pd20_i, caps_pd17_i, caps_pd8_i,
    input  logic        caps_sv32_i, caps_sv39_i, caps_sv48_i, caps_sv57_i,
    input  logic        fctl_gxl_i, caps_sv32x4_i, caps_sv39x4_i, caps_sv48x4_i, caps_sv57x4_i,
    input  logic        caps_msi_flat_i,
    input  logic        caps_amo_hwad_i,
    input  logic        caps_end_i, fctl_be_i,

    // CDW memory interface
    input  ariane_axi_soc::resp_t   mem_resp_i,
    output ariane_axi_soc::req_t    mem_req_o,

    // Update logic
    output  logic                   update_dc_o,
    output  logic [23:0]            up_did_o,
    output  rv_iommu::dc_ext_t      up_dc_content_o,

    // CDC tags
    input  logic [23:0]             req_did_i,    // device_id associated with request

    // from DDTC, to monitor misses
    input  logic                    ddtc_access_i,
    input  logic                    ddtc_hit_i,

    // from regmap
    input  logic [riscv::PPNW-1:0]  ddtp_ppn_i,     // PPN from ddtp register
    input  logic [3:0]              ddtp_mode_i    // DDT levels and IOMMU mode
);

    // DC/PC Update register
    rv_iommu::dc_ext_t dc_q, dc_n;

    // Cast read port to corresponding data structure
    rv_iommu::nl_entry_t nl;
    rv_iommu::tc_t dc_tc;
    rv_iommu::iohgatp_t dc_iohgatp;
    rv_iommu::dc_ta_t dc_ta;
    rv_iommu::fsc_t dc_fsc;
    rv_iommu::msiptp_t dc_msiptp;
    rv_iommu::msi_addr_mask_t dc_msi_addr_mask;
    rv_iommu::msi_addr_pattern_t dc_msi_addr_patt;

    assign dc_tc = rv_iommu::tc_t'(mem_resp_i.r.data);
    assign dc_iohgatp = rv_iommu::iohgatp_t'(mem_resp_i.r.data);
    assign dc_ta = rv_iommu::dc_ta_t'(mem_resp_i.r.data);
    assign dc_fsc = rv_iommu::fsc_t'(mem_resp_i.r.data);
    assign dc_msiptp = rv_iommu::msiptp_t'(mem_resp_i.r.data);
    assign dc_msi_addr_mask = rv_iommu::msi_addr_mask_t'(mem_resp_i.r.data);
    assign dc_msi_addr_patt = rv_iommu::msi_addr_pattern_t'(mem_resp_i.r.data);

    assign nl = rv_iommu::nl_entry_t'(mem_resp_i.r.data);

    // PTW states
    typedef enum logic[2:0] {
      IDLE,                     // 000
      MEM_ACCESS,               // 001
      NON_LEAF,                 // 010
      LEAF,                     // 011
      ERROR                     // 100
    } state_t;
    
    state_t state_q, state_n;

    // IOMMU mode and DDT levels
    typedef enum logic [2:0] {
        OFF, BARE, LVL1, LVL2, LVL3
    } level_t;
    
    level_t cdw_lvl_q, cdw_lvl_n;

    // Save and propagate the input device_id/process id to walk multiple levels
    logic [23:0] device_id_q, device_id_n;

    // Physical pointer to access memory bus
    logic [riscv::PLEN-1:0] cdw_pptr_q, cdw_pptr_n;

    // Last DDT/PDT level
    logic is_last_cdw_lvl;

    // It's not possible to load the entire DC in one request.
    // Aux counter to know how many DWs we have loaded
    logic [2:0] entry_cnt_q, entry_cnt_n;
    logic dc_fully_loaded;

    // Cause propagation
    logic [(rv_iommu::CAUSE_LEN-1):0] cause_q, cause_n;

    // To know whether we have to wait for the AXI transaction to complete on errors
    logic wait_rlast_q, wait_rlast_n;

    // CDW walking
    assign cdw_active_o    = (state_q != IDLE);
    // Last CDW level
    assign is_last_cdw_lvl = (cdw_lvl_q == LVL1);
    // Determine whether we have loaded the entire DC/PC
    assign dc_fully_loaded = (entry_cnt_q == 3'b111);  // extended format excluding last DW (56 bytes)

    // -------------------
    //# DDTC Update
    // -------------------
    assign up_did_o = device_id_q;
    assign up_dc_content_o = dc_q;

    //# Context Directory Walker
    always_comb begin : cdw

        // default assignments
        // AXI parameters
        // AW
        mem_req_o.aw.id         = 4'b0011;
        mem_req_o.aw.addr       = '0;
        mem_req_o.aw.len        = 8'b0;
        mem_req_o.aw.size       = 3'b011;
        mem_req_o.aw.burst      = axi_pkg::BURST_INCR;
        mem_req_o.aw.lock       = '0;
        mem_req_o.aw.cache      = '0;
        mem_req_o.aw.prot       = '0;
        mem_req_o.aw.qos        = '0;
        mem_req_o.aw.region     = '0;
        mem_req_o.aw.atop       = '0;
        mem_req_o.aw.user       = '0;

        mem_req_o.aw_valid      = 1'b0;                 // CDW will never write to memory

        // W
        mem_req_o.w.data        = '0;
        mem_req_o.w.strb        = '0;
        mem_req_o.w.last        = '0;
        mem_req_o.w.user        = '0;

        mem_req_o.w_valid       = 1'b0;                 // CDW will never write to memory

        // B
        mem_req_o.b_ready       = 1'b0;

        // AR
        mem_req_o.ar.id                     = 4'b0001;                         
        mem_req_o.ar.addr[riscv::PLEN-1:0]  = cdw_pptr_q;                       // Physical address to access
        // Number of beats per burst (1 for non-leaf entries, 7 for DC)
        mem_req_o.ar.len                    = (is_last_cdw_lvl) ? (8'd6) : (8'd0);
        mem_req_o.ar.size                   = 3'b011;                           // 64 bits (8 bytes) per beat
        mem_req_o.ar.burst                  = axi_pkg::BURST_INCR;              // Incremental start address
        mem_req_o.ar.lock                   = '0;
        mem_req_o.ar.cache                  = '0;
        mem_req_o.ar.prot                   = '0;
        mem_req_o.ar.qos                    = '0;
        mem_req_o.ar.region                 = '0;
        mem_req_o.ar.user                   = '0;

        mem_req_o.ar_valid      = 1'b0;                 // to init a request

        // R
        mem_req_o.r_ready       = 1'b0;                 // to signal read completion

        cdw_error_o             = 1'b0;
        cause_code_o            = '0;
        update_dc_o             = 1'b0;

        cdw_lvl_n               = cdw_lvl_q;
        cdw_pptr_n              = cdw_pptr_q;
        state_n                 = state_q;
        entry_cnt_n             = entry_cnt_q;
        cause_n                 = cause_q;
        wait_rlast_n            = wait_rlast_q;
        device_id_n             = device_id_q;
        dc_n                    = dc_q;

        case (state_q)

            // check for possible misses in DDTC
            IDLE: begin
                // start with the level indicated by ddtp.MODE
                cdw_lvl_n       = level_t'(ddtp_mode_i);
                device_id_n     = req_did_i;
                entry_cnt_n     = '0;
                wait_rlast_n    = 1'b0;

                // check for DDTC misses
                if (ddtc_access_i && ~ddtc_hit_i) begin
                    
                    state_n = MEM_ACCESS;

                    // load pptr according to ddtp.MODE
                    // 3LVL
                    if (ddtp_mode_i == 4'b0100)
                        cdw_pptr_n = {ddtp_ppn_i, req_did_i[23:15], 3'b0};
                    // 2LVL
                    else if (ddtp_mode_i == 4'b0011)
                        cdw_pptr_n = {ddtp_ppn_i, req_did_i[14:6], 3'b0};
                    // 1LVL
                    else if (ddtp_mode_i == 4'b0010)
                        cdw_pptr_n = {ddtp_ppn_i, req_did_i[5:0], 6'b0};
                end
            end

            // perform memory access with address hold in cdw_pptr_q
            MEM_ACCESS: begin
                // send request to AXI Bus
                mem_req_o.ar_valid = 1'b1;

                // wait for the MEM_ACCESS
                if (mem_resp_i.ar_ready) begin

                    // decode next state
                    /*
                        Control signals:
                        - Is the last level of the DDT?
                    */
                    if (is_last_cdw_lvl) 

                        // rdata will hold the PPN of a non-leaf DDT entry
                        state_n = LEAF;

                    else
                        // rdata will hold one of the doublewords of the DC
                        state_n = NON_LEAF;
                end
            end

            // Set pptr with the ppn of a non-leaf entry and the corresponding dev ID segment
            // Always triggers a CDW memory access
            NON_LEAF: begin
                // we wait for the valid signal when coming from MEM_ACCESS
                // (DDT non-leaf entries)
                if (mem_resp_i.r_valid) begin

                    mem_req_o.r_ready = 1'b1;

                    // "If ddte.V == 0, stop and report "DDT entry not valid" (cause = 258)"
                    if (!nl.v) begin
                        state_n = ERROR;
                        cause_n = rv_iommu::DDT_ENTRY_INVALID;
                    end

                    //# Valid non-leaf entry
                    else begin
                        // Set pptr and next level
                        case (cdw_lvl_q)
                            LVL3: begin
                                cdw_lvl_n = LVL2;
                                cdw_pptr_n = {nl.ppn, device_id_q[14:6], 3'b0};
                            end

                            LVL2: begin
                                cdw_lvl_n = LVL1;
                                cdw_pptr_n = {nl.ppn, device_id_q[5:0], 6'b0};
                            end

                            default:;
                        endcase

                        state_n = MEM_ACCESS;

                        // "If any bits or encoding that are reserved for future standard use are set within ddte,"
                        // "stop and report "DDT entry misconfigured" (cause = 259)"
                        if ((|nl.reserved_1) || (|nl.reserved_2)) begin
                            state_n = ERROR;
                            cause_n = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                        end
                    end
                end
            end

            // rdata holds one of the doublewords of the DC.
            // Here we check whether DC has been fully loaded, if not, go back to MEM_ACCESS.
            LEAF: begin

                // Last DW
                if (dc_fully_loaded) begin

                    state_n = IDLE;
                    // At this point we MUST have the entire DC stored
                    // Update DDTC
                    update_dc_o = 1'b1;
                end

                // Not last DW. Update counter, save DW
                else if (mem_resp_i.r_valid) begin

                    mem_req_o.r_ready   = 1'b1;
                    entry_cnt_n         = entry_cnt_q + 1;
                    // Address is automatically incremented by AXI Bus

                    case (entry_cnt_q)

                        //DC.tc
                        3'b000: begin
                            dc_n.tc = dc_tc;

                            // "If ddte.V == 0, stop and report "DDT entry not valid" (cause = 258)"
                            if (!dc_tc.v) begin
                                state_n = ERROR;
                                cause_n = rv_iommu::DDT_ENTRY_INVALID;
                                wait_rlast_n    = 1'b1;
                            end

                            // Config checks
                            if ((|dc_tc.reserved_1) || (|dc_tc.reserved_2) || 
                                (!caps_ats_i && (dc_tc.en_ats || dc_tc.en_pri || dc_tc.prpr)) ||
                                (!dc_tc.en_ats && (dc_tc.t2gpa || dc_tc.en_pri || dc_tc.prpr)) ||
                                (!caps_t2gpa_i && dc_tc.t2gpa) ||
                                (!dc_tc.pdtv && dc_tc.dpe) ||
                                (!caps_amo_hwad_i && (dc_tc.sade || dc_tc.gade)) ||
                                (!caps_end_i && (fctl_be_i != dc_tc.sbe)) ||
                                (dc_tc.sxl != fctl_gxl_i)) begin
                                state_n = ERROR;
                                cause_n = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                                wait_rlast_n    = 1'b1;
                            end
                        end

                        //DC.iohgatp
                        3'b001: begin
                            dc_n.iohgatp = dc_iohgatp;

                            // Config checks
                            if ((dc_q.tc.t2gpa && !(|dc_iohgatp.mode)) ||
                                (!(dc_iohgatp.mode inside {4'd0, 4'd8, 4'd9, 4'd10})) ||
                                (!fctl_gxl_i && ((!caps_sv39x4_i && dc_iohgatp.mode == 4'd8) ||
                                                 (!caps_sv48x4_i && dc_iohgatp.mode == 4'd9) ||
                                                 (!caps_sv57x4_i && dc_iohgatp.mode == 4'd10))) ||
                                (fctl_gxl_i && (!caps_sv32x4_i && dc_iohgatp.mode == 4'd8)) ||
                                (|dc_iohgatp.mode && |dc_iohgatp.ppn[1:0])) begin
                                state_n = ERROR;
                                cause_n = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                                wait_rlast_n    = 1'b1;
                            end
                        end

                        //DC.ta
                        3'b010: begin
                            dc_n.ta = dc_ta;

                            // Config checks
                            if ((|dc_ta.reserved_1) || (|dc_ta.reserved_2)) begin
                                state_n = ERROR;
                                cause_n = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                                wait_rlast_n    = 1'b1;
                            end
                        end

                        //DC.fsc
                        3'b011: begin
                            dc_n.fsc = dc_fsc;

                            // Config checks
                            if ((dc_q.tc.pdtv && ((!caps_pd20_i && dc_fsc.mode == 4'b0011) ||
                                                  (!caps_pd17_i && dc_fsc.mode == 4'b0010) ||
                                                  (!caps_pd8_i && dc_fsc.mode == 4'b0001))) ||
                                (!dc_q.tc.pdtv && !(dc_fsc.mode inside {4'd0, 4'd8, 4'd9, 4'd10})) ||
                                (!dc_q.tc.pdtv && !dc_q.tc.sxl && ((!caps_sv39_i && dc_fsc.mode == 4'd8) ||
                                                                   (!caps_sv48_i && dc_fsc.mode == 4'd9) ||
                                                                   (!caps_sv57_i && dc_fsc.mode == 4'd10))) ||
                                (!dc_q.tc.pdtv && dc_q.tc.sxl && (!caps_sv32_i && dc_fsc.mode == 4'd8)) ||
                                (|dc_fsc.reserved)) begin
                                state_n = ERROR;
                                cause_n = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                                wait_rlast_n    = 1'b1;
                            end
                        end

                        //DC.msiptp
                        3'b100: begin
                            dc_n.msiptp = dc_msiptp;

                            // Config checks
                            if ((caps_msi_flat_i && !(dc_msiptp.mode inside {4'd0, 4'd1})) ||
                                (|dc_msiptp.reserved)) begin
                                state_n = ERROR;
                                cause_n = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                                wait_rlast_n    = 1'b1;
                            end
                        end

                        //DC.msi_addr_mask
                        3'b101: begin
                            dc_n.msi_addr_mask = dc_msi_addr_mask;

                            // Config checks
                            if ((|dc_msi_addr_mask.reserved)) begin
                                state_n = ERROR;
                                cause_n = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                                wait_rlast_n    = 1'b1;
                            end
                        end

                        //DC.msi_addr_pattern (last DW)
                        3'b110: begin
                            dc_n.msi_addr_pattern = dc_msi_addr_patt;

                            // Config checks
                            if ((|dc_msi_addr_patt.reserved)) begin
                                state_n = ERROR;
                                cause_n = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                            end
                        end
                        
                        default:;
                    endcase
                end
            end

            // Permission/access errors detected. Propagate fault signal with error code
            ERROR: begin
                mem_req_o.r_ready   = 1'b1;     // Set RREADY to finish all transactions

                // Set cause code
                cause_code_o = cause_q;

                // Check whether we have to wait for AXI transmission to end
                if ((wait_rlast_q && mem_resp_i.r.last) || !wait_rlast_q) begin
                    cdw_error_o         = 1'b1;
                    state_n = IDLE;
                end
            end

            default: begin
                state_n = IDLE;
            end
        endcase

        // Check for AXI transmission errors
        if (mem_resp_i.r_valid && mem_resp_i.r.resp != axi_pkg::RESP_OKAY) begin
            update_dc_o     = 1'b0;
            wait_rlast_n    = ~mem_resp_i.r.last;

            // set cause code
            cause_n = rv_iommu::DDT_DATA_CORRUPTION;

            // return faulting address in bad_addr
            cdw_pptr_n = cdw_pptr_q;
            state_n = ERROR;
        end

        /*
            # Note about IOPMP faults for CDW accesses:
            IOPMP access faults are reported as failing AXI transactions. If accessing (reading) a DC/PC
            violates an IOPMP check, the read transaction is responded with an AXI error in the R channel.
            Custom data can be placed in the RDATA bus to differentiate IOPMP access faults from other 
            AXI errors.
        */
    end

    // sequential process
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            state_q                 <= IDLE;
            cdw_lvl_q               <= LVL1;
            cdw_pptr_q              <= '0;
            entry_cnt_q             <= '0;
            device_id_q             <= '0;
            cause_q                 <= '0;
            dc_q                    <= '0;
            wait_rlast_q            <= 1'b0;

        end else begin
            state_q                 <= state_n;
            cdw_pptr_q              <= cdw_pptr_n;
            cdw_lvl_q               <= cdw_lvl_n;
            entry_cnt_q             <= entry_cnt_n;
            device_id_q             <= device_id_n;
            cause_q                 <= cause_n;
            dc_q                    <= dc_n;
            wait_rlast_q            <= wait_rlast_n;
        end
    end

endmodule
//# Disabled verilator_lint_on WIDTH
