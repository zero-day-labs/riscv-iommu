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
// Date: 06/02/2023
//
// Description: RISC-V IOMMU Translation Logic Wrapper.
//              Encompasses all modules involved in the address translation 
//              process and report of translation faults.
//              Process Context support: YES
//              MSI Translation support: YES

//! NOTES:
/*
    - For now, req_trans_i must be hold high for the entire translation process (whenever walks are needed). If it is cleared, 
      IOTLB hit signal is also cleared even if it has a valid translation. Further on, input signals may be propagated to achieve 
      a stronger implementation (+ HW cost).
*/

module iommu_wrapper #(

    parameter int unsigned  IOTLB_ENTRIES       = 4,
    parameter int unsigned  DDTC_ENTRIES        = 4,
    parameter int unsigned  PDTC_ENTRIES        = 4,

    // Include Process Context support
    parameter bit               InclPID         = 0,
    // Include MSI translation support
    parameter bit               InclMSITrans    = 0,

    parameter int unsigned      N_INT_VEC       = 16,
    parameter rv_iommu::igs_t   IGS             = rv_iommu::WSI_ONLY,

    // DO NOT MODIFY
    parameter int unsigned LOG2_INTVEC  = $clog2(N_INT_VEC)
) (
    input  logic    clk_i,
    input  logic    rst_ni,

    // Trigger translation
    input  logic    req_trans_i,

    // Translation request data
    input  logic [23:0]                     device_id_i,
    input  logic                            pid_v_i,                // A valid process_id is associated with the request
    input  logic [19:0]                     process_id_i,
    input  logic [riscv::VLEN-1:0]          iova_i,
    
    input  logic [rv_iommu::TTYP_LEN-1:0]   trans_type_i,
    input  riscv::priv_lvl_t                priv_lvl_i,             // Privilege mode associated with the transaction

    // Memory Bus
    input  ariane_axi::resp_t               mem_resp_i,
    output ariane_axi::req_t                mem_req_o,

    // From Regmap
    input  iommu_reg_pkg::iommu_reg2hw_capabilities_reg_t   capabilities_i,
    input  iommu_reg_pkg::iommu_reg2hw_fctl_reg_t           fctl_i,
    input  iommu_reg_pkg::iommu_reg2hw_ddtp_reg_t           ddtp_i,
    // CQ
    input  logic [riscv::PPNW-1:0]      cqb_ppn_i,
    input  logic [4:0]                  cqb_size_i,
    input  logic [31:0]                 cqh_i,
    output logic [31:0]                 cqh_o,
    input  logic [31:0]                 cqt_i,
    // FQ
    input  logic [riscv::PPNW-1:0]      fqb_ppn_i,
    input  logic [4:0]                  fqb_size_i,
    input  logic [31:0]                 fqh_i,
    input  logic [31:0]                 fqt_i,
    output logic [31:0]                 fqt_o,
    // cqcsr
    input  logic                        cq_en_i,
    input  logic                        cq_ie_i,
    input  logic                        cq_mf_i,
    input  logic                        cq_cmd_to_i,    
    input  logic                        cq_cmd_ill_i,
    input  logic                        cq_fence_w_ip_i,
    output logic                        cq_mf_o,
    output logic                        cq_cmd_to_o,
    output logic                        cq_cmd_ill_o,
    output logic                        cq_fence_w_ip_o,
    output logic                        cq_on_o,
    output logic                        cq_busy_o,
    // fqcsr
    input  logic                        fq_en_i,
    input  logic                        fq_ie_i,
    input  logic                        fq_mf_i,
    input  logic                        fq_of_i,
    output logic                        fq_mf_o,
    output logic                        fq_of_o,
    output logic                        fq_on_o,
    output logic                        fq_busy_o,
    // ipsr
    input  logic                        cq_ip_i,
    input  logic                        fq_ip_i,
    input  logic                        hpm_ip_i,
    output logic                        cq_ip_o,
    output logic                        fq_ip_o,
    // icvec
    input  logic[(LOG2_INTVEC-1):0]     civ_i,
    input  logic[(LOG2_INTVEC-1):0]     fiv_i,
    input  logic[(LOG2_INTVEC-1):0]     pmiv_i,
    // MSI config table
    input  logic [53:0]                 msi_addr_x_i[16],
    input  logic [31:0]                 msi_data_x_i[16],
    input  logic                        msi_vec_masked_x_i[16],

    // To enable write of error bits to cqcsr and fqcsr
    output logic                        cq_error_wen_o,
    output logic                        fq_error_wen_o,

    // Request status and output data
    output logic                        trans_valid_o,      // Translation completed
    output logic                        is_msi_o,           // Indicate whether the translated address is an MSI address
    output logic [riscv::PLEN-1:0]      translated_addr_o,  // Translated address
    output logic                        trans_error_o,

    // to HPM
    output logic                        iotlb_miss_o,       // IOTLB miss happened
    output logic                        ddt_walk_o,         // DDT walk triggered
    output logic                        pdt_walk_o,         // PDT walk triggered
    output logic                        s1_ptw_o,           // first-stage PT walk triggered
    output logic                        s2_ptw_o,           // second-stage PT walk triggered
    output logic [15:0]                 gscid_o,
    output logic [19:0]                 pscid_o,

    output logic                        is_fq_fifo_full_o
);

    generate
        case ({InclPID, InclMSITrans})

            // No PC support
            // No MSI translation support
            0: begin
                iommu_wrapper_sv39x4 #(
                    .IOTLB_ENTRIES      (IOTLB_ENTRIES      ),
                    .DDTC_ENTRIES       (DDTC_ENTRIES       ),
                    .N_INT_VEC          (N_INT_VEC          ),
                    .IGS                (IGS                )
                ) i_iommu_wrapper_sv39x4 (
                    .clk_i,
                    .rst_ni,

                    .req_trans_i,

                    // Translation request data
                    .device_id_i,
                    .iova_i,
                    
                    .trans_type_i,
                    .priv_lvl_i,

                    // Memory Bus
                    .mem_resp_i,
                    .mem_req_o,

                    // From Regmap
                    .capabilities_i,
                    .fctl_i,
                    .ddtp_i,
                    // CQ
                    .cqb_ppn_i,
                    .cqb_size_i,
                    .cqh_i,
                    .cqh_o,
                    .cqt_i,
                    // FQ
                    .fqb_ppn_i,
                    .fqb_size_i,
                    .fqh_i,
                    .fqt_i,
                    .fqt_o,
                    // cqcsr
                    .cq_en_i,
                    .cq_ie_i,
                    .cq_mf_i,
                    .cq_cmd_to_i,    
                    .cq_cmd_ill_i,
                    .cq_fence_w_ip_i,
                    .cq_mf_o,
                    .cq_cmd_to_o,
                    .cq_cmd_ill_o,
                    .cq_fence_w_ip_o,
                    .cq_on_o,
                    .cq_busy_o,
                    // fqcsr
                    .fq_en_i,
                    .fq_ie_i,
                    .fq_mf_i,
                    .fq_of_i,
                    .fq_mf_o,
                    .fq_of_o,
                    .fq_on_o,
                    .fq_busy_o,
                    // ipsr
                    .cq_ip_i,
                    .fq_ip_i,
                    .hpm_ip_i,
                    .cq_ip_o,
                    .fq_ip_o,
                    // icvec
                    .civ_i,
                    .fiv_i,
                    .pmiv_i,
                    // msi_cfg_tbl
                    .msi_addr_x_i,
                    .msi_data_x_i,
                    .msi_vec_masked_x_i,

                    // To enable write of error bits to cqcsr and fqcsr
                    .cq_error_wen_o,
                    .fq_error_wen_o,

                    .trans_valid_o,
                    .translated_addr_o,
                    .trans_error_o,

                    // to HPM
                    .iotlb_miss_o,
                    .ddt_walk_o,
                    .s1_ptw_o,
                    .s2_ptw_o,
                    .gscid_o,
                    .pscid_o,

                    .is_fq_fifo_full_o
                );

                assign pdt_walk_o   = 1'b0;
                assign is_msi_o     = 1'b0;
            end

            // No PC support
            // MSI translation support
            1: begin
                iommu_wrapper_sv39x4_msi #(
                    .IOTLB_ENTRIES      (IOTLB_ENTRIES      ),
                    .DDTC_ENTRIES       (DDTC_ENTRIES       ),
                    .N_INT_VEC          (N_INT_VEC          ),
                    .IGS                (IGS                )
                ) i_iommu_wrapper_sv39x4_msi (
                    .clk_i,
                    .rst_ni,

                    .req_trans_i,

                    // Translation request data
                    .device_id_i,
                    .iova_i,
                    
                    .trans_type_i,
                    .priv_lvl_i,

                    // Memory Bus
                    .mem_resp_i,
                    .mem_req_o,

                    // From Regmap
                    .capabilities_i,
                    .fctl_i,
                    .ddtp_i,
                    // CQ
                    .cqb_ppn_i,
                    .cqb_size_i,
                    .cqh_i,
                    .cqh_o,
                    .cqt_i,
                    // FQ
                    .fqb_ppn_i,
                    .fqb_size_i,
                    .fqh_i,
                    .fqt_i,
                    .fqt_o,
                    // cqcsr
                    .cq_en_i,
                    .cq_ie_i,
                    .cq_mf_i,
                    .cq_cmd_to_i,    
                    .cq_cmd_ill_i,
                    .cq_fence_w_ip_i,
                    .cq_mf_o,
                    .cq_cmd_to_o,
                    .cq_cmd_ill_o,
                    .cq_fence_w_ip_o,
                    .cq_on_o,
                    .cq_busy_o,
                    // fqcsr
                    .fq_en_i,
                    .fq_ie_i,
                    .fq_mf_i,
                    .fq_of_i,
                    .fq_mf_o,
                    .fq_of_o,
                    .fq_on_o,
                    .fq_busy_o,
                    // ipsr
                    .cq_ip_i,
                    .fq_ip_i,
                    .hpm_ip_i,
                    .cq_ip_o,
                    .fq_ip_o,
                    // icvec
                    .civ_i,
                    .fiv_i,
                    .pmiv_i,
                    // msi_cfg_tbl
                    .msi_addr_x_i,
                    .msi_data_x_i,
                    .msi_vec_masked_x_i,

                    // To enable write of error bits to cqcsr and fqcsr
                    .cq_error_wen_o,
                    .fq_error_wen_o,

                    .trans_valid_o,
                    .is_msi_o,
                    .translated_addr_o,
                    .trans_error_o,

                    // to HPM
                    .iotlb_miss_o,
                    .ddt_walk_o,
                    .s1_ptw_o,
                    .s2_ptw_o,
                    .gscid_o,
                    .pscid_o,

                    .is_fq_fifo_full_o
                );

                assign pdt_walk_o   = 1'b0;
            end

            // PC support
            // No MSI translation support
            2: begin
                iommu_wrapper_sv39x4_pc #(
                    .IOTLB_ENTRIES      (IOTLB_ENTRIES      ),
                    .DDTC_ENTRIES       (DDTC_ENTRIES       ),
                    .PDTC_ENTRIES       (PDTC_ENTRIES       ),
                    .N_INT_VEC          (N_INT_VEC          ),
                    .IGS                (IGS                )
                ) i_iommu_wrapper_sv39x4_pc (
                    .clk_i,
                    .rst_ni,

                    .req_trans_i,

                    // Translation request data
                    .device_id_i,
                    .pid_v_i,
                    .process_id_i,                    
                    .iova_i,
                    
                    .trans_type_i,
                    .priv_lvl_i,

                    // Memory Bus
                    .mem_resp_i,
                    .mem_req_o,

                    // From Regmap
                    .capabilities_i,
                    .fctl_i,
                    .ddtp_i,
                    // CQ
                    .cqb_ppn_i,
                    .cqb_size_i,
                    .cqh_i,
                    .cqh_o,
                    .cqt_i,
                    // FQ
                    .fqb_ppn_i,
                    .fqb_size_i,
                    .fqh_i,
                    .fqt_i,
                    .fqt_o,
                    // cqcsr
                    .cq_en_i,
                    .cq_ie_i,
                    .cq_mf_i,
                    .cq_cmd_to_i,    
                    .cq_cmd_ill_i,
                    .cq_fence_w_ip_i,
                    .cq_mf_o,
                    .cq_cmd_to_o,
                    .cq_cmd_ill_o,
                    .cq_fence_w_ip_o,
                    .cq_on_o,
                    .cq_busy_o,
                    // fqcsr
                    .fq_en_i,
                    .fq_ie_i,
                    .fq_mf_i,
                    .fq_of_i,
                    .fq_mf_o,
                    .fq_of_o,
                    .fq_on_o,
                    .fq_busy_o,
                    // ipsr
                    .cq_ip_i,
                    .fq_ip_i,
                    .hpm_ip_i,
                    .cq_ip_o,
                    .fq_ip_o,
                    // icvec
                    .civ_i,
                    .fiv_i,
                    .pmiv_i,
                    // msi_cfg_tbl
                    .msi_addr_x_i,
                    .msi_data_x_i,
                    .msi_vec_masked_x_i,

                    // To enable write of error bits to cqcsr and fqcsr
                    .cq_error_wen_o,
                    .fq_error_wen_o,

                    .trans_valid_o,
                    .translated_addr_o,
                    .trans_error_o,

                    // to HPM
                    .iotlb_miss_o,
                    .ddt_walk_o,
                    .pdt_walk_o,
                    .s1_ptw_o,
                    .s2_ptw_o,
                    .gscid_o,
                    .pscid_o,

                    .is_fq_fifo_full_o
                );

                assign is_msi_o     = 1'b0;
            end

            // PC support
            // MSI translation support
            3: begin
                iommu_wrapper_sv39x4_msi_pc #(
                    .IOTLB_ENTRIES      (IOTLB_ENTRIES      ),
                    .DDTC_ENTRIES       (DDTC_ENTRIES       ),
                    .PDTC_ENTRIES       (PDTC_ENTRIES       ),
                    .N_INT_VEC          (N_INT_VEC          ),
                    .IGS                (IGS                )
                ) i_iommu_wrapper_sv39x4_msi_pc (
                    .clk_i,
                    .rst_ni,

                    .req_trans_i,

                    // Translation request data
                    .device_id_i,
                    .pid_v_i,
                    .process_id_i,                    
                    .iova_i,
                    
                    .trans_type_i,
                    .priv_lvl_i,

                    // Memory Bus
                    .mem_resp_i,
                    .mem_req_o,

                    // From Regmap
                    .capabilities_i,
                    .fctl_i,
                    .ddtp_i,
                    // CQ
                    .cqb_ppn_i,
                    .cqb_size_i,
                    .cqh_i,
                    .cqh_o,
                    .cqt_i,
                    // FQ
                    .fqb_ppn_i,
                    .fqb_size_i,
                    .fqh_i,
                    .fqt_i,
                    .fqt_o,
                    // cqcsr
                    .cq_en_i,
                    .cq_ie_i,
                    .cq_mf_i,
                    .cq_cmd_to_i,    
                    .cq_cmd_ill_i,
                    .cq_fence_w_ip_i,
                    .cq_mf_o,
                    .cq_cmd_to_o,
                    .cq_cmd_ill_o,
                    .cq_fence_w_ip_o,
                    .cq_on_o,
                    .cq_busy_o,
                    // fqcsr
                    .fq_en_i,
                    .fq_ie_i,
                    .fq_mf_i,
                    .fq_of_i,
                    .fq_mf_o,
                    .fq_of_o,
                    .fq_on_o,
                    .fq_busy_o,
                    // ipsr
                    .cq_ip_i,
                    .fq_ip_i,
                    .hpm_ip_i,
                    .cq_ip_o,
                    .fq_ip_o,
                    // icvec
                    .civ_i,
                    .fiv_i,
                    .pmiv_i,
                    // msi_cfg_tbl
                    .msi_addr_x_i,
                    .msi_data_x_i,
                    .msi_vec_masked_x_i,

                    // To enable write of error bits to cqcsr and fqcsr
                    .cq_error_wen_o,
                    .fq_error_wen_o,

                    .trans_valid_o,
                    .is_msi_o,
                    .translated_addr_o,
                    .trans_error_o,

                    // to HPM
                    .iotlb_miss_o,
                    .ddt_walk_o,
                    .pdt_walk_o,
                    .s1_ptw_o,
                    .s2_ptw_o,
                    .gscid_o,
                    .pscid_o,

                    .is_fq_fifo_full_o
                );
            end
        endcase
    endgenerate

endmodule