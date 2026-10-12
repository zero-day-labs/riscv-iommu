// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Verilator 4.x driver for tests/iommu_ptw_leaf_tb.sv.
//
// Drives the real, unmodified rv_iommu_ptw through a real read-only AXI AR/R
// page-table port.  The page-table memory model lives in this file; the SV
// wrapper only exposes scalar PTW pins.  No hierarchical force into the PTW
// and no re-implementation of its internal branches.
//
// One process run handles one scenario selected with +scenario=<id>; with no
// plusarg it runs all defined scenarios and returns nonzero on any mismatch.

#include "Viommu_ptw_leaf_tb.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <string>

static vluint64_t sim_time = 0;
double sc_time_stamp() { return static_cast<double>(sim_time); }

// ---------------------------------------------------------------- PTE coding
// RISC-V Sv39 `pte_t` layout used by rv_iommu::pte_t:
//   [63:54] reserved, [53:10] ppn, [9:8] rsw, [7] d, [6] a, [5] g,
//   [4] u, [3] x, [2] w, [1] r, [0] v
enum {
    PTE_V = 1u << 0,
    PTE_R = 1u << 1,
    PTE_W = 1u << 2,
    PTE_X = 1u << 3,
    PTE_U = 1u << 4,
    PTE_G = 1u << 5,
    PTE_A = 1u << 6,
    PTE_D = 1u << 7,
};

static uint64_t make_pte(uint64_t ppn, uint64_t flags) {
    return ((ppn & 0xFFFFFFFFFFFULL) << 10) | (flags & 0x3FFULL);
}

// --------------------------------------------------------------- constants
static const int      MAX_CYCLES   = 1000;
static const int      DRAIN_CYCLES = 16;
static const int      RESET_CYCLES = 8;
static const uint64_t IOVA         = 0x0000000000201234ULL;  // vpn2=0 vpn1=1 vpn0=1 off=0x234

static const unsigned AXI_BURST_INCR = 1; // axi_pkg::BURST_INCR
static const uint64_t VPN_MASK       = (1ULL << 29) - 1; // update_vpn_o width

static uint64_t tbl_entry(uint64_t table_ppn, unsigned shift) {
    return (table_ppn << 12) | (((IOVA >> shift) & 0x1FF) << 3);
}

// --------------------------------------------------------------- data types
struct MemModel {
    std::map<uint64_t, uint64_t> ptes;
    void put(uint64_t addr, uint64_t pte) { ptes[addr & ~0x7ULL] = pte; }
    uint64_t get(uint64_t addr) const {
        std::map<uint64_t, uint64_t>::const_iterator it = ptes.find(addr & ~0x7ULL);
        return (it == ptes.end()) ? 0ULL : it->second;
    }
};

struct Scenario {
    int         id = 0;
    std::string name;
    bool        en_1S = true;
    bool        en_2S = false;
    bool        is_store = false;
    bool        expect_error = false;
    uint64_t    iosatp_ppn = 0;
    uint64_t    iohgatp_ppn = 0;
    bool        chk_1S_1G = false;
    bool        chk_1S_2M = false;
    uint64_t    exp_1S_ppn = 0;
    bool        chk_2S = false;
    bool        chk_2S_1G = false;
    bool        chk_2S_2M = false;
    uint64_t    exp_2S_ppn = 0;
    int         expected_ar = 0;
    uint16_t    exp_cause = 0;
    bool        exp_1S_v = true, exp_1S_r = true, exp_1S_w = true;
    bool        exp_1S_x = false, exp_1S_u = false, exp_1S_g = false;
    bool        exp_2S_v = true, exp_2S_r = true, exp_2S_w = true;
    bool        exp_2S_x = false, exp_2S_u = true,  exp_2S_g = false;
    MemModel    mem;
};

