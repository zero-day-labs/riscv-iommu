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
// Date:    09/12/2023
//
// Description: RISC-V IOMMU Memory-Resident Interrupt File Cache (MRIFC).
//              Fully-associative cache to store MSI PTEs in MRIF mode.

/*
    -   The RISC-V IOMMU specification defines that MSI translation must be done even if second-stage is Bare.
        This means that all GPAs processed by the IOMMU must undergo the MSI address check, without regard to the state of both translation stages

    -   When second-stage is not Bare, MSI PTEs are configured by a hypervisor for devices associated with guests.

    -   MSI translation in configurations with second-stage in Bare mode are likely used with devices associated with the host OS or
        in non-vistualized systems.

    -   As these MSI PTEs belong to different owners, the MRIFC must provide mechanisms to isolate entries with different second-stage configuration.

    -   Entries must be tagged with the second-stage configuration, so hits only occur when this configuration matches.
*/

module rv_iommu_mrifc #(
    parameter int unsigned  MRIFC_ENTRIES    = 4
)(
    input  logic            clk_i,          // Clock
    input  logic            rst_ni,         // Asynchronous reset active low

    // Flush signals
    input  logic                    flush_guest_i,  // Flush guest OSes entries
    input  logic                    flush_host_i,   // Flush entries associated to host OSes or non-v
    input  logic                    flush_av_i,     // Filter using GPA
    input  logic                    flush_gv_i,     // Filter using GSCID
    input  logic [riscv::GPPNW-1:0] flush_gppn_i,   // GPPN to be flushed
    input  logic [15:0]             flush_gscid_i,  // GSCID to be flushed

    // Update signals
    input  logic                    update_i,       // Update flag
    input  logic [riscv::GPPNW-1:0] up_gppn_i,      // GPPN tag
    input  logic [15:0]             up_gscid_i,     // GSCID tag
    input  rv_iommu::mrifc_entry_t  up_content_i,   // MSI PTE contents

    // Lookup signals
    input  logic                    lookup_i,       // Lookup flag
    input  logic                    lu_en_2S_i,     // Second-stage translation enabled
    input  logic [riscv::GPPNW-1:0] lu_gppn_i,      // GPPN tag
    input  logic [15:0]             lu_gscid_i,     // GSCID tag
    output logic                    lu_hit_o,       // Hit flag
    output rv_iommu::mrifc_entry_t  lu_content_o    // Lookup contents
);

    // Tags
    struct packed {
        logic [riscv::GPPNW-1:0]    gppn;   // GPPN 
        logic [15:0]                gscid;  // GSCID
        logic                       en_2S;  // Second-stage translation enabled
        logic                       valid;  // valid entry
    } [MRIFC_ENTRIES-1:0] tags_q, tags_n;

    // MRIFC entries: MSI PTEs in MRIF mode
    struct packed {
        logic [10:0]    nid;
        logic [44-1:0]  nppn;
        logic [47-1:0]  addr;
    } [MRIFC_ENTRIES-1:0] content_q, content_n;

    // Replacement logic
    logic [MRIFC_ENTRIES-1:0] lu_hit;       // to replacement logic
    logic [MRIFC_ENTRIES-1:0] replace_en;   // replace the following entry, set by replacement strategy

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

            for (int unsigned i = 0; i < MRIFC_ENTRIES; i++) begin
                
                // Entry match
                if ((tags_q[i].valid                                                ) &&    // valid
                    (tags_q[i].gppn == lu_gppn_i                                    ) &&    // GPA match
                    ((tags_q[i].gscid == lu_gscid_i && lu_en_2S_i) || !lu_en_2S_i   ) &&    // GSCID match
                    (tags_q[i].en_2S == lu_en_2S_i                                  )       // Stage match
                    ) begin
                
                    lu_content_o.addr   = content_q[i].addr;
                    lu_content_o.nppn   = content_q[i].nppn;
                    lu_content_o.nid    = content_q[i].nid;
                    lu_hit_o            = 1'b1;
                    lu_hit[i]           = 1'b1;
                end
            end
        end
    end

    // ------------------
    //# Update and Flush
    // ------------------
    always_comb begin : update_flush
        tags_n      = tags_q;
        content_n   = content_q;

        for (int unsigned i = 0; i < MRIFC_ENTRIES; i++) begin
            
            /*
                # MRIFC.INVAL_GUEST
                Invalidate MSI PTEs associated with guest OSes (second-stage enabled).
                When AV is set, only entries matching the input GPA will be invalidated.
                When GV is set, only entries matching the input GSCID will be invalidated.
                When any of these flags is set, all entries are invalidated.
            */
            if (flush_guest_i) begin
                
                unique case ({flush_gv_i, flush_av_i})

                    // Invalidate all entries associated with guest OSes
                    2'b00: begin
                        if (tags_q[i].en_2S) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end 

                    // GPA filter
                    2'b01: begin
                        if (tags_q[i].en_2S && tags_q[i].gppn == flush_gppn_i) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    
                    // GSCID filter
                    2'b10: begin
                        if (tags_q[i].en_2S && tags_q[i].gscid == flush_gscid_i) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end 
                    
                    // GPA and GSCID filter
                    2'b11: begin
                        if (tags_q[i].en_2S && tags_q[i].gppn == flush_gppn_i && tags_q[i].gscid == flush_gscid_i) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end 
                    
                    default: 
                endcase
            end

            /*
                # MRIFC.INVAL_HOST
                Invalidate MSI PTEs associated with the host OS or within a non-virtualized OS (second-stage disabled).
                When AV is set, only entries matching the input GPA will be invalidated.
                It does not makes sense to specify GSCID for entries associated with a Host OS or a non-virtualized OS.
                When AV is not set, all entries are invalidated.
            */
            else if (flush_host_i) begin
                
                // GPA filter
                if (flush_av_i) begin
                    if (!tags_q[i].en_2S && tags_q[i].gppn == flush_gppn_i) begin
                        tags_n[i].valid = 1'b0;
                    end
                end

                // Invalidate all entries associated to a host OS or non-v OS
                else begin
                    
                    if (!tags_q[i].en_2S) begin
                        tags_n[i].valid = 1'b0;
                    end
                end
            end

            // Entry replacement
            // only valid entries should be cached
            else if (update_i && replace_en[i]) begin
                
                // update tags
                tags_n[i] = '{
                    gppn:   up_gppn_i,
                    gscid:  up_gscid_i,
                    en_2S:  lu_en_2S_i,
                    valid:  1'b1
                };

                // update device context
                content_n[i].addr   = up_content_i.addr;
                content_n[i].nppn   = up_content_i.nppn;
                content_n[i].nid    = up_content_i.nid;
            end
        end
    end

    // -----------------------------------------------
    //# PLRU - Pseudo Least Recently Used Replacement
    // -----------------------------------------------
    
    logic[2*(MRIFC_ENTRIES-1)-1:0] plru_tree_q, plru_tree_n;
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
        // E.g. for a MRIFC with 8 entries, the for-loop is semantically
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
        for (int unsigned i = 0; i < MRIFC_ENTRIES; i++) begin
            automatic int unsigned idx_base, shift, new_index;
            // we got a hit so update the pointer as it was least recently used
            if (lu_hit[i] && lookup_i) begin      // LRU updated on LU hits and updates
                // Set the nodes to the values we would expect
                for (int unsigned lvl = 0; lvl < $clog2(MRIFC_ENTRIES); lvl++) begin  // 3 for 8 entries
                    idx_base = $unsigned((2**lvl)-1);     // 0 for lvl0, 1 for lvl1, 3 for lvl2
                    // lvl0 <=> MSB, lvl1 <=> MSB-1, ...
                    shift = $clog2(MRIFC_ENTRIES) - lvl;    // 3 for lvl0, 2 for lvl1, 1 for lvl2
                    // to circumvent the 32 bit integer arithmetic assignment
                    new_index =  ~((i >> (shift-1)) & 32'b1);
                    plru_tree_n[idx_base + (i >> shift)] = new_index[0];
                end
            end
        end
        // Decode tree to write enable signals
        // Next for-loop basically creates the following logic for e.g. an 8 entry
        // MRIFC (note: pseudo-code obviously):
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
        for (int unsigned i = 0; i < MRIFC_ENTRIES; i += 1) begin
            automatic logic en;
            automatic int unsigned idx_base, shift, new_index;
            en = 1'b1;
            for (int unsigned lvl = 0; lvl < $clog2(MRIFC_ENTRIES); lvl++) begin
                idx_base = $unsigned((2**lvl)-1);
                // lvl0 <=> MSB, lvl1 <=> MSB-1, ...
                shift = $clog2(MRIFC_ENTRIES) - lvl;

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
        assert ((MRIFC_ENTRIES % 2 == 0) && (MRIFC_ENTRIES > 1))
        else begin $error("MRIFC size must be a multiple of 2 and greater than 1"); $stop(); end
    end

    // Just for checking
    function int countSetBits(logic[MRIFC_ENTRIES-1:0] vector);
        automatic int count = 0;
        foreach (vector[idx]) begin
        count += vector[idx];
        end
        return count;
    endfunction

    assert property (@(posedge clk_i)(countSetBits(lu_hit) <= 1))
        else begin $error("More than one hit in MRIFC!"); $stop(); end
    assert property (@(posedge clk_i)(countSetBits(replace_en) <= 1))
        else begin $error("More than one MRIFC entry selected for next replace!"); $stop(); end

    `endif
    //pragma translate_on

endmodule