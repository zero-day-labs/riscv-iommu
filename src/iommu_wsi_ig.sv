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
//    Date: 10/03/2023
//
//    Description: RISC-V IOMMU WSI Interrupt Generation Module.

module iommu_wsi_ig #(
    // Number of supported interrupt vectors
    parameter int unsigned N_INT_VEC = 16,
    
    // DO NOT MODIFY
    parameter int unsigned LOG2_INTVEC = $clog2(N_INT_VEC)
) (
    
    // fctl.wsi
    input  logic        wsi_en_i,

    // ipsr
    input  logic        cip_i,
    input  logic        fip_i,

    // icvec
    input  logic[(LOG2_INTVEC-1):0]   civ_i,
    input  logic[(LOG2_INTVEC-1):0]   fiv_i,

    // interrupt wires
    output logic [(N_INT_VEC-1):0] wsi_wires_o
);

    always_comb begin : wsi_support
            
        /* verilator lint_off WIDTH */
        // If WSI generation supported and enabled
        if (wsi_en_i) begin

            for (int unsigned i = 0; i < N_INT_VEC; i++) begin
                wsi_wires_o[i] = ((cip_i & (civ_i == iommu_pkg::icvec_vals[i] )) 
                                    | (fip_i & (fiv_i == iommu_pkg::icvec_vals[i] )));
            end
        end
        /* verilator lint_on WIDTH */
    end
    
endmodule