struct Observed {
    int      updates = 0;
    int      errors = 0;
    int      imp_errors = 0;
    int      error_2s = 0;
    int      error_2s_int = 0;
    int      ar_count = 0;
    int      r_count = 0;
    int      imp_dones = 0;
    int      msi_count = 0;
    int      protocol_errors = 0;
    std::string protocol_err;
    int      pending_r = 0;
    bool     final_r_valid = false;
    uint64_t update_vpn = 0;
    bool     u1_v = false, u1_r = false, u1_w = false, u1_x = false, u1_u = false, u1_g = false;
    bool     u2_v = false, u2_r = false, u2_w = false, u2_x = false, u2_u = false, u2_g = false;
    bool     saw_active = false;
    bool     idle_reached = false;
    int      idle_streak = 0;
    uint64_t u1_ppn = 0;
    bool     u1_1g = false, u1_2m = false;
    uint64_t u2_ppn = 0;
    bool     u2_1g = false, u2_2m = false;
    uint16_t cause = 0;
};

// --------------------------------------------------------------- scenario map
static bool build_scenario(int id, Scenario& sc) {
    sc.id = id;
    switch (id) {
        case 1: {
            sc.name = "s1_4k_read";
            sc.en_1S = true; sc.en_2S = false; sc.is_store = false;
            sc.iosatp_ppn = 0x400;
            sc.exp_1S_ppn = 0x12345;
            sc.expected_ar = 3;
            sc.mem.put(tbl_entry(0x400, 30), make_pte(0x401, PTE_V));
            sc.mem.put(tbl_entry(0x401, 21), make_pte(0x402, PTE_V));
            sc.mem.put(tbl_entry(0x402, 12), make_pte(0x12345, PTE_V|PTE_R|PTE_W|PTE_A|PTE_D));
            return true;
        }
        case 2: {
            sc.name = "s1_4k_write";
            sc.en_1S = true; sc.en_2S = false; sc.is_store = true;
            sc.iosatp_ppn = 0x400;
            sc.exp_1S_ppn = 0x12345;
            sc.expected_ar = 3;
            sc.mem.put(tbl_entry(0x400, 30), make_pte(0x401, PTE_V));
            sc.mem.put(tbl_entry(0x401, 21), make_pte(0x402, PTE_V));
            sc.mem.put(tbl_entry(0x402, 12), make_pte(0x12345, PTE_V|PTE_R|PTE_W|PTE_A|PTE_D));
            return true;
        }
        case 3: {
            sc.name = "s1_2m_read";
            sc.en_1S = true; sc.en_2S = false; sc.is_store = false;
            sc.chk_1S_2M = true;
            sc.iosatp_ppn = 0x400;
            sc.exp_1S_ppn = 0x20000;
            sc.expected_ar = 2;
            sc.mem.put(tbl_entry(0x400, 30), make_pte(0x401, PTE_V));
            sc.mem.put(tbl_entry(0x401, 21), make_pte(0x20000, PTE_V|PTE_R|PTE_W|PTE_A|PTE_D));
            return true;
        }
        case 4: {
            sc.name = "s1_1g_read";
            sc.en_1S = true; sc.en_2S = false; sc.is_store = false;
            sc.chk_1S_1G = true;
            sc.iosatp_ppn = 0x400;
            sc.exp_1S_ppn = 0x40000;
            sc.expected_ar = 1;
            sc.mem.put(tbl_entry(0x400, 30), make_pte(0x40000, PTE_V|PTE_R|PTE_W|PTE_A|PTE_D));
            return true;
        }
        case 5: {
            sc.name = "s1_invalid_v";
            sc.en_1S = true; sc.en_2S = false; sc.is_store = false;
            sc.expect_error = true;
            sc.exp_cause = 13; // LOAD_PAGE_FAULT
            sc.expected_ar = 3;
            sc.iosatp_ppn = 0x400;
            sc.mem.put(tbl_entry(0x400, 30), make_pte(0x401, PTE_V));
            sc.mem.put(tbl_entry(0x401, 21), make_pte(0x402, PTE_V));
            sc.mem.put(tbl_entry(0x402, 12), make_pte(0x12345, PTE_R|PTE_W|PTE_A|PTE_D)); // V=0
            return true;
        }
        case 6: {
            sc.name = "s1_write_d0";
            sc.en_1S = true; sc.en_2S = false; sc.is_store = true;
            sc.expect_error = true;
            sc.exp_cause = 15; // STORE_PAGE_FAULT
            sc.expected_ar = 3;
            sc.iosatp_ppn = 0x400;
            sc.mem.put(tbl_entry(0x400, 30), make_pte(0x401, PTE_V));
            sc.mem.put(tbl_entry(0x401, 21), make_pte(0x402, PTE_V));
            sc.mem.put(tbl_entry(0x402, 12), make_pte(0x12345, PTE_V|PTE_R|PTE_W|PTE_A)); // D=0
            return true;
        }
        case 7: {
            // Full two-stage Sv39/Sv39x4 walk, all levels 4 KiB.
            //
            // Guest memory map (all within the same 2 MiB G-region
            // 0x20_0000 - 0x3f_ffff, so the G-stage L1/L2 tables are shared):
            //   S1 root table GPA 0x200000 -> PA 0x1000000
            //   S1 L2   table GPA 0x201000 -> PA 0x1001000
            //   S1 L3   table GPA 0x202000 -> PA 0x1002000
            //   final GPA       0x203234   -> PA 0x1003234
            // with iova = 0x201234 (vpn2=0 vpn1=1 vpn0=1 off=0x234).
            //
            // G-stage tables:
            //   iohgatp_ppn=0x100 -> G root @ PA 0x100000
            //   G L2 L1 entry[0]  -> ppn 0x101
            //   G L3 L2 entry[1]  -> ppn 0x102
            //   G L3 leaves idx 0..3 -> ppn 0x1000..0x1003
            sc.name = "two_stage_4k";
            sc.en_1S = true; sc.en_2S = true; sc.is_store = false;
            sc.iosatp_ppn = 0x200;
            sc.iohgatp_ppn = 0x100;
            sc.chk_2S = true; sc.chk_2S_1G = false; sc.chk_2S_2M = false;
            sc.exp_1S_ppn = 0x203;
            sc.exp_2S_ppn = 0x1003;
            sc.expected_ar = 15;

            // G-stage tables (host physical)
            sc.mem.put(0x100000, make_pte(0x101, PTE_V));                        // root -> L2
            sc.mem.put(0x101008, make_pte(0x102, PTE_V));                        // L2  -> L3
            sc.mem.put(0x102000, make_pte(0x1000, PTE_V|PTE_R|PTE_W|PTE_U|PTE_A|PTE_D));
            sc.mem.put(0x102008, make_pte(0x1001, PTE_V|PTE_R|PTE_W|PTE_U|PTE_A|PTE_D));
            sc.mem.put(0x102010, make_pte(0x1002, PTE_V|PTE_R|PTE_W|PTE_U|PTE_A|PTE_D));
            sc.mem.put(0x102018, make_pte(0x1003, PTE_V|PTE_R|PTE_W|PTE_U|PTE_A|PTE_D));

            // S1 tables (guest physical, reached through the G-stage map)
            sc.mem.put(0x1000000, make_pte(0x201, PTE_V));                       // root -> L2
            sc.mem.put(0x1001008, make_pte(0x202, PTE_V));                       // L2  -> L3
            sc.mem.put(0x1002008, make_pte(0x203, PTE_V|PTE_R|PTE_W|PTE_A|PTE_D)); // S1 4K leaf
            return true;
        }
    }
    return false;
}

