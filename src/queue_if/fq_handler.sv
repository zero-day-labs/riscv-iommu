/*
    Author: Manuel Rodríguez, University of Minho
    Date: 16/02/2023

    Description: RISC-V IOMMU Fault Queue handler module.
*/

//! NOTES:
/*
    -   FSM triggered by the occurrence of a fault/event raised when processing transactions.
    -   // TODO: Implement support for faults originated from PCIe Message Requests
    -   Guest page faults caused by implicit memory accesses for first-stage address translation and 
        PDT Walk when Stage 2 is not Bare must be identified. 
        For the former case, we have the ptw_error_stage2_int_o signal from the PTW, which identifies faults 
        occurred during second-stage translations performed to find the final leaf GPA. 
        For the latter case, we can re-use the flush_cdw_o, which is set by the PTW to flush the CDW 
        when it requested an implicit second-stage translation to walk the PDT. To avoid identifing DC.fsc.pdtp
        translations as implicit accesses, the external condition should be:
        # is_implicit = ptw_error_stage2_int_o | (flush_cdw_o & ~is_ddt_walk)
*/

module fq_handler import ariane_pkg::*; #(
    parameter int unsigned DEVICE_ID_WIDTH = 24,
    parameter int unsigned PROCESS_ID_WIDTH  = 20,
    parameter ariane_pkg::ariane_cfg_t ArianeCfg = ariane_pkg::ArianeDefaultConfig
) (
    input  logic clk_i,
    input  logic rst_ni,

    // Regmap
    input  logic [riscv::PPNW-1:0]  fq_base_ppn_i,      // Base address of the FQ in memory (Should be aligned. See Spec)
    input  logic [4:0]              fq_size_i,          // Size of the FQ as log2-1 (2 entries: 0 | 4 entries: 1 | 8 entries: 2 | ...)

    input  logic                    fq_en_i,            // FQ enable bit from fqcsr, handled by SW
    input  logic                    fq_ie_i,            // FQ interrupt enable bit from fqcsr, handled by SW

    // INFO: Indexes are incremented by 1 each time a fault is read or written.
    input  logic [31:0]             fq_head_i,          // FQ head index (SW reads the next entry from fq_base + fq_head * 32 bytes)
    input  logic [31:0]             fq_tail_i,          // FQ tail index (IOMMU writes the next FQ entry to fq_base + fq_tail * 32 bytes)
    output logic [31:0]             fq_tail_o,

    output logic                    fq_on_o,            // FQ active bit. Indicates to SW whether the FQ is active or not
    output logic                    busy_o,             // FQ busy bit. Indicates SW that the FQ is in the middle of a state transition, 
                                                        //              so it has to wait to write to fqcsr.

    input logic                     fq_mf_i,             
    input logic                     fq_of_i,  

    output logic                    error_o,            // To enable write of corresponding error bit to regmap
    output logic                    fq_mf_o,            // Set when a memory fault occurred during FQ access
    output logic                    fq_of_o,            // The execution of a command lead to a timeout 
    output logic                    fq_ip_o,            // To set ipsr.fip register if a fault occurs and fq_ie is set

    // Event data
    input  logic                                event_valid,    // a fault/event has occurred
    input  logic [iommu_pkg::TTYP_LEN-1:0]      trans_type_i,   // transaction type
    input  logic [(iommu_pkg::CAUSE_LEN-1):0]   cause_code_i,   // Fault code as defined by IOMMU and Priv Spec
    //? complete VLEN for IOVA? Offset required?
    input  logic [riscv::VLEN-1:0]              iova_i,             // to report if transaction has an IOVA
    input  logic [riscv::SVX-1:0]               gpaddr,             // to report bits [63:2] of the GPA in case of a Guest Page Fault
    input  logic [DEVICE_ID_WIDTH-1:0]          did_i,              // device_id associated with the transaction
    input  logic                                pv_i,               // to indicate if transaction has a valid process_id
    input  logic [PROCESS_ID_WIDTH-1:0]         pid_i,              // process_id associated with the transaction
    input  logic                                is_supervisor_i,    // indicate if transaction has supervisor privilege (only if pid valid)
    input  logic                                is_guest_pf_i,      // indicate if event is a guest page fault
    input  logic                                is_implicit_i,      // Guest page fault caused by implicit access for 1st-stage addr translation

    // Memory Bus
    input  dcache_req_o_t           mem_resp_i,             // Response port from memory
    output dcache_req_i_t           mem_req_o               // Request port to memory
);

    // FSM States
    enum logic [1:0] {
        IDLE,
        WRITE,
        ERROR
    }   state_q, state_n;

    // Physical pointer to access memory
    logic [riscv::PLEN-1:0] fq_pptr_q, fq_pptr_n;

    // To mask the input tail index according to the size of the CQ
    logic [31:0]    masked_tail;
    assign          masked_tail = (fq_size_i <= 6) ? (fq_tail_i & 32'b0111_1111) : (fq_tail_i & ~({32{1'b1}} << (fq_size_i+1)));

    // Control busy signal to notice SW when is not possible to write to cqcsr
    logic fq_en_q, fq_en_n;
    assign busy_o = (fq_en_i != fq_en_q);

    /* 
        INFO: When the fqon bit reads 0, the IOMMU guarantees: 
              (i)  That there are no in-flight implicit writes to the FQ in progress;
              (ii) No new fault records will be written to the fault-queue.
    */
    assign fq_on_o = ~(!fq_en_q && !fq_en_i);

    // To check if any error bit was cleared by SW
    logic   error_vector;
    assign  error_vector    = (fq_mf_i | fq_of_i);

    // To enable write of error bits to regmap
    assign  error_o         = (fq_mf_o | fq_of_o);

    // FQ Record register to save event data
    iommu_pkg::fq_record_t fq_entry_q, fq_entry_n;

    //# Combinational logic
    always_comb begin : fq_handler
        
        // Default values
        fq_tail_o   = fq_tail_i;
        fq_mf_o     = fq_mf_i;
        fq_of_o     = fq_of_i;

        state_n     = state_q;
        fq_pptr_n   = fq_pptr_q;
        fq_entry_n  = fq_entry_q;

        case (state_q)

            // Monitor possible faults/events
            // Set FQ entry according to the fault and type of transaction
            IDLE: begin

                if (fq_en_i) begin

                    // FQ was recently enabled by SW. Clear fq_tail, fq_mf, and fq_of
                    if (!fq_en_q) begin
                        fq_tail_o   = '0;
                        fq_mf_o     = 1'b0;
                        fq_of_o     = 1'b0;
                        fq_en_n     = 1'b1;
                    end
                
                    else if (event_valid) begin

                        state_n = WRITE;

                        fq_entry_n.iotval2  = '0;
                        fq_entry_n.iotval   = '0;
                        fq_entry_n.did      = '0;
                        fq_entry_n.ttyp     = trans_type_i;
                        fq_entry_n.priv     = 1'b0;
                        fq_entry_n.pv       = 1'b0;
                        fq_entry_n.pid      = '0;
                        fq_entry_n.cause    = cause_code_i;

                        // If TTYP = 0 or fault occurred due to a PCIe Msg Request, nothing is reported in iotval/iotval2
                        // The DID, PV, PID, and PRIV fields are 0 if TTYP is 0
                        if (trans_type_i != iommu_pkg::NONE) begin
                            fq_entry_n.did      = did_i;
                            fq_entry_n.pid      = (pv_i) ? (pid_i) : ('0);
                            fq_entry_n.priv     = pv_i & is_supervisor_i;
                            fq_entry_n.pv       = pv_i;

                            if (trans_type_i != iommu_pkg::PCIE_MSG_REQ)
                                fq_entry_n.iotval   = iova_i;
                        end
                        
                        // If the CAUSE is a guest-page fault then bits 63:2 of the GPA are reported in iotval2[63:2].
                        if (is_guest_pf_i) begin

                                fq_entry_n.iotval2      = {22'b0, gpaddr};  // zero-extended GPA
                                fq_entry_n.iotval2[0]   = is_implicit_i;    // Guest page fault was caused by an implicit access
                                fq_entry_n.iotval2[1]   = 1'b0;             // Always zero since A/D update of bits is not implemented
                            end

                        // Set pptr with the paddr of the next entry
                        if (fq_size_i <= 6) fq_pptr_n = {fq_base_ppn_i, 12'b0} | {masked_tail, 5'b0};
                        else                fq_pptr_n = {fq_base_ppn_i << (fq_size_i+6)} | {masked_tail, 5'b0};

                        // If a fault that must be reported occurs and the FQ is full, set fq_of and signal error
                        if (fq_tail_i == fq_head_i - 1) begin
                            fq_of_o = 1'b1;
                            state_n = ERROR;
                        end
                    end
                end

                // Check if EN signal was recently cleared by SW
                else if (fq_en_q) begin
                    fq_en_n = 1'b0;
                end
            end

            // Remember to increment fq_tail after writting to FQ
            WRITE: begin
                
            end

            // When an error occurs, the FQ stops generating faults until SW clear all error bits
            // If FQ IE is set, the ipsr.fip must be set
            ERROR: begin
                if (!error_vector)
                    state_n = IDLE;

                if (fq_ie_i)
                    fq_ip_o = 1'b1;
            end

            default: state_n = IDLE;
        endcase
    end

    //# Sequential logic
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (~rst_ni) begin
            // Reset values
            state_q     <= IDLE;
            fq_pptr_q   <= '0;
            fq_entry_q  <= '0;
            fq_en_q     <= 1'b0;
        end

        else begin
            state_q     <= state_n;
            fq_pptr_q   <= fq_pptr_n;
            fq_entry_q  <= fq_entry_n;
            fq_en_q     <= fq_en_n;
        end
    end


endmodule