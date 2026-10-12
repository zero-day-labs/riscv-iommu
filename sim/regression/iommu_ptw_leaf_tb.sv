// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Test-only wrapper around the UNMODIFIED production rv_iommu_ptw.
//
// It instantiates the real PTW, exposes its scalar configuration/status pins
// and a read-only AXI (AR/R) page-table port, and lets the C++ driver own the
// page-table memory model.  No hierarchical signal is forced and no internal
// FSM branch is mirrored here.
//
// Pinned to the upstream rv_iommu_ptw port list, which has NO e3_level_o
// output.  The old platform wrapper exposed an extra e3_level_o port that the
// C++ driver never reads; it is removed here so the wrapper compiles against
// the upstream PTW.

`include "axi/typedef.svh"

module iommu_ptw_leaf_tb
  import rv_iommu::*;
  import rv_iommu_cfg::*;
  import axi_pkg::*;
(
    input  logic        clk_i,
    input  logic        rst_ni,

    // PTW configuration / request (driven by C++)
    input  logic        init_ptw_i,
    input  logic        en_1S_i,
    input  logic        en_2S_i,
    input  logic        is_store_i,
    input  logic        is_rx_i,
    input  logic [43:0] iosatp_ppn_i,
    input  logic [43:0] iohgatp_ppn_i,
    input  logic [63:0] iova_i,
    input  logic [19:0] pscid_i,
    input  logic [15:0] gscid_i,
    input  logic        imp_init_i,
    input  logic [43:0] pdt_gppn_i,

    // Read-only AXI memory port (AR / R)
    input  logic        ar_ready_i,
    input  logic        r_valid_i,
    input  logic [63:0] r_data_i,
    input  logic [1:0]  r_resp_i,
    output logic        ar_valid_o,
    output logic [63:0] ar_addr_o,
    output logic [3:0]  ar_id_o,
    output logic [7:0]  ar_len_o,
    output logic [2:0]  ar_size_o,
    output logic [1:0]  ar_burst_o,
    output logic        r_ready_o,

    // Status
    output logic        active_o,
    output logic        error_o,
    output logic        error_2S_o,
    output logic        error_2S_int_o,
    output logic [40:0] bad_gpaddr_o,
    output logic [11:0] cause_code_o,
    output logic        imp_done_o,
    output logic        imp_err_o,
    output logic        gpaddr_is_msi_o,

    // IOTLB update content (flattened for the C++ driver)
    output logic        update_valid_o,
    output logic [28:0] update_vpn_o,
    output logic        update_1S_v_o,
    output logic        update_1S_r_o,
    output logic        update_1S_w_o,
    output logic        update_1S_x_o,
    output logic        update_1S_u_o,
    output logic        update_1S_g_o,
    output logic        update_1S_is_1G_o,
    output logic        update_1S_is_2M_o,
    output logic [43:0] update_1S_ppn_o,
    output logic        update_2S_v_o,
    output logic        update_2S_r_o,
    output logic        update_2S_w_o,
    output logic        update_2S_x_o,
    output logic        update_2S_u_o,
    output logic        update_2S_g_o,
    output logic        update_2S_is_1G_o,
    output logic        update_2S_is_2M_o,
    output logic [43:0] update_2S_ppn_o
);

    typedef logic [63:0] addr_t;
    typedef logic [55:0] paddr_t;

    `AXI_TYPEDEF_AW_CHAN_T(axi_aw_chan_t, logic [63:0], logic [3:0], logic [0:0])
    `AXI_TYPEDEF_W_CHAN_T (axi_w_chan_t,  logic [63:0], logic [7:0], logic [0:0])
    `AXI_TYPEDEF_B_CHAN_T (axi_b_chan_t,  logic [3:0],  logic [0:0])
    `AXI_TYPEDEF_AR_CHAN_T(axi_ar_chan_t, logic [63:0], logic [3:0], logic [0:0])
    `AXI_TYPEDEF_R_CHAN_T (axi_r_chan_t,  logic [63:0], logic [3:0], logic [0:0])
    `AXI_TYPEDEF_REQ_T    (axi_req_t,     axi_aw_chan_t, axi_w_chan_t, axi_ar_chan_t)
    `AXI_TYPEDEF_RESP_T   (axi_resp_t,    axi_b_chan_t,  axi_r_chan_t)

    localparam rv_iommu_cfg::rv_iommu_cfg_t RVIOMMUCfg = rv_iommu_cfg::rv_iommu_cfg_t'{
        NumOutstandingTrans : 1,
        WFifoDepth          : 1,
        MrifFifoDepth       : 1,
        FaultFifoDepth      : 1,
        NumIotlbEntries     : 16,
        NumDdtcEntries      : 8,
        NumPdtcEntries      : 1,
        NumMrifcEntries     : 1,
        InclPC              : 1'b0,
        InclAxiBC           : 1'b0,
        InclDbg             : 1'b0,
        InclATS             : 1'b0,
        MSITrans            : rv_iommu_cfg::MSI_DISABLED,
        IGS                 : rv_iommu_cfg::MSI_ONLY,
        NumIntVec           : 1,
        NumHpmCounters      : 0,
        PAddrWidth          : 56,
        AxiAddrWidth        : 64,
        AxiDataWidth        : 64,
        AxiIdWidth          : 4,
        AxiProgIdWidth      : 4,
        AxiUserWidth        : 1,
        AxiProIdWidth       : 1,
        AxiDevIdWidth       : 1,
        AxisDataWidth       : 64,
        AxisDestWidth       : 1,
        AxisUserWidth       : 1,
        AxisStrbWidth       : 8,
        AxisKeepWidth       : 8,
        AxisIdWidth         : 4,
        Freq                : 1
    };

    axi_req_t  ptw_req;
    axi_resp_t ptw_resp;
    iotlb_up_t ptw_update;

    // Read-only memory: only AR/R are used.  '0 the whole struct first so that
    // fields not driven here are deterministic.
    always_comb begin
        ptw_resp              = '0;
        ptw_resp.ar_ready     = ar_ready_i;
        ptw_resp.r_valid      = r_valid_i;
        ptw_resp.r.data       = r_data_i;
        ptw_resp.r.resp       = r_resp_i;
        ptw_resp.r.last       = 1'b1;
        ptw_resp.r.id         = '0;
    end

    assign ar_valid_o = ptw_req.ar_valid;
    assign ar_addr_o  = ptw_req.ar.addr;
    assign ar_id_o    = ptw_req.ar.id;
    assign ar_len_o   = ptw_req.ar.len;
    assign ar_size_o  = ptw_req.ar.size;
    assign ar_burst_o = ptw_req.ar.burst;
    assign r_ready_o  = ptw_req.r_ready;

    assign update_valid_o    = ptw_update.update;
    assign update_vpn_o      = ptw_update.vpn;
    assign update_1S_v_o     = ptw_update.content.content_1S.v;
    assign update_1S_r_o     = ptw_update.content.content_1S.r;
    assign update_1S_w_o     = ptw_update.content.content_1S.w;
    assign update_1S_x_o     = ptw_update.content.content_1S.x;
    assign update_1S_u_o     = ptw_update.content.content_1S.u;
    assign update_1S_g_o     = ptw_update.content.content_1S.g;
    assign update_1S_is_1G_o = ptw_update.content.content_1S.is_1G;
    assign update_1S_is_2M_o = ptw_update.content.content_1S.is_2M;
    assign update_1S_ppn_o   = ptw_update.content.content_1S.ppn;
    assign update_2S_v_o     = ptw_update.content.content_2S.v;
    assign update_2S_r_o     = ptw_update.content.content_2S.r;
    assign update_2S_w_o     = ptw_update.content.content_2S.w;
    assign update_2S_x_o     = ptw_update.content.content_2S.x;
    assign update_2S_u_o     = ptw_update.content.content_2S.u;
    assign update_2S_g_o     = ptw_update.content.content_2S.g;
    assign update_2S_is_1G_o = ptw_update.content.content_2S.is_1G;
    assign update_2S_is_2M_o = ptw_update.content.content_2S.is_2M;
    assign update_2S_ppn_o   = ptw_update.content.content_2S.ppn;

    rv_iommu_ptw #(
        .RVIOMMUCfg (RVIOMMUCfg),
        .addr_t     (addr_t),
        .paddr_t    (paddr_t),
        .axi_req_t  (axi_req_t),
        .axi_resp_t (axi_resp_t)
    ) i_ptw (
        .clk_i,
        .rst_ni,
        .init_ptw_i,
        .active_o,
        .error_o,
        .error_2S_o,
        .error_2S_int_o,
        .bad_gpaddr_o,
        .cause_code_o,
        .en_1S_i,
        .en_2S_i,
        .is_store_i,
        .is_rx_i,
        .iosatp_ppn_i,
        .iohgatp_ppn_i,
        .iova_i            (addr_t'(iova_i)),
        .pscid_i,
        .gscid_i,
        .update_o          (ptw_update),
        .msi_en_i          (1'b0),
        .msi_addr_mask_i   ('0),
        .msi_addr_pattern_i('0),
        .gpaddr_is_msi_o,
        .msi_1S_content_o  (),
        .imp_init_i,
        .pdt_gppn_i,
        .imp_done_o,
        .imp_err_o,
        .mem_resp_i        (ptw_resp),
        .mem_req_o         (ptw_req)
    );

endmodule