// ------------------------------------------------------------------- driver
static void tick_plain(Viommu_ptw_leaf_tb* top) {
    top->clk_i = 0; ++sim_time; top->eval();
    top->clk_i = 1; ++sim_time; top->eval();
}

static void drive_cycle(Viommu_ptw_leaf_tb* top, const MemModel& mem,
                        std::deque<uint64_t>& pending_r, Observed& obs) {
    // Low phase: present the registered read response, then sample outputs.
    bool     have_r = !pending_r.empty();
    uint64_t r_data = have_r ? pending_r.front() : 0ULL;

    top->clk_i      = 0;
    top->r_valid_i  = have_r ? 1 : 0;
    top->r_data_i   = r_data;
    top->r_resp_i   = 0; // RESP_OKAY
    ++sim_time;
    top->eval();

    // r_ready_o is combinational from the PTW state and r_valid_i.  A new
    // AR may only be accepted if no R response is outstanding, or if the
    // outstanding response is consumed in this same cycle.
    bool r_ready = (top->r_ready_o != 0);
    bool accept_ar = (!have_r || r_ready);
    top->ar_ready_i = accept_ar ? 1 : 0;
    top->eval();

    // -------- observe current-cycle combinational outputs --------
    if (top->active_o) {
        obs.saw_active = true;
        obs.idle_streak = 0;
    } else if (obs.saw_active) {
        obs.idle_streak++;
    }
    if (top->error_o)   { obs.errors++;   obs.cause = (uint16_t)top->cause_code_o; }
    if (top->imp_err_o) { obs.imp_errors++; }
    if (top->error_2S_o)     { obs.error_2s++; }
    if (top->error_2S_int_o) { obs.error_2s_int++; }
    if (top->imp_done_o)     { obs.imp_dones++; }
    if (top->gpaddr_is_msi_o){ obs.msi_count++; }
    if (top->update_valid_o) {
        obs.updates++;
        obs.update_vpn = top->update_vpn_o;
        obs.u1_v = (top->update_1S_v_o != 0);
        obs.u1_r = (top->update_1S_r_o != 0);
        obs.u1_w = (top->update_1S_w_o != 0);
        obs.u1_x = (top->update_1S_x_o != 0);
        obs.u1_u = (top->update_1S_u_o != 0);
        obs.u1_g = (top->update_1S_g_o != 0);
        obs.u1_ppn = top->update_1S_ppn_o;
        obs.u1_1g  = (top->update_1S_is_1G_o != 0);
        obs.u1_2m  = (top->update_1S_is_2M_o != 0);
        obs.u2_v = (top->update_2S_v_o != 0);
        obs.u2_r = (top->update_2S_r_o != 0);
        obs.u2_w = (top->update_2S_w_o != 0);
        obs.u2_x = (top->update_2S_x_o != 0);
        obs.u2_u = (top->update_2S_u_o != 0);
        obs.u2_g = (top->update_2S_g_o != 0);
        obs.u2_ppn = top->update_2S_ppn_o;
        obs.u2_1g  = (top->update_2S_is_1G_o != 0);
        obs.u2_2m  = (top->update_2S_is_2M_o != 0);
    }

    // -------- capture AR / R handshakes and update the response queue --------
    bool ar_fire = (top->ar_valid_o != 0) && (top->ar_ready_i != 0);
    bool r_fire  = have_r && (top->r_ready_o != 0);

    if (ar_fire) {
        obs.ar_count++;
        if (top->ar_id_o != 0 || top->ar_len_o != 0 ||
            top->ar_size_o != 3 || top->ar_burst_o != AXI_BURST_INCR) {
            obs.protocol_errors++;
            if (obs.protocol_err.empty())
                obs.protocol_err = "AR metadata mismatch (id/len/size/burst)";
        }
        if ((top->ar_addr_o & 0x7ULL) != 0) {
            obs.protocol_errors++;
            if (obs.protocol_err.empty())
                obs.protocol_err = "AR address is not 8-byte aligned";
        }
    }
    if (ar_fire && have_r && !r_fire) {
        obs.protocol_errors++;
        if (obs.protocol_err.empty())
            obs.protocol_err = "AR accepted while prior R response is still pending";
    }

    if (r_fire) {
        obs.r_count++;
        pending_r.pop_front();
    }
    if (ar_fire) {
        pending_r.push_back(mem.get(top->ar_addr_o));
    }

    // High phase (posedge).
    top->clk_i = 1;
    ++sim_time;
    top->eval();
}

