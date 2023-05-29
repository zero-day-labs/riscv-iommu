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
            
        // If WSI generation supported and enabled
        if (wsi_en_i) begin

            for (int unsigned i = 0; i < N_INT_VEC; i++) begin
                wsi_wires_o[i] = ((cip_i & (civ_i == iommu_pkg::icvec_vals[i] )) 
                                    | (fip_i & (fiv_i == iommu_pkg::icvec_vals[i] )));
            end

            // wsi_wires_o[0 ] = ((cip_i & (civ_i == 4'd0 )) | (fip_i & (fiv_i == 4'd0 )));
            // wsi_wires_o[1 ] = ((cip_i & (civ_i == 4'd1 )) | (fip_i & (fiv_i == 4'd1 )));
            // wsi_wires_o[2 ] = ((cip_i & (civ_i == 4'd2 )) | (fip_i & (fiv_i == 4'd2 )));
            // wsi_wires_o[3 ] = ((cip_i & (civ_i == 4'd3 )) | (fip_i & (fiv_i == 4'd3 )));
            // wsi_wires_o[4 ] = ((cip_i & (civ_i == 4'd4 )) | (fip_i & (fiv_i == 4'd4 )));
            // wsi_wires_o[5 ] = ((cip_i & (civ_i == 4'd5 )) | (fip_i & (fiv_i == 4'd5 )));
            // wsi_wires_o[6 ] = ((cip_i & (civ_i == 4'd6 )) | (fip_i & (fiv_i == 4'd6 )));
            // wsi_wires_o[7 ] = ((cip_i & (civ_i == 4'd7 )) | (fip_i & (fiv_i == 4'd7 )));
            // wsi_wires_o[8 ] = ((cip_i & (civ_i == 4'd8 )) | (fip_i & (fiv_i == 4'd8 )));
            // wsi_wires_o[9 ] = ((cip_i & (civ_i == 4'd9 )) | (fip_i & (fiv_i == 4'd9 )));
            // wsi_wires_o[10] = ((cip_i & (civ_i == 4'd10)) | (fip_i & (fiv_i == 4'd10)));
            // wsi_wires_o[11] = ((cip_i & (civ_i == 4'd11)) | (fip_i & (fiv_i == 4'd11)));
            // wsi_wires_o[12] = ((cip_i & (civ_i == 4'd12)) | (fip_i & (fiv_i == 4'd12)));
            // wsi_wires_o[13] = ((cip_i & (civ_i == 4'd13)) | (fip_i & (fiv_i == 4'd13)));
            // wsi_wires_o[14] = ((cip_i & (civ_i == 4'd14)) | (fip_i & (fiv_i == 4'd14)));
            // wsi_wires_o[15] = ((cip_i & (civ_i == 4'd15)) | (fip_i & (fiv_i == 4'd15)));
        end
    end
    
endmodule