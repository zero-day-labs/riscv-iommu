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
// Date:    10/11/2022
//
// Description: RISC-V IOMMU Device Directory Table Cache (DDTC).
//              Fully-associative cache to store Device Contexts.

module rv_iommu_ddtc #(
    parameter int unsigned  DDTC_ENTRIES    = 4,
    parameter type dc_t                     = logic
)(
    input  logic            clk_i,          // Clock
    input  logic            rst_ni,         // Asynchronous reset active low

    // Flush signals
    input  logic            flush_i,        // IODIR.INVAL_DDT
    input  logic            flush_dv_i,     // device_id valid
    input  logic [23:0]     flush_did_i,    // device_id to be flushed

    // Update signals
    input  logic            update_i,       // update flag
    input  logic [23:0]     up_did_i,       // device ID to be inserted
    input  dc_t             up_content_i,   // DC to be inserted

    // Lookup signals
    input  logic            lookup_i,       // lookup flag
    input  logic [23:0]     lu_did_i,       // device_id to look for 
    output dc_t             lu_content_o,   // DC
    output logic            lu_hit_o        // hit flag
);

    //* Tags to identify DDTC entries
    // 24-bits device_id may be divided into up to three levels
    struct packed {
        logic [23:0]    device_id;  // device_id 
        logic           valid;      // valid bit
    } [DDTC_ENTRIES-1:0] tags_q, tags_n;

    //* DDTC entries: Device Contexts
    struct packed {
        dc_t dc;
    } [DDTC_ENTRIES-1:0] content_q, content_n;

    logic [DDTC_ENTRIES-1:0] lu_hit;     // to replacement logic
    logic [DDTC_ENTRIES-1:0] replace_en; // replace the following entry, set by replacement strategy

    //---------
    //# Lookup
    //---------
    always_comb begin : lookup

        // default assignment
        lu_hit         = '{default: 0};
        lu_hit_o       = 1'b0;
        lu_content_o   = '{default: 0};

        // To guarantee that hit signal is only set when we want to access the cache
        if (lookup_i) begin

            for (int unsigned i = 0; i < DDTC_ENTRIES; i++) begin
                
                // An entry match occurs if the entry is valid and if a device_id match occurs
                if (tags_q[i].valid && tags_q[i].device_id == lu_did_i) begin
                
                    lu_content_o    = content_q[i].dc;
                    lu_hit_o        = 1'b1;
                    lu_hit[i]       = 1'b1;
                end
            end
        end
    end

    // ------------------
    //# Update and Flush
    // ------------------

    /*
        # IODIR.INVAL_DDT
        IODIR.INVAL_DDT guarantees that any previous stores made by a RISC-V hart to the DDT are observed
        before all subsequent implicit reads from IOMMU to DDT. If DV is 0, then the command invalidates
        all DDT and PDT entries cached for all devices. If DV is 1, then the command invalidates cached leaf
        level DDT entry for the device identified by DID operand and all associated PDT entries.
    */

    always_comb begin : update_flush
        tags_n      = tags_q;
        content_n   = content_q;

        for (int unsigned i = 0; i < DDTC_ENTRIES; i++) begin
            
            // overall flush flag
            if (flush_i) begin
                
                // DV = 0: Invalidate all DDTC entries
                if (!flush_dv_i) begin
                    tags_n[i].valid = 1'b0;
                end

                // DV = 1: Invalidate only the DDTC entry that matches given device_id (and corresponding PDT entries)
                else if (tags_q[i].device_id == flush_did_i) begin
                    tags_n[i].valid = 1'b0;
                end
            end

            // normal replacement
            // only valid entries can be cached
            else if (update_i && replace_en[i] && up_content_i.tc.v) begin
                
                // update tags
                tags_n[i] = '{
                    device_id:  up_did_i,
                    valid:      1'b1
                };

                // update device context
                content_n[i].dc = up_content_i;
            end
        end 
    end

    // -----------------------------------------------
    //# PLRU - Pseudo Least Recently Used Replacement
    // -----------------------------------------------
    
    logic[2*(DDTC_ENTRIES-1)-1:0] plru_tree_q, plru_tree_n;
    always_comb begin : plru_replacement
        plru_tree_n = plru_tree_q;
        // The PLRU-tree indexing:
        // lvl0        0
        //            / \
        //           /   \
        // lvl1     1     2
        //         / \   / \
        // lvl2   3   4 5   6
        //       / \ /\/\  /\
        //      ... ... ... ...
        // Just predefine which nodes will be set/cleared
        // E.g. for a DDTC with 8 entries, the for-loop is semantically
        // equivalent to the following pseudo-code:
        // unique case (1'b1)
        // lu_hit[7]: plru_tree_n[0, 2, 6] = {1, 1, 1};
        // lu_hit[6]: plru_tree_n[0, 2, 6] = {1, 1, 0};
        // lu_hit[5]: plru_tree_n[0, 2, 5] = {1, 0, 1};
        // lu_hit[4]: plru_tree_n[0, 2, 5] = {1, 0, 0};
        // lu_hit[3]: plru_tree_n[0, 1, 4] = {0, 1, 1};
        // lu_hit[2]: plru_tree_n[0, 1, 4] = {0, 1, 0};
        // lu_hit[1]: plru_tree_n[0, 1, 3] = {0, 0, 1};
        // lu_hit[0]: plru_tree_n[0, 1, 3] = {0, 0, 0};
        // default: begin /* No hit */ end
        // endcase
        for (int unsigned i = 0; i < DDTC_ENTRIES; i++) begin
            automatic int unsigned idx_base, shift, new_index;
            // we got a hit so update the pointer as it was least recently used
            if (lu_hit[i] && lookup_i) begin      // LRU updated on LU hits and updates
                // Set the nodes to the values we would expect
                for (int unsigned lvl = 0; lvl < $clog2(DDTC_ENTRIES); lvl++) begin  // 3 for 8 entries
                    idx_base = $unsigned((2**lvl)-1);     // 0 for lvl0, 1 for lvl1, 3 for lvl2
                    // lvl0 <=> MSB, lvl1 <=> MSB-1, ...
                    shift = $clog2(DDTC_ENTRIES) - lvl;    // 3 for lvl0, 2 for lvl1, 1 for lvl2
                    // to circumvent the 32 bit integer arithmetic assignment
                    new_index =  ~((i >> (shift-1)) & 32'b1);
                    plru_tree_n[idx_base + (i >> shift)] = new_index[0];
                end
            end
        end
        // Decode tree to write enable signals
        // Next for-loop basically creates the following logic for e.g. an 8 entry
        // DDTC (note: pseudo-code obviously):
        // replace_en[7] = &plru_tree_q[ 6, 2, 0]; //plru_tree_q[0,2,6]=={1,1,1}
        // replace_en[6] = &plru_tree_q[~6, 2, 0]; //plru_tree_q[0,2,6]=={1,1,0}
        // replace_en[5] = &plru_tree_q[ 5,~2, 0]; //plru_tree_q[0,2,5]=={1,0,1}
        // replace_en[4] = &plru_tree_q[~5,~2, 0]; //plru_tree_q[0,2,5]=={1,0,0}
        // replace_en[3] = &plru_tree_q[ 4, 1,~0]; //plru_tree_q[0,1,4]=={0,1,1}
        // replace_en[2] = &plru_tree_q[~4, 1,~0]; //plru_tree_q[0,1,4]=={0,1,0}
        // replace_en[1] = &plru_tree_q[ 3,~1,~0]; //plru_tree_q[0,1,3]=={0,0,1}
        // replace_en[0] = &plru_tree_q[~3,~1,~0]; //plru_tree_q[0,1,3]=={0,0,0}
        // For each entry traverse the tree. If every tree-node matches,
        // the corresponding bit of the entry's index, this is
        // the next entry to replace.
        for (int unsigned i = 0; i < DDTC_ENTRIES; i += 1) begin
            automatic logic en;
            automatic int unsigned idx_base, shift, new_index;
            en = 1'b1;
            for (int unsigned lvl = 0; lvl < $clog2(DDTC_ENTRIES); lvl++) begin
                idx_base = $unsigned((2**lvl)-1);
                // lvl0 <=> MSB, lvl1 <=> MSB-1, ...
                shift = $clog2(DDTC_ENTRIES) - lvl;

                // en &= plru_tree_q[idx_base + (i>>shift)] == ((i >> (shift-1)) & 1'b1);
                new_index =  (i >> (shift-1)) & 32'b1;
                if (new_index[0]) begin
                    en &= plru_tree_q[idx_base + (i>>shift)];
                end else begin
                    en &= ~plru_tree_q[idx_base + (i>>shift)];
                end
            end
            replace_en[i] = en;
        end
    end

    // sequential process
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            tags_q      <= '{default: 0};
            content_q   <= '{default: 0};
            plru_tree_q <= '{default: 0};
        end
        else begin
            tags_q      <= tags_n;
            content_q   <= content_n;
            plru_tree_q <= plru_tree_n;
        end
    end

    //--------------
    // Sanity checks
    //--------------

    //pragma translate_off
    `ifndef VERILATOR

    initial begin : p_assertions
        assert ((DDTC_ENTRIES % 2 == 0) && (DDTC_ENTRIES > 1))
        else begin $error("DDTC size must be a multiple of 2 and greater than 1"); $stop(); end
    end

    // Just for checking
    function int countSetBits(logic[DDTC_ENTRIES-1:0] vector);
        automatic int count = 0;
        foreach (vector[idx]) begin
        count += vector[idx];
        end
        return count;
    endfunction

    assert property (@(posedge clk_i)(countSetBits(lu_hit) <= 1))
        else begin $error("More than one hit in DDTC!"); $stop(); end
    assert property (@(posedge clk_i)(countSetBits(replace_en) <= 1))
        else begin $error("More than one DDTC entry selected for next replace!"); $stop(); end

    `endif
    //pragma translate_on

endmodule