static bool run_scenario(Viommu_ptw_leaf_tb* top, const Scenario& sc, Observed& obs) {
    // Reset.
    top->rst_ni       = 0;
    top->init_ptw_i   = 0;
    top->en_1S_i      = sc.en_1S ? 1 : 0;
    top->en_2S_i      = sc.en_2S ? 1 : 0;
    top->is_store_i   = sc.is_store ? 1 : 0;
    top->is_rx_i      = 0;
    top->iosatp_ppn_i = (uint64_t)sc.iosatp_ppn;
    top->iohgatp_ppn_i= (uint64_t)sc.iohgatp_ppn;
    top->iova_i       = IOVA;
    top->pscid_i      = 0;
    top->gscid_i      = 0;
    top->imp_init_i   = 0;
    top->pdt_gppn_i   = 0;
    top->ar_ready_i   = 1;
    top->r_valid_i    = 0;
    top->r_data_i     = 0;
    top->r_resp_i     = 0;
    top->clk_i        = 0;
    ++sim_time;
    top->eval();

    for (int i = 0; i < RESET_CYCLES; ++i) { tick_plain(top); }
    top->rst_ni = 1;
    top->clk_i  = 0;
    ++sim_time;
    top->eval();

    // Kick the walk.
    std::deque<uint64_t> pending_r;
    top->init_ptw_i = 1;

    for (int i = 0; i < MAX_CYCLES; ++i) {
        drive_cycle(top, sc.mem, pending_r, obs);
        if (i == 1) top->init_ptw_i = 0;
        if (obs.saw_active && obs.idle_streak >= DRAIN_CYCLES) {
            obs.idle_reached = true;
            break;
        }
    }
    obs.pending_r = (int)pending_r.size();
    obs.final_r_valid = !pending_r.empty();
    return obs.idle_reached;
}

