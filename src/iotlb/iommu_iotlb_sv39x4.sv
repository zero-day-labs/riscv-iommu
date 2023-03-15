// Copyright (c) 2022 University of Minho
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
    Date:    04/11/2022

    Description: Sv39x4 IO Translation Look-aside Buffer (IO Address Translation Cache) for RISC-V IOMMU.
                This module is an adaptation of the CVA6 Sv39 TLB developed by:
                -   David Schaffenrath, TU Graz,
                -   Florian Zaruba, ETH Zurich;
                And the CVA6 Sv39x4 TLB developed by:
                -   Bruno Sá, University of Minho.
*/

module iommu_iotlb_sv39x4 import ariane_pkg::*; #(
    parameter int unsigned IOTLB_ENTRIES = 4,
    parameter int unsigned PSCID_WIDTH  = 20,
    parameter int unsigned GSCID_WIDTH  = 16
)(
    input  logic                    clk_i,            // Clock
    input  logic                    rst_ni,           // Asynchronous reset active low

    // TODO: Create F, U and LU signals structure (carefull with cocotb testing...)
    // Flush signals
    input  logic                    flush_vma_i,      // IOTINVAL.VMA
    input  logic                    flush_gvma_i,     // IOTINVAL.GVMA
    input  logic                    flush_av_i,       // ADDR valid
    input  logic                    flush_gv_i,       // GSCID valid
    input  logic                    flush_pscv_i,     // PSCID valid
    input  logic [riscv::GPPNW-1:0] flush_vpn_i,      // VPN to be flushed
    input  logic [PSCID_WIDTH-1:0]  flush_gscid_i,    // GSCID identifier to be flushed (VM identifier)
    input  logic [GSCID_WIDTH-1:0]  flush_pscid_i,    // PSCID identifier to be flushed (address space identifier)

    // Update signals
    // input  tlb_update_sv39x4_t      update_i,
    input  logic                    update_i,
    input  logic                    up_is_s_2M_i,
    input  logic                    up_is_s_1G_i,
    input  logic                    up_is_g_2M_i,
    input  logic                    up_is_g_1G_i,
    input  logic                    up_is_msi_i,
    input  logic [riscv::GPPNW-1:0] up_vpn_i,
    input  logic [PSCID_WIDTH-1:0]  up_pscid_i,
    input  logic [GSCID_WIDTH-1:0]  up_gscid_i,
    input riscv::pte_t              up_content_i,
    input riscv::pte_t              up_g_content_i,

    // Lookup signals
    input  logic                    lookup_i,                 // lookup flag
    input  logic [riscv::VLEN-1:0]  lu_iova_i,                // IOVA to look for 
    input  logic [PSCID_WIDTH-1:0]  lu_pscid_i,               // PSCID to look for
    input  logic [GSCID_WIDTH-1:0]  lu_gscid_i,               // GSCID to look for
    output logic [riscv::GPLEN-1:0] lu_gpaddr_o,              // GPA to return in case of an exception
    // Yes, i need both PTE ports. Different PPNs are needed according to the size of the page
    output riscv::pte_t             lu_content_o,             // S/VS-stage PTE (GPA PPN)
    output riscv::pte_t             lu_g_content_o,           // G-stage PTE (SPA PPN)
    // External logic needs to know the size of the 
    //final page, in order to construct the final PA
    output logic                    lu_is_s_2M_o,               
    output logic                    lu_is_s_1G_o,
    output logic                    lu_is_g_2M_o,               
    output logic                    lu_is_g_1G_o,
    output logic                    lu_is_msi_o,              // IOTLB entry contains a GPA associated with a guest vIMSIC
    input  logic                    s_stg_en_i,               // s-stage enabled
    input  logic                    g_stg_en_i,               // g-stage enabled
    output logic                    lu_hit_o                  // hit flag
);

    //* Tags to identify TLB entries
    // SV39 defines three levels of page tables
    // GV and PSCV are not used to tag IOTLB entries. Only to define which entries will be flushed / invalidated when requested.
    // GSCID is analogous to VMID. Helps to identify entries that correspond to a specific virtual machine, to avoid flushing when a context switch between two different VMs occur.
    // PSCID is analogous to ASID. Helps to identify processes address spaces within the same VM, to avoid flushing TLB when switching context between different processes.asid
    struct packed {
        logic [PSCID_WIDTH-1:0] pscid;      // process address space identifier
        logic [GSCID_WIDTH-1:0] gscid;      // virtual machine identifier
        logic [riscv::GPPN2:0] vpn2;        // 3-level VPN (VPN[2] is the segment expanded by two bits in Sv39x4)
        logic [8:0]            vpn1;
        logic [8:0]            vpn0;
        logic                  is_s_2M;       // S/VS superpage: VPN[0] makes part of the offset
        logic                  is_s_1G;       // S/VS superpage: VPN[0,1] makes part of the offset
        logic                  is_g_2M;       // G superpage: VPN[0] makes part of the offset
        logic                  is_g_1G;       // G superpage: VPN[0,1] makes part of the offset
        logic                  is_msi;        // IOTLB entry contains a GPA associated with a guest vIMSIC
        logic                  s_stg_en;      // s-stage translation enable
        logic                  g_stg_en;      // g-stage translation enable
        logic                  valid;         // valid bit //? Why two V bits? tag and PTE
    } [IOTLB_ENTRIES-1:0] tags_q, tags_n;

    //* IOTLB entries: Same entry for both stages (S/VS and G)
    // TODO: For now, adopt the same PTE format for the IOTLB. Then, consider to ignore/save some unnecessary bits
    // For G-stage address translation, all memory accesses are considered to be user-level accesses
    // R, W and X permissions are checked in both stages
    // G bit in G-stage PTEs should be cleared by SW and ignored by HW
    struct packed {
        riscv::pte_t pte;     // S/VS
        riscv::pte_t gpte;    // G
    } [IOTLB_ENTRIES-1:0] content_q, content_n;

    logic [8:0] vpn0, vpn1;
    logic [riscv::GPPN2:0] vpn2;
    logic [IOTLB_ENTRIES-1:0] lu_hit;     // to replacement logic
    logic [IOTLB_ENTRIES-1:0] replace_en; // replace the following entry, set by replacement strategy
    logic [IOTLB_ENTRIES-1:0] match_gscid;
    logic [IOTLB_ENTRIES-1:0] match_pscid;
    logic [IOTLB_ENTRIES-1:0] match_stage;
    logic [IOTLB_ENTRIES-1:0] is_1G;
    logic [IOTLB_ENTRIES-1:0] is_2M;
    riscv::pte_t   g_content;

    //-------------
    //# Lookup
    //-------------
    always_comb begin : lookup
        automatic logic [riscv::GPPN2:0] mask_pn2;
        mask_pn2 = s_stg_en_i ? ((2**(riscv::VPN2+1))-1) : ((2**(riscv::GPPN2+1))-1);  // 2^9 - 1 : 2^11 - 1 
        vpn0 = lu_iova_i[20:12];
        vpn1 = lu_iova_i[29:21];
        vpn2 = lu_iova_i[30+riscv::GPPN2:30] & mask_pn2;   // input vaddr[40:30] (Sv39x4), clear additional bits

        // default assignment
        lu_hit         = '{default: 0};
        lu_hit_o       = 1'b0;
        lu_content_o   = '{default: 0};
        lu_g_content_o = '{default: 0};
        lu_is_s_2M_o    = 1'b0;        
        lu_is_s_1G_o    = 1'b0;
        lu_is_g_2M_o    = 1'b0;               
        lu_is_g_1G_o    = 1'b0;
        lu_is_msi_o     = 1'b0;
        match_pscid     = '{default: 0};
        match_gscid     = '{default: 0};
        match_stage    = '{default: 0};
        is_1G          = '{default: 0};
        is_2M          = '{default: 0};
        g_content      = '{default: 0};
        lu_gpaddr_o    = '{default: 0};

        // Hit flag may be set only when we want to access the IOTLB
        if (lookup_i) begin

            for (int unsigned i = 0; i < IOTLB_ENTRIES; i++) begin
            
                // A PSCID match is signaled for lookups with S/VS stage disabled
                // If S/VS stage is enabled, only PSCID matches and global entries match
                match_pscid[i] = (((lu_pscid_i == tags_q[i].pscid) || content_q[i].pte.g) && s_stg_en_i) || !s_stg_en_i;

                // A GSCID match is signaled for lookups with G stage disabled
                // If G stage is active, only GSCID matches will indicate entry match
                match_gscid[i] = (lu_gscid_i == tags_q[i].gscid && g_stg_en_i) || !g_stg_en_i;

                // returns true if S/VS and G stages are both disabled. Otherwise, return true if enabled stages have 1G pages
                is_1G[i] = is_trans_1G(s_stg_en_i,
                                        g_stg_en_i,
                                        tags_q[i].is_s_1G,
                                        tags_q[i].is_g_1G
                                    );

                // checks if final translation page size is 2M when H-extension is enabled 
                is_2M[i] = is_trans_2M(s_stg_en_i,
                                        g_stg_en_i,
                                        tags_q[i].is_s_1G,
                                        tags_q[i].is_s_2M,
                                        tags_q[i].is_g_1G,
                                        tags_q[i].is_g_2M
                                    );

                // check if translation is a: S-Stage and G-Stage, S-Stage only or G-Stage only translation
                // A stage match occurs if enabled translation stages are equal to the input ones
                // This means that a TLB entry may be associated to only one translation stage, or both
                match_stage[i] = (tags_q[i].g_stg_en == g_stg_en_i) && (tags_q[i].s_stg_en == s_stg_en_i);
                
                // An entry match occurs if the entry is valid, if GSCID and PSCID matches, if translation stages matches, and VPN[2] matches
                // For now only VPN[2] is verified for the case of gigapages, where VPN[1] and VPN[0] make part of the offset
                if (tags_q[i].valid && match_pscid[i] && match_gscid[i] && match_stage[i] && (vpn2 == (tags_q[i].vpn2 & mask_pn2))) begin

                    // Construct a GPA with input GVA, according to the size of the page (bypassed offset field is different in each case)
                    // All 44 bits of the S/VS PTE's PPN are not used. Only 11 bits of PPN[2] are used, in order to match GPA's length
                    // Does not make sense when translating GPAs (S-stage disabled)
                    lu_gpaddr_o = make_gpaddr_sv39x4(s_stg_en_i, tags_q[i].is_s_1G, tags_q[i].is_s_2M, lu_iova_i, content_q[i].pte);
                    
                    // 1G match | 2M match | 4k match, modified condition to simplify
                    if (is_1G[i] || ((vpn1 == tags_q[i].vpn1) && (is_2M[i] || vpn0 == tags_q[i].vpn0))) begin
                        lu_is_s_2M_o    = tags_q[i].is_s_2M;        
                        lu_is_s_1G_o    = tags_q[i].is_s_1G;
                        lu_is_g_2M_o    = tags_q[i].is_g_2M;               
                        lu_is_g_1G_o    = tags_q[i].is_g_1G;
                        lu_is_msi_o     = tags_q[i].is_msi;
                        lu_content_o    = content_q[i].pte;
                        lu_g_content_o  = content_q[i].gpte;
                        lu_hit_o        = 1'b1;
                        lu_hit[i]       = 1'b1;
                    end
                end
            end
        end
    end

    // ------------------
    //# Update and Flush
    // ------------------

    logic  [IOTLB_ENTRIES-1:0] vaddr_vpn0_match;
    logic  [IOTLB_ENTRIES-1:0] vaddr_vpn1_match;
    logic  [IOTLB_ENTRIES-1:0] vaddr_vpn2_match;
    logic  [IOTLB_ENTRIES-1:0] vaddr_2M_match;
    logic  [IOTLB_ENTRIES-1:0] vaddr_1G_match;
    logic  [IOTLB_ENTRIES-1:0] gpaddr_gppn0_match;
    logic  [IOTLB_ENTRIES-1:0] gpaddr_gppn1_match;
    logic  [IOTLB_ENTRIES-1:0] gpaddr_gppn2_match;
    /*
        !NOTE: 
        For IOTINVAL.GVMA commands, any entry whose GVA maps to a GPA that matches 
        the given address in the ADDR field, and also matches the GSCID field, must be invalidated.
        This requires tagging entries with the GPA, which is hardware costly. A common implementation
        invalidates all entries that match the GSCID field.

        This implementation will assume the HW cost and perform the IOTINVAL.GVMA according to the specification.
    */
    logic  [IOTLB_ENTRIES-1:0] [(riscv::GPPNW-1):0] gppn;

    // only update if a flush operation is not ongoing
    always_comb begin : update_flush
        tags_n    = tags_q;
        content_n = content_q;

        for (int unsigned i = 0; i < IOTLB_ENTRIES; i++) begin

            // check if given GVA (39-bits) matches VPN tag
            vaddr_vpn0_match[i] = (flush_vpn_i[8:0] == tags_q[i].vpn0);
            vaddr_vpn1_match[i] = (flush_vpn_i[17:9] == tags_q[i].vpn1);
            vaddr_vpn2_match[i] = (flush_vpn_i[18+riscv::VPN2:18] == tags_q[i].vpn2[riscv::VPN2:0]);   // [26:18]

            // S/VS superpage cases
            vaddr_2M_match[i] = (vaddr_vpn2_match[i] && vaddr_vpn1_match[i] && tags_q[i].is_s_2M);
            vaddr_1G_match[i] = (vaddr_vpn2_match[i] && tags_q[i].is_s_1G);

            // construct GPA's PPN according to VS page table entry data
            gppn[i] = make_gppn_sv39x4(tags_q[i].s_stg_en, tags_q[i].is_s_1G, tags_q[i].is_s_2M, {tags_q[i].vpn2,tags_q[i].vpn1,tags_q[i].vpn0}, content_q[i].pte);
            
            // check if given GPA matches with any tag
            // Since the IOVA may be a GVA or a GPA, i think the input port may be the same...
            gpaddr_gppn0_match[i] = (flush_vpn_i[8:0] == gppn[i][8:0]);
            gpaddr_gppn1_match[i] = (flush_vpn_i[17:9] == gppn[i][17:9]);
            gpaddr_gppn2_match[i] = (flush_vpn_i[18+riscv::GPPN2:18] == gppn[i][18+riscv::GPPN2:18]);

            // G superpage cases
            gpaddr_2M_match[i] = (gpaddr_gppn2_match[i] && gpaddr_gppn1_match[i] && tags_q[i].is_g_2M);
            gpaddr_1G_match[i] = (gpaddr_gppn2_match[i] && tags_q[i].is_g_1G);
            
            //* IOTINVAL.VMA:
            // Ensures that all previous stores made to the S/VS PTs by the harts, 
            // are observed by the IOMMU before all subsequent implicit reads from the IOMMU.
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
                        // all host address space entries are flushed (G disabled, S enabled)
                        if(!tags_q[i].g_stg_en && tags_q[i].s_stg_en) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    3'b001: begin
                        // G disabled, S enabled, PSCID match, exclude global entries
                        if((!tags_q[i].g_stg_en && tags_q[i].s_stg_en) && (tags_q[i].pscid == flush_pscid_i) && !content_q[i].pte.g) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    3'b010: begin
                        // G disabled, S enabled, IOVA (39-bit VA in this case) match, include global entries
                        if((!tags_q[i].g_stg_en && tags_q[i].s_stg_en) && 
                            ((vaddr_vpn2_match[i] && vaddr_vpn1_match[i] && vaddr_vpn0_match[i]) ||
                              vaddr_2M_match[i] || vaddr_1G_match[i])) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                    3'b011: begin
                        // G disabled, S enabled, IOVA (39-bit VA in this case) match, PSCID match, exclude global entries
                        if((!tags_q[i].g_stg_en && tags_q[i].s_stg_en) && 
                            ((vaddr_vpn2_match[i] && vaddr_vpn1_match[i] && vaddr_vpn0_match[i]) ||
                              vaddr_2M_match[i] || vaddr_1G_match[i]) &&
                              tags_q[i].pscid == flush_pscid_i && !content_q[i].pte.g) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                    3'b100: begin
                        // G enabled, VS enabled, GSCID match, include global mappings
                        if((tags_q[i].g_stg_en && tags_q[i].s_stg_en) && (tags_q[i].gscid == flush_gscid_i)) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    3'b101: begin
                        // G enabled, VS enabled, GSCID and PSCID match, exclude global mappings
                        if( (tags_q[i].g_stg_en && tags_q[i].s_stg_en) && 
                            (tags_q[i].gscid == flush_gscid_i && tags_q[i].pscid == flush_pscid_i) &&
                             !content_q[i].pte.g) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                    3'b110: begin
                        // G enabled, VS enabled, GSCID and IOVA (39-bit GVA in this case) match, include global mappings
                        if( (tags_q[i].g_stg_en && tags_q[i].s_stg_en) && 
                            ((vaddr_vpn2_match[i] && vaddr_vpn1_match[i] && vaddr_vpn0_match[i]) ||
                              vaddr_2M_match[i] || vaddr_1G_match[i]) &&
                              tags_q[i].gscid == flush_gscid_i) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                    3'b111: begin
                        // G enabled, VS enabled, GSCID, PSCID and IOVA (39-bit GVA in this case) match, exclude global mappings
                        if( (tags_q[i].g_stg_en && tags_q[i].s_stg_en) && 
                            ((vaddr_vpn2_match[i] && vaddr_vpn1_match[i] && vaddr_vpn0_match[i]) ||
                              vaddr_2M_match[i] || vaddr_1G_match[i]) &&
                             (tags_q[i].gscid == flush_gscid_i && tags_q[i].pscid == flush_pscid_i) &&
                             !content_q[i].pte.g) begin
                                tags_n[i].valid = 1'b0;
                            end
                    end
                endcase
            end

            //* IOTINVAL.GVMA:
            // Ensures that all previous stores made to the G PTs by the harts 
            // are observed by the IOMMU before all subsequent implicit reads from the IOMMU.
            //
            // S/VS entries whose GPA matches the ADDR field and GSCID field must be invalidated by these operations
            // According to the value of GV and AV, different entries are selected to be invalidated:
            /*
                |GV|AV|

                |0 |d |     Invalidate G-stage entries for all VM address spaces
                |1 |0 |     Invalidate G-stage entries for all VM address spaces identified by GSCID
                |1 |1 |     Invalidate G-stage entries corresponding to the IOVA (GPA) in the ADDR field, for all VM address spaces identified by GSCID.
            */
            else if(flush_gvma_i) begin
                unique casez ({flush_gv_i, flush_av_i})
                    3'b0?: begin
                        // G enabled, S/VS don't care
                        if(tags_q[i].g_stg_en) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    3'b10: begin
                        // G enabled, S/VS don't care, GSCID match
                        if(tags_q[i].g_stg_en && tags_q[i].gscid == flush_gscid_i) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                    3'b11: begin
                        // G enabled, S/VS don't care, GSCID match, IOVA (41-bit GPA) match
                        if(tags_q[i].g_stg_en && tags_q[i].gscid == flush_gscid_i && 
                           ((gpaddr_gppn2_match[i] && gpaddr_gppn1_match[i] && gpaddr_gppn0_match[i]) ||
                             gpaddr_2M_match[i] || gpaddr_1G_match[i])) begin
                            tags_n[i].valid = 1'b0;
                        end
                    end
                endcase
            end
            // normal replacement
            // replace_en[i] identifies the LRU entry
            // only valid entries can be cached
            else if (update_i && replace_en[i] && ((s_stg_en_i && up_content_i.v) || (g_stg_en_i && up_g_content_i.v))) begin
                // update tags
                tags_n[i] = '{
                    pscid:      up_pscid_i,
                    gscid:      up_gscid_i,
                    vpn2:       up_vpn_i[18+riscv::GPPN2:18],
                    vpn1:       up_vpn_i[17:9],
                    vpn0:       up_vpn_i[8:0],
                    s_stg_en:   s_stg_en_i,
                    g_stg_en:   g_stg_en_i,
                    is_s_1G:    up_is_s_1G_i,
                    is_s_2M:    up_is_s_2M_i,
                    is_g_1G:    up_is_g_1G_i,
                    is_g_2M:    up_is_g_2M_i,
                    is_msi:     up_is_msi_i,
                    valid:      1'b1
                };
                // and content as well
                content_n[i].pte = up_content_i;
                content_n[i].gpte = up_g_content_i;
            end
        end
    end

    // -----------------------------------------------
    //* PLRU - Pseudo Least Recently Used Replacement
    // -----------------------------------------------
    
    //? Is it necessary to update LRU on updates?
    logic[2*(IOTLB_ENTRIES-1)-1:0] plru_tree_q, plru_tree_n;
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
        // E.g. for a TLB with 8 entries, the for-loop is semantically
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
        for (int unsigned i = 0; i < IOTLB_ENTRIES; i++) begin
            automatic int unsigned idx_base, shift, new_index;
            // we got a hit so update the pointer as it was least recently used
            if ((lu_hit[i] && lookup_i) || (replace[i] && update_i)) begin      // LRU updated on LU hits and updates
                // Set the nodes to the values we would expect
                for (int unsigned lvl = 0; lvl < $clog2(IOTLB_ENTRIES); lvl++) begin  // 3 for 8 entries
                    idx_base = $unsigned((2**lvl)-1);     // 0 for lvl0, 1 for lvl1, 3 for lvl2
                    // lvl0 <=> MSB, lvl1 <=> MSB-1, ...
                    shift = $clog2(IOTLB_ENTRIES) - lvl;    // 3 for lvl0, 2 for lvl1, 1 for lvl2
                    // to circumvent the 32 bit integer arithmetic assignment
                    new_index =  ~((i >> (shift-1)) & 32'b1);
                    plru_tree_n[idx_base + (i >> shift)] = new_index[0];
                end
            end
        end
        // Decode tree to write enable signals
        // Next for-loop basically creates the following logic for e.g. an 8 entry
        // TLB (note: pseudo-code obviously):
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
        for (int unsigned i = 0; i < IOTLB_ENTRIES; i += 1) begin
            automatic logic en;
            automatic int unsigned idx_base, shift, new_index;
            en = 1'b1;
            for (int unsigned lvl = 0; lvl < $clog2(IOTLB_ENTRIES); lvl++) begin
                idx_base = $unsigned((2**lvl)-1);
                // lvl0 <=> MSB, lvl1 <=> MSB-1, ...
                shift = $clog2(IOTLB_ENTRIES) - lvl;

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
        if(~rst_ni) begin
            tags_q      <= '{default: 0};
            content_q   <= '{default: 0};
            plru_tree_q <= '{default: 0};
        end else begin
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
        assert ((IOTLB_ENTRIES % 2 == 0) && (IOTLB_ENTRIES > 1))
        else begin $error("TLB size must be a multiple of 2 and greater than 1"); $stop(); end
        assert (PSCID_WIDTH >= 1)
        else begin $error("PSCID width must be at least 1"); $stop(); end
        assert (GSCID_WIDTH >= 1)
        else begin $error("GSCID width must be at least 1"); $stop(); end
    end

    // Just for checking
    function int countSetBits(logic[IOTLB_ENTRIES-1:0] vector);
        automatic int count = 0;
        foreach (vector[idx]) begin
        count += vector[idx];
        end
        return count;
    endfunction

    assert property (@(posedge clk_i)(countSetBits(lu_hit) <= 1))
        else begin $error("More than one hit in TLB!"); $stop(); end
    assert property (@(posedge clk_i)(countSetBits(replace_en) <= 1))
        else begin $error("More than one TLB entry selected for next replace!"); $stop(); end

    `endif
    //pragma translate_on

endmodule
