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
// Date: 22/06/2023
//
// Description: RISC-V IOMMU Hardware Performance Monitor.

/*
    !NOTES:
        1.  The number of HPM event counters implemented may be discovered by SW by writing
            '1 to iocountinh register and reading back. Implemented counters will allow writing
            1 to their inhibit bits. Zeros in the returned value will represent unimplemented counters.

        2.  All event counters are inhibited from counting by default, as well as the clock cycles counter.

        3.  Not all input ID's are known at the moment an event happens. For example, GSCID/PSCID values are
            determined after performing a DDT/PDT walk, if they are not present in the context caches. Event
            counters programmed with ID matching using unknown ID values upon event occurrence will always
            increment without verifying the match condition.

        4.  Counter OF bits generate an interrupt when they undergo a transition from 0 to 1. However,
            these bits may be written by SW to disable interrupts. The logic must be implemented in a way
            that SW writes do not generate interrupts:
            -   Setting ipsr.pmip should not depend on OF transition only, but, when the OF bit of a counter
                is set, it cannot generate interrupts.
*/

module iommu_hpm #(

    // Number of Performance monitoring event counters (set to zero to disable HPM)
    parameter int unsigned  N_IOHPMCTR          = 0     // max 31
) (

    input  logic clk_i,
    input  logic rst_ni,

    // Event indicators
    input  logic tr_request_i,
    input  logic iotlb_miss_i,
    input  logic ddt_walk_i,
    input  logic pdt_walk_i,
    input  logic s1_ptw_i,
    input  logic s2_ptw_i,

    // ID filters
    input  logic [23:0]                 did_i,      // device_id associated with event
    input  logic [19:0]                 pid_i,      // process_id associated with event // TODO: Set optional ?
    input  logic [19:0]                 pscid_i,    // PSCID 
    input  logic [15:0]                 gscid_i,    // GSCID
    input  logic                        pid_v_i,    // process_id is valid

    // from HPM registers
    input  iommu_reg_pkg::iommu_reg2hw_iocountinh_reg_t                 iocountinh_i,   // inhibit 63-bit cycles counter
    input  iommu_reg_pkg::iommu_reg2hw_iohpmcycles_reg_t                iohpmcycles_i,  // clock cycle counter register
    input  iommu_reg_pkg::iommu_reg2hw_iohpmctr_reg_t [N_IOHPMCTR-1:0]  iohpmctr_i,     // event counters
    input  iommu_reg_pkg::iommu_reg2hw_iohpmevt_reg_t [N_IOHPMCTR-1:0]  iohpmevt_i,     // event configuration registers

    // to HPM registers
    output iommu_reg_pkg::iommu_hw2reg_iohpmcycles_reg_t                iohpmcycles_o,  // clock cycle counter value
    output iommu_reg_pkg::iommu_hw2reg_iohpmctr_reg_t [N_IOHPMCTR-1:0]  iohpmctr_o,     // event counters value
    output iommu_reg_pkg::iommu_hw2reg_iohpmevt_reg_t [N_IOHPMCTR-1:0]  iohpmevt_o,     // event configuration registers

    // ipsr.pmip
    output logic hpm_ip_o
);

    typedef enum logic[2:0] {
      UT_REQ,
      IOTLB_MISS,
      DDTW,
      PDTW,
      S1_PTW,
      S2_PTW
    } hpm_events;

    // To signal event counters increment
    logic [N_IOHPMCTR-1:0]  increment_ctr;

    // ID matching
    logic [N_IOHPMCTR-1:0]  did_match;
    logic [N_IOHPMCTR-1:0]  pid_match;
    logic [N_IOHPMCTR-1:0]  gscid_match;
    logic [N_IOHPMCTR-1:0]  pscid_match;

    // Interrupt wires
    logic [N_IOHPMCTR:0]    hpm_ip;
    assign                  hpm_ip_o    = |hpm_ip;

    // Edge detection
    logic [5:0] event_vector;
    logic [5:0] edged_event_q, edged_event_n;
    logic [5:0] count_q, count_n;
    assign event_vector = { 
        s2_ptw_i,
        s1_ptw_i,
        pdt_walk_i,
        ddt_walk_i,
        iotlb_miss_i,
        tr_request_i
    };

    // TODO: Change to FIFO. We must consider the possibility of having multiple events simultaneously
    logic [23:0] did_q, did_n;
    logic [19:0] pid_q, pid_n;
    logic [19:0] pscid_q, pscid_n;
    logic [15:0] gscid_q, gscid_n;
    logic        pid_v_q, pid_v_n;

    // Event and ID matching logic
    always_comb begin : event_logic

        for (int unsigned i = 0; i < N_IOHPMCTR; i++) begin

            increment_ctr[i] = 1'b0;

            // ID matching
            did_match[i]    = (did_q == iohpmevt_i[i].did_gscid.q);
            pid_match[i]    = ((pid_q == iohpmevt_i[i].pid_pscid.q) & pid_v_q);
            gscid_match[i]  = (gscid_q == iohpmevt_i[i].did_gscid.q[15:0]);
            pscid_match[i]  = (pscid_q == iohpmevt_i[i].pid_pscid.q);

            // Parse eventID
            if (((iohpmevt_i[i].eventid.q == rv_iommu::UT_REQ)      &&   count_q[UT_REQ]    ) ||
                ((iohpmevt_i[i].eventid.q == rv_iommu::IOTLB_MISS)  &&   count_q[IOTLB_MISS]) ||
                ((iohpmevt_i[i].eventid.q == rv_iommu::DDTW)        &&   count_q[DDTW]      ) ||
                ((iohpmevt_i[i].eventid.q == rv_iommu::PDTW)        &&   count_q[PDTW]      ) ||
                ((iohpmevt_i[i].eventid.q == rv_iommu::S1_PTW)      &&   count_q[S1_PTW]    ) ||
                ((iohpmevt_i[i].eventid.q == rv_iommu::S2_PTW)      &&   count_q[S2_PTW]    )
            ) begin
                
                // ID filtering
                case ({iohpmevt_i[i].idt.q, iohpmevt_i[i].dv_gscv.q, iohpmevt_i[i].pv_pscv.q})

                    // process_id filtering
                    3'b001: begin
                        increment_ctr[i] = pid_match[i];
                    end

                    // device_id filtering
                    3'b010: begin

                        // DID_GSCID partial matching
                        if (iohpmevt_i[i].dmask.q) begin

                            // Get index of starting bit
                            for (int unsigned k = 0 ; k < 24; k++) begin
                                if (!iohpmevt_i[i].did_gscid.q[k]) begin

                                    // Increment if bits [23:(k+1)] match
                                    // If k = 23, match always occurs
                                    increment_ctr[i] = ((did_q >> (k+1)) == (iohpmevt_i[i].did_gscid.q >> (k+1)));
                                    break;
                                end
                            end
                        end

                        // Do not perform partial matching
                        else
                            increment_ctr[i] = did_match[i];
                    end

                    // device_id and process_id filtering
                    3'b011: begin

                        // DID_GSCID partial matching (if PID_PSCID matches)
                        if (iohpmevt_i[i].dmask.q & pid_match[i]) begin

                            // Get index of starting bit
                            for (int unsigned k = 0 ; k < 24; k++) begin
                                if (!iohpmevt_i[i].did_gscid.q[k]) begin

                                    // Increment if bits [23:(k+1)] match
                                    increment_ctr[i] = ((did_q >> (k+1)) == (iohpmevt_i[i].did_gscid.q >> (k+1)));
                                    break;
                                end
                            end
                        end

                        // Do not perform DID_GSCID partial matching
                        else
                            increment_ctr[i] = did_match[i] & pid_match[i];
                    end

                    // PSCID filtering
                    3'b101: begin
                        if (count_q[IOTLB_MISS] || count_q[S1_PTW] || count_q[S2_PTW])
                            increment_ctr[i] = pscid_match[i];
                        else
                            // PSCID is not known for other events at the moment of happening.
                            // Increment without comparing.
                            increment_ctr[i] = 1'b1;
                    end

                    // GSCID filtering
                    3'b110: begin
                        
                        // GSCID is not known for other events at the moment of happening.
                        if (count_q[IOTLB_MISS] || count_q[S1_PTW] || count_q[S2_PTW] || count_q[PDTW]) begin

                            // DID_GSCID partial matching
                            if (iohpmevt_i[i].dmask.q) begin

                                // Get index of starting bit
                                for (int unsigned k = 0 ; k < 16; k++) begin
                                    if (!iohpmevt_i[i].did_gscid.q[k]) begin

                                        // Increment if bits [15:(k+1)] match
                                        increment_ctr[i] = ((gscid_q >> (k+1)) == (iohpmevt_i[i].did_gscid.q[15:0] >> (k+1)));
                                        break;
                                    end
                                end
                            end

                            // Do not perform partial matching
                            else
                                increment_ctr[i] = gscid_match[i];
                        end

                        else
                            // GSCID is not known for other events.
                            // Increment without comparing
                            increment_ctr[i] = 1'b1;
                    end

                    // GSCID and PSCID filtering
                    3'b111: begin

                        // PSCID is not known for other events.
                        if (count_q[IOTLB_MISS] || count_q[S1_PTW] || count_q[S2_PTW]) begin
                        
                            // DID_GSCID partial matching (if PID_PSCID matches)
                            if (iohpmevt_i[i].dmask.q & pscid_match[i]) begin

                                // Get index of starting bit
                                for (int unsigned k = 0 ; k < 16; k++) begin
                                    if (!iohpmevt_i[i].did_gscid.q[k]) begin

                                        // Increment if bits [15:(k+1)] match
                                        increment_ctr[i] = ((gscid_q >> (k+1)) == (iohpmevt_i[i].did_gscid.q[15:0] >> (k+1)));
                                        break;
                                    end
                                end
                            end

                            // Do not perform DID_GSCID partial matching
                            else
                                increment_ctr[i] = gscid_match[i] & pscid_match[i];
                        end

                        else
                            // PSCID is not known for other events.
                            // Increment without comparing
                            increment_ctr[i] = 1'b1;
                    end

                    // No filter, increment counter
                    default: begin
                        increment_ctr[i] = 1'b1;
                    end
                endcase
            end
        end
    end

    // Counter increment logic
    always_comb begin : increment_counters

        // Free clock cycles counter value
        iohpmcycles_o.counter.de = ~iocountinh_i.cy.q;          // enable counting
        iohpmcycles_o.counter.d  = iohpmcycles_i.counter.q + 1; // always increment

        // set OF when counter enabled and == '1
        iohpmcycles_o.of.de = (~iocountinh_i.cy.q) & (&iohpmcycles_i.counter.q);
        iohpmcycles_o.of.d  = 1'b1;

        // also set ipsr.pmip if OF bit is clear
        hpm_ip[0]           = (~iocountinh_i.cy.q) & (&iohpmcycles_i.counter.q) & (!iohpmcycles_i.of.q);

        for (int unsigned j = 0; j < N_IOHPMCTR; j++) begin
            
            // Default values for event counters
            iohpmctr_o[j].counter.de    = 1'b0;
            iohpmctr_o[j].counter.d     = iohpmctr_i[j].counter.q + 1;

            // Event OF flag
            iohpmevt_o[j].of.de         = 1'b0;
            iohpmevt_o[j].of.d          = 1'b1;
            
            // Increment event counter
            if ((increment_ctr[j]) && (~iocountinh_i.hpm.q[j])) begin
                
                iohpmctr_o[j].counter.de    = 1'b1;

                // enable OF setting when counter enabled, counter == '1 (will overflow) and event occurs
                iohpmevt_o[j].of.de         = (&iohpmctr_i[j].counter.q);

                // also set ipsr.pmip if the corresponding OF bit is clear
                hpm_ip[j+1]                 = (&iohpmctr_i[j].counter.q) & (!iohpmevt_i[j].of.q);
            end
        end
    end

    always_comb begin : edge_detection

        // Default
        edged_event_n   = edged_event_q;
        count_n         = count_q;

        for (int unsigned i = 0; i < 6; i++) begin

            if (event_vector[i] && !edged_event_q[i]) begin
                edged_event_n[i]    = 1'b1;
                count_n[i]          = 1'b1;

                //? One register per counter? Too much expensive...
                did_n               = did_i;
                pid_n               = pid_i;
                pscid_n             = pscid_i;
                gscid_n             = gscid_i;
                pid_v_n             = pid_v_i;
            end

            if (event_vector[i] && edged_event_q[i])
                count_n[i]          = 1'b0;

            if (!event_vector[i] && edged_event_q[i]) begin
                edged_event_n[i]    = 1'b0;
                count_n[i]          = 1'b0;
            end
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin

        if (~rst_ni) begin
            // reset
            edged_event_q   <= '0;
            count_q         <= '0;

            did_q           <= '0;
            pid_q           <= '0;
            pscid_q         <= '0;
            gscid_q         <= '0;
            pid_v_q         <= '0;
        end

        else begin
            edged_event_q   <= edged_event_n;
            count_q         <= count_n;

            did_q           <= did_n;
            pid_q           <= pid_n;
            pscid_q         <= pscid_n;
            gscid_q         <= gscid_n;
            pid_v_q         <= pid_v_n;
        end
        
    end

endmodule