static bool check_scenario(const Scenario& sc, const Observed& obs, std::string& msg) {
    char buf[512];
    if (!obs.idle_reached) {
        std::snprintf(buf, sizeof(buf),
                      "walker never returned to IDLE (AR reads=%d R reads=%d)",
                      obs.ar_count, obs.r_count);
        msg = buf; return false;
    }

    // Common AXI/handshake checks for every scenario.
    if (!obs.protocol_err.empty()) {
        msg = "AXI protocol error: " + obs.protocol_err; return false;
    }
    if (obs.protocol_errors != 0) {
        std::snprintf(buf, sizeof(buf), "AXI protocol errors=%d", obs.protocol_errors);
        msg = buf; return false;
    }
    if (obs.ar_count != sc.expected_ar) {
        std::snprintf(buf, sizeof(buf),
                      "AR handshakes=%d expected %d", obs.ar_count, sc.expected_ar);
        msg = buf; return false;
    }
    if (obs.r_count != sc.expected_ar) {
        std::snprintf(buf, sizeof(buf),
                      "R handshakes=%d expected %d", obs.r_count, sc.expected_ar);
        msg = buf; return false;
    }
    if (obs.ar_count != obs.r_count) {
        std::snprintf(buf, sizeof(buf),
                      "AR/R mismatch: AR=%d R=%d", obs.ar_count, obs.r_count);
        msg = buf; return false;
    }
    if (obs.pending_r != 0 || obs.final_r_valid) {
        std::snprintf(buf, sizeof(buf),
                      "pending R at end (queue=%d r_valid=%d)",
                      obs.pending_r, obs.final_r_valid ? 1 : 0);
        msg = buf; return false;
    }

    if (sc.expect_error) {
        if (obs.errors != 1) {
            std::snprintf(buf, sizeof(buf),
                          "expected exactly one error_o, got %d (AR reads=%d)",
                          obs.errors, obs.ar_count);
            msg = buf; return false;
        }
        if (obs.cause != sc.exp_cause) {
            std::snprintf(buf, sizeof(buf),
                          "cause=0x%03x expected 0x%03x",
                          (unsigned)obs.cause, (unsigned)sc.exp_cause);
            msg = buf; return false;
        }
        if (obs.error_2s != 0 || obs.error_2s_int != 0) {
            std::snprintf(buf, sizeof(buf),
                          "unexpected 2S error signals (error_2S=%d error_2S_int=%d)",
                          obs.error_2s, obs.error_2s_int);
            msg = buf; return false;
        }
        if (obs.imp_errors != 0) {
            std::snprintf(buf, sizeof(buf), "unexpected imp_err_o (count=%d)", obs.imp_errors);
            msg = buf; return false;
        }
        if (obs.imp_dones != 0 || obs.msi_count != 0) {
            std::snprintf(buf, sizeof(buf),
                          "unexpected completion/MSI on fault (imp_done=%d msi=%d)",
                          obs.imp_dones, obs.msi_count);
            msg = buf; return false;
        }
        if (obs.updates != 0) {
            std::snprintf(buf, sizeof(buf),
                          "illegal translation produced %d IOTLB update(s)", obs.updates);
            msg = buf; return false;
        }
        return true;
    }

    // Legal translation.
    if (obs.errors != 0) {
        std::snprintf(buf, sizeof(buf),
                      "unexpected error_o (count=%d cause=0x%03x) -- a legal page "
                      "must not fault (old bug: leaf-cycle update, next ERROR cycle report)",
                      obs.errors, (unsigned)obs.cause);
        msg = buf; return false;
    }
    if (obs.error_2s != 0 || obs.error_2s_int != 0) {
        std::snprintf(buf, sizeof(buf),
                      "unexpected 2S error signals (error_2S=%d error_2S_int=%d)",
                      obs.error_2s, obs.error_2s_int);
        msg = buf; return false;
    }
    if (obs.imp_errors != 0) {
        std::snprintf(buf, sizeof(buf), "unexpected imp_err_o (count=%d)", obs.imp_errors);
        msg = buf; return false;
    }
    if (obs.imp_dones != 0) {
        std::snprintf(buf, sizeof(buf), "unexpected imp_done_o (count=%d)", obs.imp_dones);
        msg = buf; return false;
    }
    if (obs.msi_count != 0) {
        std::snprintf(buf, sizeof(buf), "unexpected gpaddr_is_msi_o (count=%d)", obs.msi_count);
        msg = buf; return false;
    }
    if (obs.updates != 1) {
        std::snprintf(buf, sizeof(buf), "expected exactly 1 IOTLB update, got %d", obs.updates);
        msg = buf; return false;
    }

    const uint64_t exp_vpn = (IOVA >> 12) & VPN_MASK;
    if (obs.update_vpn != exp_vpn) {
        std::snprintf(buf, sizeof(buf),
                      "update.vpn=0x%llx expected 0x%llx",
                      (unsigned long long)obs.update_vpn, (unsigned long long)exp_vpn);
        msg = buf; return false;
    }

    // Strict page-size and PPN checks.  A large-page encoding must set
    // exactly one of is_1G/is_2M; the other bit must stay zero.
    if (obs.u1_1g != sc.chk_1S_1G || obs.u1_2m != sc.chk_1S_2M) {
        std::snprintf(buf, sizeof(buf),
                      "content_1S page size bits: is_1G=%d is_2M=%d expected is_1G=%d is_2M=%d",
                      obs.u1_1g ? 1 : 0, obs.u1_2m ? 1 : 0,
                      sc.chk_1S_1G ? 1 : 0, sc.chk_1S_2M ? 1 : 0);
        msg = buf; return false;
    }
    if (obs.u1_ppn != sc.exp_1S_ppn) {
        std::snprintf(buf, sizeof(buf),
                      "content_1S.ppn=0x%llx expected 0x%llx",
                      (unsigned long long)obs.u1_ppn, (unsigned long long)sc.exp_1S_ppn);
        msg = buf; return false;
    }
    if (obs.u1_v != sc.exp_1S_v || obs.u1_r != sc.exp_1S_r || obs.u1_w != sc.exp_1S_w ||
        obs.u1_x != sc.exp_1S_x || obs.u1_u != sc.exp_1S_u || obs.u1_g != sc.exp_1S_g) {
        std::snprintf(buf, sizeof(buf),
                      "content_1S flags mismatch (v=%d r=%d w=%d x=%d u=%d g=%d)",
                      obs.u1_v ? 1 : 0, obs.u1_r ? 1 : 0, obs.u1_w ? 1 : 0,
                      obs.u1_x ? 1 : 0, obs.u1_u ? 1 : 0, obs.u1_g ? 1 : 0);
        msg = buf; return false;
    }

    if (sc.chk_2S) {
        if (obs.u2_1g != sc.chk_2S_1G || obs.u2_2m != sc.chk_2S_2M) {
            std::snprintf(buf, sizeof(buf),
                          "content_2S page size bits: is_1G=%d is_2M=%d expected is_1G=%d is_2M=%d",
                          obs.u2_1g ? 1 : 0, obs.u2_2m ? 1 : 0,
                          sc.chk_2S_1G ? 1 : 0, sc.chk_2S_2M ? 1 : 0);
            msg = buf; return false;
        }
        if (obs.u2_ppn != sc.exp_2S_ppn) {
            std::snprintf(buf, sizeof(buf),
                          "content_2S.ppn=0x%llx expected 0x%llx",
                          (unsigned long long)obs.u2_ppn, (unsigned long long)sc.exp_2S_ppn);
            msg = buf; return false;
        }
        if (obs.u2_v != sc.exp_2S_v || obs.u2_r != sc.exp_2S_r || obs.u2_w != sc.exp_2S_w ||
            obs.u2_x != sc.exp_2S_x || obs.u2_u != sc.exp_2S_u || obs.u2_g != sc.exp_2S_g) {
            std::snprintf(buf, sizeof(buf),
                          "content_2S flags mismatch (v=%d r=%d w=%d x=%d u=%d g=%d)",
                          obs.u2_v ? 1 : 0, obs.u2_r ? 1 : 0, obs.u2_w ? 1 : 0,
                          obs.u2_x ? 1 : 0, obs.u2_u ? 1 : 0, obs.u2_g ? 1 : 0);
            msg = buf; return false;
        }
    } else {
        if (obs.u2_ppn != 0 || obs.u2_1g || obs.u2_2m) {
            msg = "unexpected content_2S update in single-stage scenario";
            return false;
        }
    }
    return true;
}

