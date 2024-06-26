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
// Acknowledges: SSRC - Technology Innovation Institute (TII)
//
// Description: Context Directory Walker (CDW) for the RISC-V IOMMU.
//              Supports Process Contexts. Parameterized MSI translation support
//              This module walks memory to locate DCs, PCs, and updates the corresponding cache.

module rv_iommu_cdw_pc #(

    // MSI translation support
    parameter rv_iommu::msi_trans_t MSITrans    = rv_iommu::MSI_DISABLED,

    /// AXI Full request struct type
    parameter type  axi_req_t       = logic,
    /// AXI Full response struct type
    parameter type  axi_rsp_t       = logic,

    // DC width
    parameter int DC_WIDTH          = -1,

    // AR burst size (DO NOT OVERRIDE)
    parameter logic [7:0] ar_len    = ((MSITrans != rv_iommu::MSI_DISABLED) ? (8'd6) : (8'd3))
) (
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

    // PC checks
    input  logic        dc_sxl_i,

    // CDW memory interface
    input  axi_rsp_t    mem_resp_i,
    output axi_req_t    mem_req_o,

    // Update logic
    output  logic                   update_dc_o,
    output  logic [23:0]            up_did_o,
    output  logic [(DC_WIDTH-1):0]  up_dc_content_o,

    output logic                    update_pc_o,
    output logic [19:0]             up_pid_o,
    output rv_iommu::pc_t           up_pc_content_o,

    // CDC tags
    input  logic [23:0]             req_did_i,    // device_id associated with request
    input  logic [19:0]             req_pid_i,    // process_id associated with request

    // from DDTC / PDTC, to monitor misses
    input  logic                    init_cdw_i,

    input  logic                    pdtc_access_i,
    input  logic                    pdtc_hit_i,

    // from regmap
    input  logic [riscv::PPNW-1:0]  ddtp_ppn_i,     // PPN from ddtp register
    input  logic [3:0]              ddtp_mode_i,    // DDT levels and IOMMU mode

    // from DC (for PC walks)
    input  logic                    en_stage2_i,    // Second-stage translation is enabled
    input  logic [riscv::PPNW-1:0]  pdtp_ppn_i,     // PPN from DC.fsc.PPN
    input  logic [3:0]              pdtp_mode_i,    // PDT levels from DC.fsc.MODE

    // CDW implicit translations (Second-stage only)
    input  logic                        ptw_done_i,
    input  logic                        flush_i,
    input  logic [riscv::PPNW-1:0]      pdt_ppn_i,
    output logic                        cdw_implicit_access_o,
    output logic                        is_ddt_walk_o,
    output logic [(riscv::GPPNW-1):0]   pdt_gppn_o,
    output logic [riscv::PPNW-1:0]      iohgatp_ppn_fw_o  // to forward iohgatp.PPN to PTW when translating pdtp.PPN
);

    // Save and propagate the input device_id/process id to walk multiple levels
    logic [23:0] device_id_q, device_id_n;
    logic [19:0] process_id_q, process_id_n;

    // DC/PC Update registers
    rv_iommu::tc_t      dc_tc_q,        dc_tc_n;
    rv_iommu::iohgatp_t dc_iohgatp_q,   dc_iohgatp_n;
    rv_iommu::dc_ta_t   dc_ta_q,        dc_ta_n;
    rv_iommu::fsc_t     dc_fsc_q,       dc_fsc_n;

    rv_iommu::pc_ta_t   pc_ta_q,    pc_ta_n;
    rv_iommu::fsc_t     pc_fsc_q,   pc_fsc_n;

    // DDTC / PDTC Update
    assign up_did_o = device_id_q;

    assign up_pid_o = process_id_q;

    assign up_pc_content_o.ta   = pc_ta_q;
    assign up_pc_content_o.fsc  = pc_fsc_q;

    // Cast read port to corresponding data structure
    rv_iommu::tc_t          dc_tc;
    rv_iommu::iohgatp_t     dc_iohgatp;
    rv_iommu::dc_ta_t       dc_ta;
    rv_iommu::fsc_t         dc_fsc;

    rv_iommu::pc_ta_t       pc_ta;
    rv_iommu::fsc_t         pc_fsc;

    rv_iommu::nl_entry_t    nl;

    assign dc_tc = rv_iommu::tc_t'(mem_resp_i.r.data);
    assign dc_iohgatp = rv_iommu::iohgatp_t'(mem_resp_i.r.data);
    assign dc_ta = rv_iommu::dc_ta_t'(mem_resp_i.r.data);
    assign dc_fsc = rv_iommu::fsc_t'(mem_resp_i.r.data);
    
    assign pc_ta = rv_iommu::pc_ta_t'(mem_resp_i.r.data);
    assign pc_fsc = rv_iommu::fsc_t'(mem_resp_i.r.data);

    assign nl = rv_iommu::nl_entry_t'(mem_resp_i.r.data);

    // PTW states
    typedef enum logic[2:0] {
      IDLE,                     // 000
      MEM_ACCESS,               // 001
      NON_LEAF,                 // 010
      LEAF,                     // 011
      GUEST_TR,                 // 100
      ERROR                     // 101
    } state_t;
    
    state_t state_q, state_n;

    // IOMMU mode and DDT/PDT levels
    typedef enum logic [2:0] {
        OFF, BARE, LVL1, LVL2, LVL3
    } level_t;
    
    level_t cdw_lvl_q, cdw_lvl_n;

    // Propagate miss source to update later
    logic is_ddt_walk_q, is_ddt_walk_n;

    // Physical pointer to access memory bus
    logic [riscv::PLEN-1:0] cdw_pptr_q, cdw_pptr_n;

    // Last DDT/PDT level
    logic is_last_cdw_lvl;

    // Propagate done signal from PTW
    logic ptw_done_q;

    // It's not possible to load the entire DC/PC in one request.
    // Aux counter to know how many DWs we have loaded
    // 3-bit wide since we are not counting the reserved DW of the DC
    logic [2:0] entry_cnt_q, entry_cnt_n;
    logic dc_fully_loaded, pc_fully_loaded;

    // Cause propagation
    logic [(rv_iommu::CAUSE_LEN-1):0] cause_q, cause_n;

    // To know whether we have to wait for the AXI transaction to complete
    logic wait_rlast_q, wait_rlast_n;

    // Enable MSI DC fields configuration checks
    logic en_msi_check;

    // Signal main FSM to translate the pdtp using second-stage translation
    logic translate_pdtp;

    // Signal MSI field config error to main FSM
    logic msi_check_error;

    // PTW walking
    assign cdw_active_o     = (state_q != IDLE);
    // Last CDW level
    assign is_last_cdw_lvl  = (cdw_lvl_q == LVL1);
    // Determine whether we have loaded the entire DC/PC
    assign dc_fully_loaded  = (MSITrans != rv_iommu::MSI_DISABLED) ? (entry_cnt_q == 3'b111) : (entry_cnt_q == 3'b100);  // extended format w/out reserved DW (64-8 = 56 bytes)
    assign pc_fully_loaded  = (entry_cnt_q == 3'b010);  // always 16-bytes
    // PTW needs to know walk type to identify pdtp.PPN translations and select correct iohgatp source
    assign is_ddt_walk_o    = is_ddt_walk_q;

    // Edge-triggered init control
    logic edge_trigger_q, edge_trigger_n;

    // Edge-triggered init control
    always_comb begin : cdw_init_control

        // Default
        edge_trigger_n = edge_trigger_q;

        // Edged signal
        if (!edge_trigger_q && init_cdw_i)
            edge_trigger_n = 1'b1;

        // End of edged signal
        if (edge_trigger_q && !init_cdw_i)
            edge_trigger_n = 1'b0;

    end : cdw_init_control

    //# Context Directory Walker
    always_comb begin : cdw

        // default assignments
        // Wires
        en_msi_check = 1'b0;

        // Output values
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
        mem_req_o.ar.id         = 4'b0001;                         
        mem_req_o.ar.addr       = {{riscv::XLEN-riscv::PLEN{1'b0}}, cdw_pptr_q};    // Physical address to access
        // Number of beats per burst (1 for non-leaf entries, 2 for PC, 7 for DC)
        mem_req_o.ar.len        = (is_last_cdw_lvl) ? ((is_ddt_walk_q) ? (ar_len) : (8'd1)) : (8'd0);
        mem_req_o.ar.size       = 3'b011;                                           // 64 bits (8 bytes) per beat
        mem_req_o.ar.burst      = axi_pkg::BURST_INCR;                              // Incremental start address
        mem_req_o.ar.lock       = '0;
        mem_req_o.ar.cache      = '0;
        mem_req_o.ar.prot       = '0;
        mem_req_o.ar.qos        = '0;
        mem_req_o.ar.region     = '0;
        mem_req_o.ar.user       = '0;

        mem_req_o.ar_valid      = 1'b0;                 // to init a request

        // R
        mem_req_o.r_ready       = 1'b0;                 // to signal read completion

        cdw_error_o             = 1'b0;
        cause_code_o            = '0;
        update_dc_o             = 1'b0;
        update_pc_o             = 1'b0;
        pdt_gppn_o              = '0;
        cdw_implicit_access_o   = 1'b0;
        iohgatp_ppn_fw_o        = '0;

        // Next state values
        cdw_lvl_n               = cdw_lvl_q;
        cdw_pptr_n              = cdw_pptr_q;
        state_n                 = state_q;
        is_ddt_walk_n           = is_ddt_walk_q;
        entry_cnt_n             = entry_cnt_q;
        cause_n                 = cause_q;
        wait_rlast_n            = wait_rlast_q;
        device_id_n             = device_id_q;
        process_id_n            = process_id_q;
        dc_tc_n                 = dc_tc_q;
        dc_iohgatp_n            = dc_iohgatp_q;
        dc_ta_n                 = dc_ta_q;
        dc_fsc_n                = dc_fsc_q;
        pc_ta_n                 = pc_ta_q;
        pc_fsc_n                = pc_fsc_q;

        case (state_q)

            // check for possible misses in Context Directory Caches
            IDLE: begin
                // start with the level indicated by ddtp.MODE
                cdw_lvl_n       = level_t'(ddtp_mode_i);
                is_ddt_walk_n   = 1'b0;
                device_id_n     = req_did_i;
                entry_cnt_n     = '0;
                wait_rlast_n    = 1'b0;

                // check for DDTC misses
                // External logic guarantees that DDTC is looked up before PDTC
                if (init_cdw_i && !edge_trigger_q) begin
                    
                    is_ddt_walk_n = 1'b1;
                    state_n = MEM_ACCESS;

                    // load pptr according to ddtp.MODE
                    // 3LVL
                    if (ddtp_mode_i == 4'b0100)
                        // 56 = 44 + 9 + 3 
                        cdw_pptr_n = {ddtp_ppn_i, 
                                        ((MSITrans == rv_iommu::MSI_DISABLED) ? ({1'b0, req_did_i[23:16]}) : (req_did_i[23:15])), 
                                            3'b0};
                    // 2LVL
                    else if (ddtp_mode_i == 4'b0011)
                        cdw_pptr_n = {ddtp_ppn_i, 
                                        ((MSITrans == rv_iommu::MSI_DISABLED) ? (req_did_i[15:7]) : (req_did_i[14:6])), 
                                            3'b0};
                    // 1LVL
                    else if (ddtp_mode_i == 4'b0010)
                        cdw_pptr_n = {ddtp_ppn_i, 
                                        (MSITrans == rv_iommu::MSI_DISABLED) ? ({req_did_i[6:0], 5'b0}) : ({req_did_i[5:0], 6'b0})};
                end

                // check for PDTC misses
                if (pdtc_access_i && ~pdtc_hit_i) begin
                
                    process_id_n    = req_pid_i;
                    state_n         = MEM_ACCESS;
                    cdw_lvl_n       = level_t'(pdtp_mode_i + 4'd1);    // level enconding is different for PDT

                    // load pptr according to pdtp.MODE
                    // PD20
                    if (pdtp_mode_i == 4'b0011)
                        cdw_pptr_n = {pdtp_ppn_i, 6'b0, req_pid_i[19:17], 3'b0};    // ... aaaa 0000 00bb b000
                    // PD17
                    else if (pdtp_mode_i == 4'b0010)
                        cdw_pptr_n = {pdtp_ppn_i, req_pid_i[16:8], 3'b0};           // ... aaaa bbbb bbbb b000
                    // PD8
                    else if (pdtp_mode_i == 4'b0001)
                        cdw_pptr_n = {pdtp_ppn_i, req_pid_i[7:0], 4'b0};             // ... aaaa bbbb bbbb 0000
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
                        - Is a DDT lookup?
                        - Is Stage-2 enabled?
                        - Is the last level of the DDT/PDT?
                    */
                    case ({en_stage2_i, is_ddt_walk_q, is_last_cdw_lvl})
                        // rdata will hold the PPN of a non-leaf PDT/DDT entry
                        // Stage-2 is don't care for DC walks since iohgatp always provides a PPN
                        3'b000, 3'b010, 3'b110: begin
                            state_n = NON_LEAF;
                        end

                        // rdata will hold one of the doublewords of the PC/DC
                        // If stage-2 is enabled, only after loading all DC/PC DWs we have to translate pdtp.PPN if needed
                        3'b001, 3'b101, 3'b011, 3'b111: begin 
                            state_n = LEAF;
                        end

                        // rdata will hold the GPPN of a non-leaf PDT entry
                        // Must be first translated with second-stage translation
                        3'b100: begin
                            state_n = GUEST_TR;
                        end
                    endcase
                end
            end

            // Set pptr with the ppn of a non-leaf entry and the corresponding dev/proc ID segment
            // Always triggers a CDW memory access
            NON_LEAF: begin
                // we wait for the valid signal when coming from MEM_ACCESS
                // (DDT non-leaf entries or PDT entries when Stage-2 is disabled)
                // When coming from GUEST_TR, we wait for the translation to be completed or a fault to be raised
                if (mem_resp_i.r_valid || (ptw_done_i || flush_i)) begin

                    if (mem_resp_i.r_valid) mem_req_o.r_ready = 1'b1;

                    // "If ddte/pdte.V == 0, stop and report "DDT entry not valid" (cause = 258/266)"
                    if (!nl.v && mem_resp_i.r_valid) begin
                        state_n = ERROR;
                        if (is_ddt_walk_q) cause_n = rv_iommu::DDT_ENTRY_INVALID;
                        else cause_n = rv_iommu::PDT_ENTRY_INVALID;
                    end

                    // "If any bits or encoding that are reserved for future standard use are set within ddte/pdte,"
                    // "stop and report "DDT/pdte entry misconfigured" (cause = 259/267)"
                    else if (mem_resp_i.r_valid && ((|nl.reserved_1) || (|nl.reserved_2))) begin
                        state_n = ERROR;
                        if (is_ddt_walk_q) cause_n = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                        else cause_n = rv_iommu::PDT_ENTRY_MISCONFIGURED;
                    end

                    //# Valid non-leaf entry
                    else begin
                        // Set pptr and next level
                        // Different configs for DC and PC
                        // PDT PPN may come from second-stage translation (GUEST-TR)
                        case (cdw_lvl_q)
                            LVL3: begin
                                cdw_lvl_n = LVL2;
                                if (is_ddt_walk_q) cdw_pptr_n = {nl.ppn, 
                                                                    (MSITrans == rv_iommu::MSI_DISABLED) ? (device_id_q[15:7]) : (device_id_q[14:6]), 
                                                                        3'b0};
                                else begin 
                                    if (!en_stage2_i)   cdw_pptr_n = {nl.ppn, process_id_q[16:8], 3'b0};
                                    else                cdw_pptr_n = {pdt_ppn_i, process_id_q[16:8], 3'b0};
                                end
                            end

                            LVL2: begin
                                cdw_lvl_n = LVL1;
                                if (is_ddt_walk_q) cdw_pptr_n = {nl.ppn, 
                                                                    (MSITrans == rv_iommu::MSI_DISABLED) ? ({device_id_q[6:0], 5'b0}) : ({device_id_q[5:0], 6'b0})};
                                else begin 
                                    if (!en_stage2_i)   cdw_pptr_n = {nl.ppn, process_id_q[7:0], 4'b0};
                                    else                cdw_pptr_n = {pdt_ppn_i, process_id_q[7:0], 4'b0};
                                end
                            end

                            default:;
                        endcase

                        state_n = MEM_ACCESS;
                    end

                    // Abort walk and go to IDLE if PTW raised a second-stage translation error
                    // Error is signaled by PTW
                    if (flush_i)
                        state_n = IDLE;
                end
            end

            // rdata holds one of the doublewords of the DC/PC.
            // Here we check whether DC/PC has been fully loaded, if not, go back to MEM_ACCESS.
            // After having the DC/PC ready, check if second-stage translation is enabled to determine next state
            LEAF: begin

                // Comming from GUEST_TR, pdtp.PPN has been translated by the PTW. Must be first stored in DC reg.
                if (ptw_done_i) begin
                    dc_fsc_n.ppn = pdt_ppn_i;
                end

                // Last DW (When stage-2 is enabled we must verify if the DC has been updated with the translated pdtp.PPN)
                if ((is_ddt_walk_q && dc_fully_loaded && (ptw_done_q || !en_stage2_i || !dc_tc_q.pdtv)) || 
                    (!is_ddt_walk_q && pc_fully_loaded)) begin

                    state_n = IDLE;
                    // At this point we MUST have the entire DC/PC stored
                    // Update DDTC/PDTC
                    if (is_ddt_walk_q)  update_dc_o = 1'b1;
                    else                update_pc_o = 1'b1;
                end

                // Not last DW. Update counter, save DW
                else if (mem_resp_i.r_valid) begin

                    mem_req_o.r_ready   = 1'b1;
                    en_msi_check        = 1'b1;
                    entry_cnt_n         = entry_cnt_q + 1;
                    // Address is automatically incremented by AXI Bus

                    case ({is_ddt_walk_q, entry_cnt_q})

                        //PC.ta
                        4'b0000: begin
                            pc_ta_n = pc_ta;

                            // "If pdte.V == 0, stop and report "PDT entry not valid" (cause = 266)"
                            if (!pc_ta.v) begin
                                state_n         = ERROR;
                                cause_n         = rv_iommu::PDT_ENTRY_INVALID;
                                wait_rlast_n    = 1'b1;
                            end

                            // Config checks
                            if ((|pc_ta.reserved_1) || (|pc_ta.reserved_2)) begin
                                state_n         = ERROR;
                                cause_n         = rv_iommu::PDT_ENTRY_MISCONFIGURED;
                                wait_rlast_n    = 1'b1;
                            end
                        end

                        //PC.fsc (last DW)
                        4'b0001: begin
                            pc_fsc_n = pc_fsc;

                            // Config checks
                            if ((|pc_fsc.reserved) ||
                                (!(pc_fsc.mode inside {4'd0, 4'd8, 4'd9, 4'd10})) ||
                                (!dc_sxl_i && ((!caps_sv39_i && pc_fsc.mode == 4'd8) ||
                                                 (!caps_sv48_i && pc_fsc.mode == 4'd9) ||
                                                 (!caps_sv57_i && pc_fsc.mode == 4'd10))) ||
                                (dc_sxl_i && (!caps_sv32_i && pc_fsc.mode == 4'd8))) begin
                                state_n = ERROR;
                                cause_n = rv_iommu::PDT_ENTRY_MISCONFIGURED;
                            end
                        end

                        /*---------------------------------------------------------------*/

                        //DC.tc
                        4'b1000: begin
                            dc_tc_n = dc_tc;

                            // "If ddte.V == 0, stop and report "DDT entry not valid" (cause = 258)"
                            if (!dc_tc.v) begin
                                state_n = ERROR;
                                cause_n = rv_iommu::DDT_ENTRY_INVALID;
                                wait_rlast_n    = 1'b1;
                            end

                            // Config checks
                            if ((|dc_tc.reserved_1) || (|dc_tc.reserved_2) || 
                                (!caps_ats_i && (dc_tc.en_ats || dc_tc.en_pri || dc_tc.prpr)) ||
                                (!dc_tc.en_ats && (dc_tc.t2gpa || dc_tc.en_pri)) ||
                                (!dc_tc.en_pri && dc_tc.prpr) ||
                                (!dc_tc.pdtv && dc_tc.dpe) ||
                                (!caps_amo_hwad_i && (dc_tc.sade || dc_tc.gade)) ||
                                (fctl_be_i != dc_tc.sbe) ||
                                (dc_tc.sxl != fctl_gxl_i)) begin
                                state_n = ERROR;
                                cause_n = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                                wait_rlast_n    = 1'b1;
                            end
                        end

                        //DC.iohgatp
                        4'b1001: begin
                            dc_iohgatp_n = dc_iohgatp;

                            // Config checks
                            if ((dc_tc_q.t2gpa && !(|dc_iohgatp.mode)) ||
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
                        4'b1010: begin
                            dc_ta_n = dc_ta;

                            // Config checks
                            if ((|dc_ta.reserved_1) || (|dc_ta.reserved_2)) begin
                                state_n = ERROR;
                                cause_n = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                                wait_rlast_n    = 1'b1;
                            end
                        end

                        // DC.fsc (Last DW if MSI translation is not supported)
                        4'b1011: begin
                            dc_fsc_n = dc_fsc;

                            // Config checks
                            if ((dc_tc_q.pdtv && ((dc_fsc.mode inside {[4:15]}) ||
                                                   (!caps_pd20_i && dc_fsc.mode == 4'b0011     ) ||
                                                   (!caps_pd17_i && dc_fsc.mode == 4'b0010     ) ||
                                                   (!caps_pd8_i && dc_fsc.mode == 4'b0001      )
                                                  )) ||
                                (!dc_tc_q.pdtv && !dc_tc_q.sxl && (!(dc_fsc.mode inside {4'd0, 4'd8, 4'd9, 4'd10}) ||
                                                                    (!caps_sv39_i && dc_fsc.mode == 4'd8         ) ||
                                                                    (!caps_sv48_i && dc_fsc.mode == 4'd9         ) ||
                                                                    (!caps_sv57_i && dc_fsc.mode == 4'd10        )
                                                                   )) ||
                                (!dc_tc_q.pdtv && dc_tc_q.sxl && (!(dc_fsc.mode inside {4'd0, 4'd8}    ) ||
                                                                   (!caps_sv32_i && dc_fsc.mode == 4'd8)
                                                                  )) ||
                                (|dc_fsc.reserved)) begin

                                wait_rlast_n    = (MSITrans == rv_iommu::MSI_DISABLED) ? (1'b0) : (1'b1);
                                state_n         = ERROR;
                                cause_n         = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                            end

                            // MSI translation NOT supported
                            else if (MSITrans == rv_iommu::MSI_DISABLED) begin
                                // only if DC have an associated PC and Stage-2 is enabled, pdtp.PPN must be translated before being stored
                                // otherwise, fsc.PPN holds iosatp field, which must be saved as a GPA
                                if (en_stage2_i && dc_tc_q.pdtv)
                                    state_n = GUEST_TR;
                            end
                        end

                        // DC MSI fields
                        4'b1100, 4'b1101, 4'b1110: begin

                            if (translate_pdtp) begin
                                state_n = GUEST_TR;
                            end

                            if (msi_check_error) begin
                                
                                wait_rlast_n    = (entry_cnt_q != 3'b110);
                                state_n = ERROR;
                                cause_n = rv_iommu::DDT_ENTRY_MISCONFIGURED;
                            end
                        end
                        
                        default:;
                    endcase
                end

                // If an error occur in implicit second-stage translation, we abort the transaction and go back to idle
                if (flush_i)    state_n = IDLE;
            end

            // If Stage-2 is enabled, this state triggers the PTW to perform second-stage translation for pdtp.PPN or a non-leaf PDT GPPN
            // In the former case, we go to LEAF to update the corresponding CDTC entry
            // In the latter case, we go to NON-LEAF to set the CDW pptr with the non-leaf PPN.
            GUEST_TR: begin

                // We come from MEM_ACCESS (translate non-leaf PDT GPPN)
                if (!is_ddt_walk_q) begin

                    if(mem_resp_i.r_valid) begin

                        mem_req_o.r_ready   = 1'b1;

                        // When coming from MEM_ACCESS, the ppn to be translated is located in nl.ppn
                        // "If pdte.V == 0, stop and report "PDT entry not valid" (cause = 258/266)"
                        if (!nl.v) begin
                            state_n = ERROR;
                            cause_n = rv_iommu::PDT_ENTRY_INVALID;
                        end

                        // "If if any bits or encoding that are reserved for future standard use are set within ddte,"
                        // "stop and report "DDT entry misconfigured" (cause = 259)"
                        else if ((|nl.reserved_1) || (|nl.reserved_2)) begin
                            state_n = ERROR;
                            cause_n = rv_iommu::PDT_ENTRY_MISCONFIGURED;
                        end

                        // Set pdt_ppn with nl.ppn and trigger PTW
                        // NON_LEAF waits for the translation to be completed
                        else begin
                            pdt_gppn_o = nl.ppn[(riscv::GPPNW-1):0];
                            cdw_implicit_access_o = 1'b1;
                            state_n = NON_LEAF;
                        end
                    end
                end

                // We come from LEAF (pdtp.ppn)
                else begin

                    // Set pdt_ppn with DC.fsc.PPN (pdtp.ppn) and trigger PTW
                    pdt_gppn_o = dc_fsc_q.ppn[(riscv::GPPNW-1):0];
                    iohgatp_ppn_fw_o = dc_iohgatp_q.ppn;
                    cdw_implicit_access_o = 1'b1;
                    state_n = LEAF;
                end
            end

            // Permission/access errors detected. Propagate fault signal with error code
            ERROR: begin
                mem_req_o.r_ready   = 1'b1;     // Set RREADY to finish all transactions

                // Set cause code
                cause_code_o = cause_q;

                // Check whether we have to wait for AXI transmission to end
                if ((wait_rlast_q && mem_resp_i.r.last) || !wait_rlast_q) begin
                    cdw_error_o = 1'b1;
                    state_n     = IDLE;
                end
            end

            default: begin
                state_n = IDLE;
            end
        endcase

        // Check for AXI transmission errors
        if (mem_resp_i.r_valid && mem_resp_i.r.resp != axi_pkg::RESP_OKAY) begin
            update_dc_o     = 1'b0;
            update_pc_o     = 1'b0;
            wait_rlast_n    = ~mem_resp_i.r.last;

            // set cause code
            if (is_ddt_walk_q) cause_n = rv_iommu::DDT_DATA_CORRUPTION;
            else cause_n = rv_iommu::PDT_DATA_CORRUPTION;

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

    // MSI Translation Support
    generate
        
        // MSI translation supported
        if (MSITrans != rv_iommu::MSI_DISABLED) begin : gen_msi_support

            // Update wires
            rv_iommu::dc_ext_t              up_dc_content;

            // MSI Translation wires and registers
            rv_iommu::msiptp_t              dc_msiptp_q, dc_msiptp_n;
            rv_iommu::msi_addr_mask_t       dc_msi_addr_mask_q, dc_msi_addr_mask_n;
            rv_iommu::msi_addr_pattern_t    dc_msi_addr_patt_q, dc_msi_addr_patt_n;
            
            rv_iommu::msiptp_t              dc_msiptp;
            rv_iommu::msi_addr_mask_t       dc_msi_addr_mask;
            rv_iommu::msi_addr_pattern_t    dc_msi_addr_patt;

            always_comb begin : msi_config_checks

                // Default values
                // Wires
                msi_check_error     = 1'b0;
                translate_pdtp      = 1'b0;
                dc_msiptp           = rv_iommu::msiptp_t'(mem_resp_i.r.data);
                dc_msi_addr_mask    = rv_iommu::msi_addr_mask_t'(mem_resp_i.r.data);
                dc_msi_addr_patt    = rv_iommu::msi_addr_pattern_t'(mem_resp_i.r.data);

                up_dc_content.tc                = dc_tc_q;
                up_dc_content.iohgatp           = dc_iohgatp_q;
                up_dc_content.ta                = dc_ta_q;
                up_dc_content.fsc               = dc_fsc_q;
                up_dc_content.msi_addr_pattern  = dc_msi_addr_patt_q;
                up_dc_content.msi_addr_mask     = dc_msi_addr_mask_q;
                up_dc_content.msiptp            = dc_msiptp_q;
                up_dc_content.reserved          = '0;

                // Outputs
                up_dc_content_o = up_dc_content;

                // Next state values
                dc_msiptp_n         = dc_msiptp_q;
                dc_msi_addr_mask_n  = dc_msi_addr_mask_q;
                dc_msi_addr_patt_n  = dc_msi_addr_patt_q;

                if (en_msi_check) begin

                    case (entry_cnt_q)

                        // DC.msiptp
                        3'b100: begin
                            dc_msiptp_n = dc_msiptp;

                            // Config checks
                            if ((caps_msi_flat_i && |(dc_msiptp.mode & 4'b1110)) ||
                                (|dc_msiptp.reserved)) begin

                                msi_check_error = 1'b1;
                            end
                        end

                        // DC.msi_addr_mask
                        3'b101: begin
                            dc_msi_addr_mask_n = dc_msi_addr_mask;

                            // Config checks
                            if ((|dc_msi_addr_mask.reserved)) begin

                                msi_check_error = 1'b1;
                            end
                        end

                        // DC.msi_addr_pattern (last DW)
                        3'b110: begin
                            dc_msi_addr_patt_n = dc_msi_addr_patt;

                            // only if DC have an associated PC and Stage-2 is enabled, pdtp.PPN must be translated before being stored
                            // otherwise, fsc.PPN holds iosatp field, which must be saved as a GPA
                            if (en_stage2_i && dc_tc_q.pdtv) 
                                translate_pdtp = 1'b1;

                            // Config checks
                            if ((|dc_msi_addr_patt.reserved)) begin
                                
                                msi_check_error = 1'b1;
                            end
                        end
                        
                        default:;
                    endcase
                end
            end : msi_config_checks

            // sequential process
            always_ff @(posedge clk_i or negedge rst_ni) begin : msi_fields
                if (~rst_ni) begin
                    dc_msiptp_q         <= '0;
                    dc_msi_addr_mask_q  <= '0;
                    dc_msi_addr_patt_q  <= '0;

                end else begin
                    dc_msiptp_q         <= dc_msiptp_n;
                    dc_msi_addr_mask_q  <= dc_msi_addr_mask_n;
                    dc_msi_addr_patt_q  <= dc_msi_addr_patt_n;
                end
            end : msi_fields
        end : gen_msi_support

        // MSI translation NOT supported
        else begin : gen_msi_support_disabled

            // Output wires
            rv_iommu::dc_base_t up_dc_content;
            assign up_dc_content_o = up_dc_content;

            assign up_dc_content.tc         = dc_tc_q;
            assign up_dc_content.iohgatp    = dc_iohgatp_q;
            assign up_dc_content.ta         = dc_ta_q;
            assign up_dc_content.fsc        = dc_fsc_q;
                        
            assign msi_check_error     = 1'b0;
            assign translate_pdtp      = 1'b0;

        end : gen_msi_support_disabled
    endgenerate

    // sequential process
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            state_q                 <= IDLE;
            cdw_lvl_q               <= LVL1;
            cdw_pptr_q              <= '0;
            entry_cnt_q             <= '0;
            device_id_q             <= '0;
            process_id_q            <= '0;
            cause_q                 <= '0;
            is_ddt_walk_q           <= 1'b0;
            dc_tc_q                 <= '0;
            dc_iohgatp_q            <= '0;
            dc_ta_q                 <= '0;
            dc_fsc_q                <= '0;
            pc_ta_q                 <= '0;
            pc_fsc_q                <= '0;
            ptw_done_q              <= 1'b0;
            wait_rlast_q            <= 1'b0;
            edge_trigger_q          <= 1'b0;

        end else begin
            state_q                 <= state_n;
            cdw_pptr_q              <= cdw_pptr_n;
            cdw_lvl_q               <= cdw_lvl_n;
            entry_cnt_q             <= entry_cnt_n;
            device_id_q             <= device_id_n;
            process_id_q            <= process_id_n;
            cause_q                 <= cause_n;
            is_ddt_walk_q           <= is_ddt_walk_n;
            dc_tc_q                 <= dc_tc_n;
            dc_iohgatp_q            <= dc_iohgatp_n;
            dc_ta_q                 <= dc_ta_n;
            dc_fsc_q                <= dc_fsc_n;
            pc_ta_q                 <= pc_ta_n;
            pc_fsc_q                <= pc_fsc_n;
            ptw_done_q              <= ptw_done_i;
            wait_rlast_q            <= wait_rlast_n;
            edge_trigger_q          <= edge_trigger_n;
        end
    end

endmodule