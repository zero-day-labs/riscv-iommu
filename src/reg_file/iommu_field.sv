// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Register slice conforming to Comportibility guide.
//
//
// Edited by: Manuel Rodríguez <manuel.cederog@gmail.com>
// Edited at: 12/10/2022
//
// IOMMU Register Field module: Instance of a variable width IOMMU register field

`include "packages/iommu_field_pkg.sv"

module iommu_field
    #(
        parameter int                           DATA_WIDTH = 32,        // bit width of the register field (2-state)
        parameter iommu_field_pkg::sw_access_e  SwAccess = SwAccessRW,  // SW access permission
        parameter logic [DATA_WIDTH-1:0]        RESVAL = '0             // reset value, 
    )
    (
        input clk_i,
        input rst_ni,

        // Signals from SW side: valid for RW, WO, W1C, W1S, W0C, RC
        // In case of RC, top module connects Read Pulse to WE. WD should be 1'b0 in this case ???
        input we,                           // SW WE
        input [DATA_WIDTH-1:0] wd,          // SW WD

        // From HW: valid for HRW, HWO
        input de,                           // HW WE
        input [DATA_WIDTH-1:0] d,           // HW WD

        // To HW and SW Reg IF read
        output logic qe,                    // definitive write enable
        output logic [DATA_WIDTH-1:0] q,    // HW read port

        output logic [DATA_WIDTH-1:0] ds,
        output logic [DATA_WIDTH-1:0] qs    // SW read port
    );

    import iommu_field_pkg::*;

    // Write arbiter output signals.
    // It takes WE, WD, DE, D, Q signals and yields the valid WE and WD that will cause writes to the register
    logic arb_wr_en;
    logic [DATA_WIDTH-1:0] arb_wr_data;

    // Data write arbiter
    iommu_field_arb #(
        .DATA_WIDTH(DATA_WIDTH),
        .SwAccess(SwAccess)
    ) int_wr_arb(
        .we(we),
        .wd(wd),
        .de(de),
        .d(d),
        .q(q),

        .wr_en(arb_wr_en),      // Arbitrated WE
        .wr_data(arb_wr_data)   // Arbitrated WD
    );

    // Register update logic
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            q <= RESVAL;
        end
        else if (arb_wr_en) begin
            q <= arb_wr_data;
        end
    end

    // outputs
    assign ds = arb_wr_en ? arb_wr_data : qs;
    assign qe = arb_wr_en;
    assign qs = q;
endmodule