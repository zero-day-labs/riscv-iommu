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
    Date: 19/01/2023

    Description: RISC-V IOMMU Hardware CDW (Context Directory Walker).
*/

//# Disabled verilator_lint_off WIDTH

module iommu_cdw import ariane_pkg::*; #(
        parameter int unsigned DEVICE_ID_WIDTH = 24,
        parameter int unsigned PROCESS_ID_WIDTH  = 20,
        parameter ariane_pkg::ariane_cfg_t ArianeCfg = ariane_pkg::ArianeDefaultConfig
) (
    input  logic                    clk_i,                  // Clock
    input  logic                    rst_ni,                 // Asynchronous reset active low
    
    // Error signaling
    input  logic                                dtf_i,                  // DTF bit from DC. Disables reporting of translation process faults
    output logic                                cdw_active_o,           // Set when PTW is walking memory
    output logic                                cdw_error_o,            // set when an error occurred
    output logic [(iommu_pkg::CAUSE_LEN-1):0]   cause_code_o,           // Fault code as defined by IOMMU and Priv Spec
    // TODO: Integrate functional IOPMP

    // Leaf checks
    // DC checks
    input  logic        caps_ats_i,
    input  logic        caps_t2gpa_i,
    input  logic        caps_pd20_i, caps_pd17_i, caps_pd8_i,
    input  logic        caps_sv32_i, caps_sv39_i, caps_sv48_i, caps_sv57_i,
    input  logic        fctl_glx, caps_sv32x4_i, caps_sv39x4_i, caps_sv48x4_i, caps_sv57x4_i,
    input  logic        caps_msi_flat_i,
    input  logic        caps_amo_i,
    input  logic        caps_end_i, fctl_be_i,

    // PC checks
    input  logic        dc_sxl,

    // Indicate whether this translation was triggered by a store or a load
    input  logic                    is_store_i,

    // PTW memory interface
    input  dcache_req_o_t           mem_resp_i,             // Response port from memory
    output dcache_req_i_t           mem_req_o,              // Request port to memory

    // Update logic
    output  logic                           update_dc_o,
    output  logic [DEVICE_ID_WIDTH-1:0]     up_did_o,
    output  iommu_pkg::dc_ext_t             up_dc_content_o,

    output logic                            update_pc_o,
    output  logic [PROCESS_ID_WIDTH-1:0]    up_pid_o,
    output iommu_pkg::pc_t                  up_pc_content_o,

    // CDC tags
    input  logic [iommu_pkg::DEV_ID_MAX_LEN-1:0]  req_cid_i,    // device/process ID associated with request

    // from DDTC / PDTC, to monitor misses
    input  logic                        ddtc_access_i,
    input  logic                        ddtc_hit_i,

    input  logic                        pdtc_access_i,
    input  logic                        pdtc_hit_i,

    // from regmap
    input  logic [riscv::PPNW-1:0]  ddtp_ppn_i,     // PPN from ddtp register
    input  logic [3:0]              ddtp_mode_i,    // DDT levels and IOMMU mode

    // from DC (for PC walks)
    //! Similarly to the PTW, we only want to know if second stage is enabled. External logic should verify the scheme...
    input  logic                    en_stage2_i,    // Second-stage translation is enabled
    input  logic [riscv::PPNW-1:0]  pdtp_ppn_i,     // PPN from DC.fsc.PPN
    input  logic [3:0]              pdtp_mode_i,    // PDT levels from DC.fsc.MODE

    // TODO: include HPM
    // // Performance counters
    // output logic                    itlb_miss_o,
    // output logic                    dtlb_miss_o,

    // (IO)PMP
    input  riscv::pmpcfg_t [15:0]           conf_reg_i,
    input  logic [15:0][riscv::PLEN-3:0]    addr_reg_i,
    output logic [riscv::PLEN-1:0]         bad_paddr_o    // to return the SPA in case of access error
);

    // input registers to receive data from memory
    logic data_rvalid_q;
    logic [63:0] data_rdata_q;

    // DC/PC Update register
    iommu_pkg::dc_ext_t dc_q, dc_n;
    iommu_pkg::pc_t pc_q, pc_n;

    // Cast read port to corresponding data structure
    iommu_pkg::nl_entry_t nl;
    iommu_pkg::tc_t dc_tc;
    iommu_pkg::iohgatp_t dc_iohgatp;
    iommu_pkg::dc_ta_t dc_ta;
    iommu_pkg::fsc_t dc_fsc;
    iommu_pkg::msiptp_t dc_msiptp;
    iommu_pkg::msi_addr_mask_t dc_msi_addr_mask;
    iommu_pkg::msi_addr_pattern_t dc_msi_addr_patt;
    iommu_pkg::pc_ta_t pc_ta;
    iommu_pkg::fsc_t pc_fsc;

    assign dc_tc = iommu_pkg::tc_t'(data_rdata_q);
    assign dc_iohgatp = iommu_pkg::iohgatp_t'(data_rdata_q);
    assign dc_ta = iommu_pkg::dc_ta_t'(data_rdata_q);
    assign dc_fsc = iommu_pkg::fsc_t'(data_rdata_q);
    assign dc_msiptp = iommu_pkg::msiptp_t'(data_rdata_q);
    assign dc_msi_addr_mask = iommu_pkg::msi_addr_mask_t'(data_rdata_q);
    assign dc_msi_addr_patt = iommu_pkg::msi_addr_pattern_t'(data_rdata_q);
    assign pc_ta = iommu_pkg::pc_ta_t'(data_rdata_q);
    assign pc_fsc = iommu_pkg::fsc_t'(data_rdata_q);

    //! Nope, DC is 8-DW wide, PC is 2-DW wide, and CVA6 read bursts are 64-bits wide. Read is performed sequentially in the FSM
    // assign dc = iommu_pkg::dc_ext_t'(data_rdata_q);
    // assign pc = iommu_pkg::pc_t'(data_rdata_q);

    assign nl = iommu_pkg::nl_entry_t'(data_rdata_q);
    

    // PTW states
    typedef enum logic[2:0] {
      IDLE,
      MEM_ACCESS,
      NON_LEAF,
      LEAF,
      GUEST_TR,
      ERROR
    } state_t;
    
    state_t state_q, state_n;

    // IOMMU mode and DDT/PDT levels
    typedef enum logic [1:0] {
        OFF, BARE, LVL1, LVL2, LVL3
    } level_t;
    
    level_t cdw_lvl_q, cdw_lvl_n;

    // Propagate miss source to update later
    logic is_ddt_walk_q, is_ddt_walk_n;

    // latched tag signal
    logic tag_valid_n,      tag_valid_q;

    // Save and propagate the input device_id/process id to walk multiple levels
    logic [iommu_pkg::DEV_ID_MAX_LEN-1:0] context_id_q, context_id_n;

    // Physical pointer to access memory bus
    logic [riscv::PLEN-1:0] cdw_pptr_q, cdw_pptr_n;

    // Last DDT/PDT level
    logic is_last_cdw_lvl;

    // It's not possible to load the entire DC/PC in one request.
    // Aux counter to know how many DWs we have loaded
    // 3-bit wide since we are not counting the reserved DW of the DC
    logic [2:0] entry_cnt_q, entry_cnt_n;
    logic dc_fully_loaded, pc_fully_loaded;

    // Cause propagation
    logic [(iommu_pkg::CAUSE_LEN-1):0] cause_q, cause_n;

    // PTW walking
    assign cdw_active_o    = (state_q != IDLE);
    // Last CDW level
    assign is_last_cdw_lvl = (cdw_lvl_q == LVL1);
    // Determine whether we have loaded the entire DC/PC
    assign dc_fully_loaded = (entry_cnt_q == 3'b111);  // extended format w/out reserved DW (64-8 = 56 bytes)
    assign pc_fully_loaded = (entry_cnt_q == 3'b010);  // always 16-bytes

    // Memory bus
    // directly output the correct physical address
    assign mem_req_o.address_index = cdw_pptr_q[DCACHE_INDEX_WIDTH-1:0];
    assign mem_req_o.address_tag   = cdw_pptr_q[DCACHE_INDEX_WIDTH+DCACHE_TAG_WIDTH-1:DCACHE_INDEX_WIDTH];
    // we are never going to kill this request
    assign mem_req_o.kill_req      = '0;
    // we are never going to write with the HPTW
    assign mem_req_o.data_wdata    = 64'b0;

    // -------------------
    //# DDTC / PDTC Update
    // -------------------
    assign up_did_o = context_id_q;
    assign up_dc_content_o = dc_q;
    assign up_pid_o = context_id_q;
    assign up_pc_content_o = pc_q;

    assign req_port_o.tag_valid      = tag_valid_q;

    // # IOPMP
    logic allow_access;
    logic is_access_err_q, is_access_err_n;

    // TODO: Insert functional IOPMP. Only PMP and PMP entry modules are actually considered
    pmp #(
        .PLEN       ( riscv::PLEN            ),
        .PMP_LEN    ( riscv::PLEN - 2        ),
        .NR_ENTRIES ( ArianeCfg.NrPMPEntries )  // 8 entries by default
    ) i_pmp_ptw (
        .addr_i         ( cdw_pptr_q         ),
        .priv_lvl_i     ( riscv::PRIV_LVL_S  ), // PTW access are always checked as if in S-Mode
        .access_type_i  ( riscv::ACCESS_READ ), // PTW only reads
        // Configuration
        .addr_reg_i     ( addr_reg_i         ), // address register
        .conf_reg_i     ( conf_reg_i         ), // config register
        .allow_o        ( allow_access       )
    );

    //# Page table walker
    always_comb begin : ptw
        automatic logic [riscv::PLEN-1:0] pptr;
        automatic logic [riscv::GPLEN-1:0] gpaddr;
        // default assignments
        // PTW memory interface
        tag_valid_n            = 1'b0;
        mem_req_o.data_req     = 1'b0;
        mem_req_o.data_be      = 8'hFF;
        mem_req_o.data_size    = 2'b11;
        mem_req_o.data_we      = 1'b0;
        cdw_error_o            = 1'b0;
        cause_code_o           = '0;
        bad_paddr_o            = '0;
        update_dc_o            = 1'b0;
        update_pc_o            = 1'b0;

        cdw_lvl_n              = cdw_lvl_q;
        cdw_pptr_n             = cdw_pptr_q;
        state_n                = state_q;
        is_ddt_walk_n          = is_ddt_walk_q;
        entry_cnt_n            = entry_cnt_q;
        is_access_err_n        = is_access_err_q;
        cause_n                = cause_q;
        context_id_n           = context_id_q;
        dc_n                   = dc_q;
        pc_n                   = pc_q;

        // itlb_miss_o           = 1'b0;
        // dtlb_miss_o           = 1'b0;

        case (state_q)

            // check for possible misses in Context Directory Caches
            IDLE: begin
                // start with the level indicated by ddtp.MODE
                cdw_lvl_n       = level_t'(ddtp_mode_i);
                is_ddt_walk_n   = 1'b0;
                context_id_n    = req_cid_i;
                entry_cnt_n     = '0;

                // check for DDTC misses
                //! Simultaneous accesses may occur in the DDTC and PDTC. We need DC to find PC, so first walk DDT.
                if (ddtc_access_i && ~ddtc_hit_i) begin
                    
                    is_ddt_walk_n = 1'b1;
                    state_n = MEM_ACCESS;
                    // ddtc_miss_o        = 1'b1;     // to HPM

                    // load pptr according to ddtp.MODE
                    // 3LVL
                    if (ddtp_mode_i == 4'b0100)
                        cdw_pptr_n = {ddtp_ppn_i, req_cid_i[23:15], 3'b0};
                    // 2LVL
                    else if (ddtp_mode_i == 4'b0011)
                        cdw_pptr_n = {ddtp_ppn_i, req_cid_i[14:6], 3'b0};
                    // 1LVL
                    else if (ddtp_mode_i == 4'b0010)
                        cdw_pptr_n = {ddtp_ppn_i, req_cid_i[5:0], 6'b0};
                end

                // check for PDTC misses
                else if (pdtc_access_i && ~pdtc_hit_i && ~ddtc_access_i) begin
                    
                    state_n = MEM_ACCESS;
                    cdw_lvl_n       = level_t'(pdtp_mode_i + 1);    // level enconding is different for PDT
                    // pdtc_miss_o        = 1'b1;     // to HPM

                    // load pptr according to pdtp.MODE
                    // PD20
                    if (pdtp_mode_i == 4'b0011)
                        cdw_pptr_n = {pdtp_ppn_i, 6'b0, req_cid_i[19:17], 3'b0};    // ... aaaa 0000 00bb b000
                    // PD17
                    else if (pdtp_mode_i == 4'b0010)
                        cdw_pptr_n = {pdtp_ppn_i, req_cid_i[16:8], 3'b0};           // ... aaaa bbbb bbbb b000
                    // PD8
                    else if (pdtp_mode_i == 4'b0001)
                        cdw_pptr_n = {pdtp_ppn_i,req_cid_i[7:0], 4'b0};             // ... aaaa bbbb bbbb 0000
                end
            end

            // perform memory access with address hold in cdw_pptr_q
            MEM_ACCESS: begin
                // send request to memory
                mem_req_o.data_req = 1'b1;
                // wait for the MEM_ACCESS
                if (mem_resp_i.data_gnt) begin
                    // send the tag valid signal to request bus, one cycle later
                    tag_valid_n = 1'b1;

                    // decode next state
                    /*
                        Control signals:
                        - Is a DDT lookup?
                        - Is Stage-2 enabled?
                        - Is the last level of the DDT/PDT?
                        - Is the DC/PC fully loaded?
                    */
                    case ({en_stage2_i, is_ddt_walk_q, is_last_cdw_lvl})
                        // rdata will hold the PPN of a non-leaf PDT/DDT entry
                        // Stage-2 is don't care for DC walks since iohgatp always provides a PPN
                        3'b000, 3'b010, 3'b110: begin
                            state_n = NON_LEAF;
                        end

                        // rdata will hold one of the doublewords of the PC/DC
                        // Since Stage-2 is disabled, there's no need to translate fsc.PPN
                        // We can go to LEAF to update DDTC/PDTC
                        3'b001, 3'b011: begin 
                            state_n = LEAF;
                        end

                        // rdata will hold the GPPN of a non-leaf PDT entry
                        // Must be first translated with second-stage translation
                        3'b100: begin
                            state_n = GUEST_TR;
                        end

                        // rdata will hold one of the doublewords of the DC/PC.
                        // Stage-2 is enabled, so only after loading all DC/PC DWs we have to translate fsc.ppn
                        3'b101, 3'b111: begin
                            state_n = LEAF;
                        end

                        default: begin
                            state_n = IDLE;
                        end
                    endcase
                end
            end

            // Set pptr with the ppn of a non-leaf entry and the corresponding dev/proc ID segment
            // Always triggers a CDW memory access
            NON_LEAF: begin
                // we wait for the valid signal
                if (data_rvalid_q) begin

                    // "If ddte/pdte.V == 0, stop and report "DDT entry not valid" (cause = 258/266)"
                    if (!nl.v) begin
                        state_n = ERROR;
                        if (is_ddt_walk_q) cause_n = iommu_pkg::DDT_ENTRY_INVALID;
                        else cause_n = iommu_pkg::PDT_ENTRY_INVALID;
                    end

                    //# Valid non-leaf entry
                    else begin
                        // Set pptr and next level
                        // Different configs for DC and PC
                        case (cdw_lvl_q)
                            LVL3: begin
                                cdw_lvl_n = LVL2;
                                if (is_ddt_walk_q) cdw_pptr_n = {nl.ppn, context_id_q[14:6], 3'b0};
                                else cdw_pptr_n = {nl.ppn, context_id_q[16:8], 3'b0};
                            end

                            LVL2: begin
                                cdw_lvl_n = LVL1;
                                if (is_ddt_walk_q) cdw_pptr_n = {nl.ppn, context_id_q[5:0], 6'b0};
                                else cdw_pptr_n = {nl.ppn, context_id_q[7:0], 4'b0};
                            end

                            default:
                        endcase

                        state_n = MEM_ACCESS;
                    end

                    // "If if any bits or encoding that are reserved for future standard use are set within ddte,"
                    // "stop and report "DDT entry misconfigured" (cause = 259)"
                    if (nl.reserved_1 || nl.reserved_2) begin
                        state_n = ERROR;
                        cause_n = iommu_pkg::DDT_ENTRY_MISCONFIGURED;
                    end
                end
            end

            // rdata holds one of the doublewords of the DC/PC.
            // Here we check whether DC/PC has been fully loaded, if not, go back to MEM_ACCESS.
            // After having the DC/PC ready, check if second-stage translation is enabled to determine next state
            LEAF: begin

                // Last DW
                //! When coming from GUEST_TR, these conditions should be fulfilled
                if ((is_ddt_walk_q && dc_fully_loaded) || (!is_ddt_walk_q && pc_fully_loaded)) begin
                    
                    state_n = IDLE;
                    // At this point we MUST have the entire DC/PC stored
                    // If Stage-2 is disabled or fsc.PPN has already been translated, update DDTC/PDTC
                    //! Guarantee that translated PPN is already in DC/PC register when coming from GUEST_TR
                    if (is_ddt_walk_q) update_dc_o = 1'b1;
                    else update_pc_o = 1'b1;
                end

                // Not last DW. Update counter and pptr, save DW
                else if (data_rvalid_q ) begin

                    entry_cnt_n = entry_cnt_q + 1;

                    // Set pptr with address for next DW
                    cdw_pptr_n = cdw_pptr_q + 8;
                    state_n = MEM_ACCESS;

                    case ({is_ddt_walk_q, entry_cnt_q})

                        //PC.ta
                        4'b0000: begin
                            pc_n.ta = pc_ta;

                            // "If pdte.V == 0, stop and report "PDT entry not valid" (cause = 266)"
                            if (!pc_ta.v) begin
                                state_n = ERROR;
                                cause_n = iommu_pkg::PDT_ENTRY_INVALID;
                            end
                        end

                        //PC.fsc (last DW)
                        4'b0001: begin
                            pc_n.fsc = pc_fsc;
                            cdw_pptr_n = cdw_pptr_q;
                            if (en_stage2_i) state_n = GUEST_TR;
                            else state_n = LEAF;
                        end

                        /*---------------------------------------------*/

                        //DC.tc
                        4'b1000: begin
                            dc_n.tc = dc_tc;

                            // "If ddte.V == 0, stop and report "DDT entry not valid" (cause = 258)"
                            if (!dc_tc.v) begin
                                state_n = ERROR;
                                cause_n = iommu_pkg::DDT_ENTRY_INVALID;
                            end
                        end

                        //DC.iohgatp
                        4'b1001: begin
                            dc_n.iohgatp = dc_iohgatp;
                        end

                        //DC.ta
                        4'b1010: begin
                            dc_n.ta = dc_ta;
                        end

                        //DC.fsc
                        4'b1011: begin
                            dc_n.fsc = dc_fsc;
                        end

                        //DC.msiptp
                        4'b1100: begin
                            dc_n.msiptp = dc_msiptp;
                        end

                        //DC.msi_addr_mask
                        4'b1101: begin
                            dc_n.msi_addr_mask = dc_msi_addr_mask;
                        end

                        //DC.msi_addr_pattern (last DW)
                        4'b1110: begin
                            dc_n.msi_addr_pattern = dc_msi_addr_patt;
                            cdw_pptr_n = cdw_pptr_q;
                            if (en_stage2_i) state_n = GUEST_TR;
                            else state_n = LEAF;
                        end

                        default:
                    endcase
                end
            end

            // If Stage-2 is enabled, this state triggers the PTW to perform second-stage translation for fsc.PPN or a non-leaf PDT GPPN
            // In the former case, we go to LEAF to update the corresponding CDTC entry
            // In the latter case, we go to NON-LEAF to set the CDW pptr with the non-leaf PPN.
            GUEST_TR: begin
                // we wait for the valid signal
                if (data_rvalid_q) begin
                    
                end
            end

            // Permission/access errors detected. Propagate fault signal with error code
            ERROR: begin
                cdw_error_o = 1'b1;

                // Return SPA for access errors
                if (is_access_err_q) bad_paddr_o = cdw_pptr_q;

                // Set cause code
                cause_code_o = cause_q;
                state_n = IDLE;
            end

            default: begin
                state_n = IDLE;
            end
        endcase

        // Check if mem access was actually allowed from a PMP perspective
        //! Access errors caused by second-stage implicit translations are signaled by the PTW.
        //! PTW and CDW must sync in these cases.
        if (!allow_access && (state_q == NON_LEAF || state_q == LEAF || state_q == GUEST_TR)) begin
            update_dc_o = 1'b0;
            update_pc_o = 1'b0;
            is_access_err_n'= 1'b1;

            // set cause code
            if (is_ddt_walk_q) cause_n = iommu_pkg::DDT_ENTRY_LD_ACCESS_FAULT;
            else cause_n = iommu_pkg::PDT_ENTRY_LD_ACCESS_FAULT;

            // return faulting address in bad_addr
            cdw_pptr_n = cdw_pptr_q;
            state_q = ERROR;
        end
    end

    // sequential process
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            state_q                 <= IDLE;
            cdw_lvl_q               <= LVL1;
            tag_valid_q             <= 1'b0;
            cdw_pptr_q              <= '0;
            data_rdata_q            <= '0;
            data_rvalid_q           <= 1'b0;
            entry_cnt_q             <= '0;
            context_id_q            <= '0;
            cause_q                 <= '0;
            is_ddt_walk_q           <= 1'b0;
            dc_q                    <= '0;
            pc_q                    <= '0;

        end else begin
            state_q                 <= state_n;
            cdw_pptr_q              <= cdw_pptr_n;
            cdw_lvl_q               <= cdw_lvl_n;
            tag_valid_q             <= tag_valid_n;
            data_rdata_q            <= mem_resp_i.data_rdata;
            data_rvalid_q           <= mem_resp_i.data_rvalid;
            entry_cnt_q             <= entry_cnt_n;
            context_id_q            <= context_id_n;
            cause_q                 <= cause_n;
            is_access_err_q         <= is_access_err_n;
            is_ddt_walk_q           <= is_ddt_walk_n;
            dc_q                    <= dc_n;
            pc_q                    <= pc_n;
        end
    end

endmodule
//# Disabled verilator_lint_on WIDTH
