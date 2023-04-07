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
// Date: 12/10/2022
//
// Description: IOMMU Register field internal write arbiter.
//
// Disclaimer:  This file was generated using LowRISC `reggen` tool. Edit at your own risk.

// `include "packages/iommu_field_pkg.sv"

module iommu_field_arb
    import iommu_field_pkg::*;
    #(
        parameter int         DATA_WIDTH = 32,
        parameter sw_access_e SwAccess = SwAccessRW
    )
    (
        // From SW: valid for RW, WO, W1C, W1S, W0C, RC.
        // In case of RC, top connects read pulse to we.
        input                   we,
        input [DATA_WIDTH-1:0]  wd,

        // From HW: valid for HRW, HWO.
        input                   de,
        input [DATA_WIDTH-1:0]  d,

        // From register: actual reg value. (Needed to mask input value when W1S, W1C)
        input [DATA_WIDTH-1:0]  q,

        // To register: actual write enable and write data.
        output logic                    wr_en,
        output logic [DATA_WIDTH-1:0]   wr_data
    );

    // If RW or WO, allow write (if SW is not requesting write, set WD with HW D value)
    if (SwAccess inside {SwAccessRW, SwAccessWO}) begin : gen_w
        assign wr_en   = we | de;
        assign wr_data = (we == 1'b1) ? wd : d; // SW higher priority
        // Unused q - Prevent lint errors.
        logic [DATA_WIDTH-1:0] unused_q;
        assign unused_q = q;
    end

    // If RO, only allow HW writes
    else if (SwAccess == SwAccessRO) begin : gen_ro
        assign wr_en   = de;
        assign wr_data = d;
        // Unused we, wd, q - Prevent lint errors.
        logic                   unused_we;
        logic [DATA_WIDTH-1:0]  unused_wd;
        logic [DATA_WIDTH-1:0]  unused_q;
        assign unused_we = we;
        assign unused_wd = wd;
        assign unused_q  = q;
    end
    
    else if (SwAccess == SwAccessW1S) begin : gen_w1s
        // If SwAccess is W1S, then assume hw tries to clear. (Possible conflict case)
        // So, give a chance HW to clear when SW tries to set.
        // If both try to set/clr at the same bit pos, SW wins.
        assign wr_en   = we | de;
        assign wr_data = (de ? d : q) | (we ? wd : '0); // OR-mask input set bits with current reg value to set
    end
    
    else if (SwAccess == SwAccessW1C) begin : gen_w1c
        // If SwAccess is W1C, then assume hw tries to set.
        // So, give a chance HW to set when SW tries to clear.
        // If both try to set/clr at the same bit pos, SW wins.
        assign wr_en   = we | de;
        assign wr_data = (de ? d : q) & (we ? ~wd : '1);    // AND-ask input set bits (inverted) with current reg value to clear
    end
    
    else if (SwAccess == SwAccessW0C) begin : gen_w0c
        assign wr_en   = we | de;
        assign wr_data = (de ? d : q) & (we ? wd : '1); // AND-ask input set bits with current reg value to clear
    end
    
    else if (SwAccess == SwAccessRC) begin : gen_rc
        // This swtype is not recommended but exists for compatibility.
        // WARN: we signal is actually read signal not write enable.
        assign wr_en  = we | de;
        assign wr_data = (de ? d : q) & (we ? '0 : '1); // 
        // Unused wd - Prevent lint errors.
        logic [DATA_WIDTH-1:0] unused_wd;
        assign unused_wd = wd;
    end
    
    else begin : gen_hw
        assign wr_en   = de;
        assign wr_data = d;
        // Unused we, wd, q - Prevent lint errors.
        logic                   unused_we;
        logic [DATA_WIDTH-1:0]  unused_wd;
        logic [DATA_WIDTH-1:0]  unused_q;
        assign unused_we = we;
        assign unused_wd = wd;
        assign unused_q  = q;
    end

endmodule