static const int NUM_SCENARIOS = 7;

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);

    int want = 0;
    for (int i = 1; i < argc; ++i) {
        if (std::strncmp(argv[i], "+scenario=", 10) == 0) {
            want = std::atoi(argv[i] + 10);
        }
    }

    Viommu_ptw_leaf_tb* top = new Viommu_ptw_leaf_tb;

    int rc    = 0;
    int first = (want == 0) ? 1 : want;
    int last  = (want == 0) ? NUM_SCENARIOS : want;

    for (int id = first; id <= last; ++id) {
        Scenario sc;
        if (!build_scenario(id, sc)) {
            std::fprintf(stderr, "ptw_leaf_tb: unknown scenario %d\n", id);
            rc = 1;
            continue;
        }
        Observed obs;
        bool ran = run_scenario(top, sc, obs);
        std::string msg;
        bool ok = ran && check_scenario(sc, obs, msg);
        std::printf("scenario %d (%s): %s [updates=%d errors=%d imp_err=%d AR=%d R=%d pending=%d]\n",
                    id, sc.name.c_str(), ok ? "PASS" : "FAIL",
                    obs.updates, obs.errors, obs.imp_errors, obs.ar_count, obs.r_count, obs.pending_r);
        if (!ok) {
            if (ran) std::printf("    reason: %s\n", msg.c_str());
            rc = 1;
        }
    }

    top->final();
    delete top;
    return rc;
}
