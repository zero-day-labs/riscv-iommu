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
// Date:    04/11/2022
// Acknowledges: SSRC - Technology Innovation Institute (TII)
//
// Description: RISC-V IOMMU Memory-Resident Interrupt File Cache (MRIFC).
//              Fully-associative cache to store MSI PTEs in MRIF mode and the first-stage PTEs that map GVA to them.

/*
    -   The RISC-V IOMMU specification defines that MSI translation must be done even if second-stage is Bare.
        This means that all GPAs processed by the IOMMU must undergo the MSI address check, without regard to the state of second-state translation

    -   When second-stage is not Bare, MSI PTEs are configured by a hypervisor for devices associated with guests.

    -   MSI translation in configurations with second-stage in Bare mode are likely used with devices associated with the host OS or
        in non-virtualized systems.

    -   If first-stage translation is enabled, this cache stores all first-stage PTEs that map to GPAs of guest MRIFs.
        Thus, the IOTINVAL.VMA and IOTINVAL.GVMA commands also affect this cache, and entries are tagged with IOVA, GSCID and PSCID.
*/

module rv_iommu_mrifc #(
    parameter int unsigned  MRIFC_ENTRIES    = 4
)(
    input  logic            clk_i,          // Clock
    input  logic            rst_ni,         // Asynchronous reset active low

    // Flush signals
    input  logic                    flush_vma_i,      // IOTINVAL.VMA
    input  logic                    flush_gvma_i,     // IOTINVAL.GVMA
    input  logic                    flush_av_i,       // ADDR tag filtering
    input  logic                    flush_gv_i,       // GSCID tag filtering
    input  logic                    flush_pscv_i,     // PSCID tag filtering
    input  logic [riscv::GPPNW-1:0] flush_vpn_i,      // VPN/GPPN to be flushed
    input  logic [15:0]             flush_gscid_i,    // GSCID to be flushed
    input  logic [19:0]             flush_pscid_i,    // PSCID to be flushed

    // Update signals
    input  logic                    update_i,
    input  logic                    up_1S_2M_i,
    input  logic                    up_1S_1G_i,
    input  logic [riscv::GPPNW-1:0] up_vpn_i,
    input  logic [19:0]             up_pscid_i,
    input  logic [15:0]             up_gscid_i,
    input  riscv::pte_t             up_1S_content_i,
    input  rv_iommu::mrifc_entry_t  up_msi_content_i,   // MSI PTE contents

    // Lookup signals
    input  logic                    lookup_i,           // lookup flag
    input  logic [riscv::VLEN-1:0]  lu_iova_i,          // IOVA to look for 
    input  logic [19:0]             lu_pscid_i,         // PSCID to look for
    input  logic [15:0]             lu_gscid_i,         // GSCID to look for
    input  logic                    en_1S_i,            // first-stage enabled
    input  logic                    en_2S_i,            // second-stage enabled
    output logic                    lu_hit_o,           // hit flag
    output logic                    lu_miss_o,          // miss flag
    output riscv::pte_t             lu_1S_content_o,    // first-stage PTE
    output rv_iommu::mrifc_entry_t  lu_msi_content_o    // MSI PTE
);

    // Tags
    struct packed {
        logic [10:0]    vpn2;       // 3-level VPN (VPN[2] is the segment extended by two bits in Sv39x4)
        logic [8:0]     vpn1;
        logic [8:0]     vpn0;
        logic [19:0]    pscid;      // process address space identifier
        logic [15:0]    gscid;      // virtual machine identifier
        logic           is_1S_2M;   // first-stage 2MiB superpage: VPN[0] makes part of the offset
        logic           is_1S_1G;   // first-stage 1GiB superpage: VPN[0,1] makes part of the offset
        logic           en_1S;      // first-stage translation enable
        logic           en_2S;      // second-stage translation enable
        logic           valid;      // valid bit
    } [MRIFC_ENTRIES-1:0] tags_q, tags_n;

    // MRIFC entries: MSI PTEs in MRIF mode
    struct packed {
        riscv::pte_t            pte_1S;     // first-stage data
        rv_iommu::mrifc_entry_t msi_pte;    // MSI PTE in MRIF mode
    } [MRIFC_ENTRIES-1:0] content_q, content_n;

    logic [8:0] vpn0, vpn1;
    logic [10:0] vpn2;
    logic [MRIFC_ENTRIES-1:0] match_gscid;
    logic [MRIFC_ENTRIES-1:0] match_pscid;
    logic [MRIFC_ENTRIES-1:0] match_stage;

    // Replacement logic
    logic [MRIFC_ENTRIES-1:0] lu_hit;       // to replacement logic
    logic [MRIFC_ENTRIES-1:0] replace_en;   // replace the following entry, set by replacement strategy

    //---------
    //# Lookup
    //---------
    always_comb begin : lookup

        // Default Assignments
        // Wires
        vpn0 = lu_iova_i[20:12];
        vpn1 = lu_iova_i[29:21];
        vpn2 = lu_iova_i[40:30];

        match_pscid     = '{default: 0};
        match_gscid     = '{default: 0};
        match_stage     = '{default: 0};
        lu_hit          = '{default: 0};

        // Output signals
        lu_hit_o            = 1'b0;
        lu_miss_o           = lookup_i;
        lu_1S_content_o     = '{default: 0};
        lu_msi_content_o    = '{default: 0};

        for (int unsigned i = 0; i < MRIFC_ENTRIES; i++) begin
            
            // PSCID check is skipped for lookups with first-stage disabled
            // If first-stage is enabled, only PSCID matches and global entries match
            match_pscid[i] = (((lu_pscid_i == tags_q[i].pscid) || content_q[i].pte_1S.g) && en_1S_i) || !en_1S_i;

            // GSCID check is skipped for lookups with second-stage disabled
            // If second-stage is active, only GSCID matches will indicate entry match
            match_gscid[i] = (lu_gscid_i == tags_q[i].gscid && en_2S_i) || !en_2S_i;

            // Check enabled stages
            match_stage[i] = (tags_q[i].en_2S == en_2S_i) && (tags_q[i].en_1S == en_1S_i);
            
            // An entry match occurs if the entry is valid, if GSCID and PSCID matches, if translation stages matches, and VPN[2] matches
            if (tags_q[i].valid && match_pscid[i] && match_gscid[i] && match_stage[i] && (vpn2 == tags_q[i].vpn2)) begin
                
                // 1G match | 2M match | 4k match
                if ((tags_q[i].is_1S_1G && tags_q[i].en_1S) || 
                    ((vpn1 == tags_q[i].vpn1) && 
                        ((tags_q[i].is_1S_2M && tags_q[i].en_1S) || vpn0 == tags_q[i].vpn0))) begin
                    
                    lu_1S_content_o     = content_q[i].pte_1S;
                    lu_msi_content_o    = content_q[i].msi_pte;
                    lu_hit_o            = lookup_i;
                    lu_miss_o           = 1'b0;
                    lu_hit[i]           = 1'b1;
                end
            end
        end
    end

    // ------------------
    //# Update and Flush
    // ------------------

    logic  [MRIFC_ENTRIES-1:0] gvaddr_vpn0_match;
    logic  [MRIFC_ENTRIES-1:0] gvaddr_vpn1_match;
    logic  [MRIFC_ENTRIES-1:0] gvaddr_vpn2_match;
    logic  [MRIFC_ENTRIES-1:0] gvaddr_2M_match;
    logic  [MRIFC_ENTRIES-1:0] gvaddr_1G_match;
    logic  [MRIFC_ENTRIES-1:0] gpaddr_gppn0_match;
    logic  [MRIFC_ENTRIES-1:0] gpaddr_gppn1_match;
    logic  [MRIFC_ENTRIES-1:0] gpaddr_gppn2_match;
    /*
        !NOTE: 
        For IOTINVAL.GVMA commands, any entry whose GVA maps to a GPA that matches 
        the given address in the ADDR field, and also matches the GSCID field, must be invalidated.
        This requires tagging entries with the GPA, which is hardware costly. A common implementation
        invalidates all entries that match the GSCID field.

        This implementation assumes the HW cost and performs the IOTINVAL.GVMA completely.
    */
    logic  [MRIFC_ENTRIES-1:0] [(riscv::GPPNW-1):0] gppn;

    always_comb begin : update_flush

        tags_n    = tags_q;
        content_n = content_q;

        for (int unsigned i = 0; i < MRIFC_ENTRIES; i++) begin

            // check if given GVA (39-bits) matches VPN tag
            gvaddr_vpn0_match[i] = (flush_vpn_i[8:0] == tags_q[i].vpn0);
            gvaddr_vpn1_match[i] = (flush_vpn_i[17:9] == tags_q[i].vpn1);
            gvaddr_vpn2_match[i] = (flush_vpn_i[26:18] == tags_q[i].vpn2[8:0]);

            // first-stage superpage cases
            gvaddr_2M_match[i] = (gvaddr_vpn2_match[i] && gvaddr_vpn1_match[i] && tags_q[i].is_1S_2M);
            gvaddr_1G_match[i] = (gvaddr_vpn2_match[i] && tags_q[i].is_1S_1G);

            // construct GPA's PPN according to first-stage pte data
            gppn[i] = rv_iommu::make_gppn(tags_q[i].en_1S, tags_q[i].is_1S_1G, tags_q[i].is_1S_2M, {tags_q[i].vpn2,tags_q[i].vpn1,tags_q[i].vpn0}, content_q[i].pte_1S);
            
            // check if given GPA matches with any tag
            gpaddr_gppn0_match[i] = (flush_vpn_i[8:0] == gppn[i][8:0]);
            gpaddr_gppn1_match[i] = (flush_vpn_i[17:9] == gppn[i][17:9]);
            gpaddr_gppn2_match[i] = (flush_vpn_i[28:18] == gppn[i][28:18]);
            
            //# IOTINVAL.VMA:
            // Ensures that all previous stores made to the first-stage PTs by the harts are observed by the IOMMU 
            // before any subsequent implicit read from the IOMMU.
            // According to the value of GV, AV and PSCV, different entries are selected to be invalidated:
            /*
                |GV|AV|PSCV|

                |0 |0 |0   |    Invalidate all entries for all host address spaces (G-stage translation disabled), including those with G=1 
                                NOTE: Host address space entries are those with G-stage translation disabled. Some devices may be retained by the hypervisor or host OS
                |0 |0 |1   |    Invalidate all entries for the host address space identified by PSCID, except for those with G=1
                |0 |1 |0   |    Invalidate all entries identified by the IOVA in ADDR field, for all host address spaces, including those with G=1
                |0 |1 |1   |    Invalidate all entries identified by the IOVA in ADDR field, for the host address space identified by PSCID, except for those with G=1 //? Should it be only one entry?
                |1 |0 |0   |    Invalidate all entries for all address spaces associated to the VM identified by GSCID, including those with G=1
                |1 |0 |1   |    Invalidate all entries for the address space identified by PSCID, in the VM identified by GSCID, except for those with G=1
                |1 |1 |0   |    Invalidate all entries corresponding to the IOVA in ADDR field, associated to the VM identified by GSCID, including those with G=1
                |1 |1 |1   |    Invalidate all entries corresponding to the IOVA in ADDR field, for the VM address space identified by GSCID and PSCID.
            */
            if(flush_vma_i) begin
                unique case ({flush_gv_i, flush_av_i, flush_pscv_i})
                    3'b000: begin
                        // all host address space entries are flushed
                        if(!tags_q[i].en_2S && tags_q[i].en_1S) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    3'b001: begin
                        // 2S disabled, 1S enabled, PSCID match, exclude global entries
                        if((!tags_q[i].en_2S && tags_q[i].en_1S) && (tags_q[i].pscid == flush_pscid_i) && !content_q[i].pte_1S.g) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    3'b010: begin
                        // 2S disabled, 1S enabled, GVA match, include global entries
                        if((!tags_q[i].en_2S && tags_q[i].en_1S) && 
                            ((gvaddr_vpn2_match[i] && gvaddr_vpn1_match[i] && gvaddr_vpn0_match[i]) ||
                              gvaddr_2M_match[i] || gvaddr_1G_match[i])) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                    3'b011: begin
                        // 2S disabled, 1S enabled, GVA match, PSCID match, exclude global entries
                        if((!tags_q[i].en_2S && tags_q[i].en_1S) && 
                            ((gvaddr_vpn2_match[i] && gvaddr_vpn1_match[i] && gvaddr_vpn0_match[i]) ||
                              gvaddr_2M_match[i] || gvaddr_1G_match[i]) &&
                              tags_q[i].pscid == flush_pscid_i && !content_q[i].pte_1S.g) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                    3'b100: begin
                        // 2S enabled, 1S enabled, GSCID match, include global mappings
                        if((tags_q[i].en_2S && tags_q[i].en_1S) && (tags_q[i].gscid == flush_gscid_i)) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    3'b101: begin
                        // 2S enabled, 1S enabled, GSCID and PSCID match, exclude global mappings
                        if( (tags_q[i].en_2S && tags_q[i].en_1S) && 
                            (tags_q[i].gscid == flush_gscid_i && tags_q[i].pscid == flush_pscid_i) &&
                             !content_q[i].pte_1S.g) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                    3'b110: begin
                        // 2S enabled, 1S enabled, GSCID and IOVA (39-bit GVA in this case) match, include global mappings
                        if( (tags_q[i].en_2S && tags_q[i].en_1S) && 
                            ((gvaddr_vpn2_match[i] && gvaddr_vpn1_match[i] && gvaddr_vpn0_match[i]) ||
                              gvaddr_2M_match[i] || gvaddr_1G_match[i]) &&
                              tags_q[i].gscid == flush_gscid_i) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                    3'b111: begin
                        // 2S enabled, 1S enabled, GSCID, PSCID and IOVA (39-bit GVA in this case) match, exclude global mappings
                        if( (tags_q[i].en_2S && tags_q[i].en_1S) && 
                            ((gvaddr_vpn2_match[i] && gvaddr_vpn1_match[i] && gvaddr_vpn0_match[i]) ||
                              gvaddr_2M_match[i] || gvaddr_1G_match[i]) &&
                             (tags_q[i].gscid == flush_gscid_i && tags_q[i].pscid == flush_pscid_i) &&
                             !content_q[i].pte_1S.g) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                endcase
            end

            //# IOTINVAL.GVMA:
            // Ensures that all previous stores made to the MSI PTs by the harts 
            // are observed by the IOMMU before all subsequent implicit reads from the IOMMU.
            //
            // 1S entries whose GPA matches the ADDR field and GSCID field must be invalidated by these operations
            // According to the value of GV and AV, different entries are selected to be invalidated:
            /*
                |GV|AV|

                |0 |d |     Invalidate second-stage entries for all VM address spaces
                |1 |0 |     Invalidate second-stage entries for all VM address spaces identified by GSCID
                |1 |1 |     Invalidate second-stage entries corresponding to the IOVA (GPA) in the ADDR field, for all VM address spaces identified by GSCID.
            */
            else if(flush_gvma_i) begin
                unique casez ({flush_gv_i, flush_av_i})
                    2'b0?: begin
                        // Invalidate all entries
                        tags_n[i].valid = 1'b0;
                    end
                    2'b10: begin
                        // GSCID match
                        if(tags_q[i].gscid == flush_gscid_i) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    2'b11: begin
                        // GSCID match, IOVA (41-bit GPA) match
                        if(tags_q[i].gscid == flush_gscid_i && 
                           (gpaddr_gppn2_match[i] && gpaddr_gppn1_match[i] && gpaddr_gppn0_match[i])) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                endcase
            end

            // normal replacement
            else if (update_i && replace_en[i]) begin
                // update tags
                tags_n[i] = '{
                    pscid:      up_pscid_i,
                    gscid:      up_gscid_i,
                    vpn2:       up_vpn_i[28:18],
                    vpn1:       up_vpn_i[17:9],
                    vpn0:       up_vpn_i[8:0],
                    en_1S:      en_1S_i,
                    en_2S:      en_2S_i,
                    is_1S_1G:   up_1S_1G_i,
                    is_1S_2M:   up_1S_2M_i,
                    valid:      1'b1
                };
                // and content as well
                content_n[i].pte_1S     = up_1S_content_i;
                content_n[i].msi_pte    = up_msi_content_i;
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