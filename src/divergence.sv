`default_nettype none
`timescale 1ns/1ns

// SIMT DIVERGENCE UNIT
// > Owns current_pc, active_mask, done_mask, and a reconvergence stack.
// > Implements per-thread RET semantics with IPDOM-style stack reconvergence.
// > One unit per core. Replaces the single-PC "current_pc <= next_pc[N-1]" line
//   that lived in scheduler before this module existed.
//
// Algorithm at the UPDATE FSM state:
//   1. RET mask-off: active threads with decoded_ret get sticky-removed from
//      active_mask (and recorded in done_mask) before any further decision.
//   2. Compute lo_pc/hi_pc/lo_mask/hi_mask over the surviving active threads.
//      BRnzp is binary, so survivors have at most 2 distinct next_pc values.
//   3. If internally diverged (hi_mask != 0): PUSH (hi_pc, hi_mask), run lo.
//      Internal divergence takes priority over pop -- this avoids the 3-way
//      pop+re-diverge case in a single cycle.
//   4. Else if stack non-empty AND lo_pc >= stack_top.pc: POP.
//        - Clean reconverge if lo_pc == stack_top.pc: union surviving + popped,
//          run at lo_pc, ptr--.
//        - Leapfrog re-divergence if lo_pc > stack_top.pc: swap roles. Overwrite
//          top with (lo_pc, surviving_active), run popped from stack_top.pc.
//          Net stack depth unchanged.
//   5. Else if surviving_active != 0: just propagate (no stack op).
//   6. Else (surviving_active == 0): pop if stack non-empty (popped group becomes
//      the new active group); else block_done.
// > Pop test uses `>=` so unconditional jumps that leapfrog the saved reconverge
//   PC still trigger reconvergence. At most one stack op per cycle (push, pop,
//   or pop+push swap on leapfrog).
//
// Baseline before this module existed (THREADS_PER_BLOCK=4):
//   matadd = 178 cycles, matmul = 491 cycles.
// These cycle counts MUST stay identical for the no-divergence path. With no BR
// or only convergent BR, all threads always agree on next_pc, so internally
// diverged is false and the stack stays empty -- behavior reduces exactly to the
// old "current_pc <= next_pc[any]" update.
//
// Known limitation (matches every pre-Volta GPU): if the leader takes a backward
// branch whose exit condition is data-dependent on the deferred threads, those
// threads never run and the loop never exits => divergence-induced deadlock.
// Don't write tiny-gpu kernels that intra-warp-synchronize on each other.
module divergence #(
    parameter THREADS_PER_BLOCK = 4,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter STACK_DEPTH = 4
) (
    input wire clk,
    input wire reset,

    // Per-block alive mask: bit i set iff (i < thread_count). Combinational.
    input wire [THREADS_PER_BLOCK-1:0] alive_mask,

    // Scheduler FSM observation
    input reg [2:0] core_state,

    // Per-thread next-PC values (from each thread's pc_instance) and decoded RET
    input reg [PROGRAM_MEM_ADDR_BITS-1:0] next_pc [THREADS_PER_BLOCK-1:0],
    input reg decoded_ret,

    // Outputs to scheduler / fetcher / per-thread submodules
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] current_pc,
    output reg [THREADS_PER_BLOCK-1:0] active_mask,
    output reg [THREADS_PER_BLOCK-1:0] done_mask,
    output wire block_done,

    // Debug taps for HEX displays / cocotb tracing
    output wire [$clog2(STACK_DEPTH+1)-1:0] stack_ptr_dbg,
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] stack_top_pc_dbg,
    output wire [THREADS_PER_BLOCK-1:0] stack_top_mask_dbg
);
    localparam IDLE   = 3'b000;
    localparam UPDATE = 3'b110;

    localparam STACK_PTR_W = $clog2(STACK_DEPTH+1);

    // Stack state
    reg [PROGRAM_MEM_ADDR_BITS-1:0] stack_pc   [STACK_DEPTH-1:0];
    reg [THREADS_PER_BLOCK-1:0]     stack_mask [STACK_DEPTH-1:0];
    reg [STACK_PTR_W-1:0]           stack_ptr;

    // ========= Combinational divergence-step computation =========
    // These wires reflect the result of running the algorithm against the
    // current values of (next_pc[], decoded_ret, active_mask, done_mask, stack).
    // They become the new state at the next posedge clk in UPDATE.

    wire [THREADS_PER_BLOCK-1:0] just_returned    = active_mask & {THREADS_PER_BLOCK{decoded_ret}};
    wire [THREADS_PER_BLOCK-1:0] new_done_mask_w  = done_mask | just_returned;
    wire [THREADS_PER_BLOCK-1:0] surviving_active = active_mask & ~just_returned;

    // lo_pc = min(next_pc[i]) over surviving_active. lo_pc_valid iff surviving_active != 0.
    integer ii;
    reg [PROGRAM_MEM_ADDR_BITS-1:0] lo_pc_w;
    reg                             lo_pc_valid_w;
    always @(*) begin
        lo_pc_w       = {PROGRAM_MEM_ADDR_BITS{1'b1}};
        lo_pc_valid_w = 1'b0;
        for (ii = 0; ii < THREADS_PER_BLOCK; ii = ii + 1) begin
            if (surviving_active[ii]) begin
                if (!lo_pc_valid_w || next_pc[ii] < lo_pc_w) begin
                    lo_pc_w = next_pc[ii];
                end
                lo_pc_valid_w = 1'b1;
            end
        end
    end

    // lo_mask: surviving threads at lo_pc. hi_mask: surviving threads not at lo_pc.
    // hi_pc: any next_pc value of a hi_mask thread (they all agree because BRnzp is binary).
    reg [THREADS_PER_BLOCK-1:0]     lo_mask_w;
    reg [THREADS_PER_BLOCK-1:0]     hi_mask_w;
    reg [PROGRAM_MEM_ADDR_BITS-1:0] hi_pc_w;
    always @(*) begin
        lo_mask_w = {THREADS_PER_BLOCK{1'b0}};
        hi_mask_w = {THREADS_PER_BLOCK{1'b0}};
        hi_pc_w   = {PROGRAM_MEM_ADDR_BITS{1'b0}};
        for (ii = 0; ii < THREADS_PER_BLOCK; ii = ii + 1) begin
            if (surviving_active[ii]) begin
                if (next_pc[ii] == lo_pc_w) begin
                    lo_mask_w[ii] = 1'b1;
                end else begin
                    hi_mask_w[ii] = 1'b1;
                    hi_pc_w       = next_pc[ii];
                end
            end
        end
    end

    wire internally_diverged = (hi_mask_w != {THREADS_PER_BLOCK{1'b0}});

    wire stack_nonempty = (stack_ptr != {STACK_PTR_W{1'b0}});

    // Top-of-stack readout (guarded so we don't index with 0-1 when empty).
    wire [STACK_PTR_W-1:0]           top_idx_w  = stack_nonempty ? (stack_ptr - 1'b1) : {STACK_PTR_W{1'b0}};
    wire [PROGRAM_MEM_ADDR_BITS-1:0] top_pc_w   = stack_nonempty ? stack_pc[top_idx_w]   : {PROGRAM_MEM_ADDR_BITS{1'b0}};
    wire [THREADS_PER_BLOCK-1:0]     top_mask_w = stack_nonempty ? stack_mask[top_idx_w] : {THREADS_PER_BLOCK{1'b0}};
    wire [THREADS_PER_BLOCK-1:0]     pop_mask_w = top_mask_w & ~new_done_mask_w; // RET-respecting

    wire can_pop_normal     = stack_nonempty && lo_pc_valid_w && !internally_diverged
                              && (lo_pc_w >= top_pc_w);
    wire surviving_empty    = !lo_pc_valid_w; // surviving_active == 0
    wire can_pop_when_empty = stack_nonempty && surviving_empty;

    // Determine final new state
    reg [PROGRAM_MEM_ADDR_BITS-1:0] new_current_pc_w;
    reg [THREADS_PER_BLOCK-1:0]     new_active_mask_w;
    reg [STACK_PTR_W-1:0]           new_stack_ptr_w;
    reg                             stack_write_en_w;
    reg [STACK_PTR_W-1:0]           stack_write_idx_w;
    reg [PROGRAM_MEM_ADDR_BITS-1:0] stack_write_pc_w;
    reg [THREADS_PER_BLOCK-1:0]     stack_write_mask_w;
    reg                             block_done_w;

    always @(*) begin
        new_current_pc_w   = current_pc;
        new_active_mask_w  = surviving_active;
        new_stack_ptr_w    = stack_ptr;
        stack_write_en_w   = 1'b0;
        stack_write_idx_w  = {STACK_PTR_W{1'b0}};
        stack_write_pc_w   = {PROGRAM_MEM_ADDR_BITS{1'b0}};
        stack_write_mask_w = {THREADS_PER_BLOCK{1'b0}};
        block_done_w       = 1'b0;

        if (internally_diverged) begin
            // PUSH (hi_pc, hi_mask), run lo
            new_current_pc_w   = lo_pc_w;
            new_active_mask_w  = lo_mask_w;
            stack_write_en_w   = 1'b1;
            stack_write_idx_w  = stack_ptr;
            stack_write_pc_w   = hi_pc_w;
            stack_write_mask_w = hi_mask_w;
            new_stack_ptr_w    = stack_ptr + 1'b1;
        end else if (can_pop_normal) begin
            if (lo_pc_w == top_pc_w) begin
                // Clean reconverge: union surviving + popped, sit at lo_pc
                new_current_pc_w  = lo_pc_w;
                new_active_mask_w = surviving_active | pop_mask_w;
                new_stack_ptr_w   = stack_ptr - 1'b1;
            end else begin
                // Leapfrog re-divergence: lo_pc > top_pc. Swap roles. Leader becomes
                // deferred at lo_pc, popped group becomes new leader at top_pc.
                if (pop_mask_w != {THREADS_PER_BLOCK{1'b0}}) begin
                    new_current_pc_w   = top_pc_w;
                    new_active_mask_w  = pop_mask_w;
                    stack_write_en_w   = 1'b1;
                    stack_write_idx_w  = top_idx_w;     // overwrite top, ptr unchanged
                    stack_write_pc_w   = lo_pc_w;
                    stack_write_mask_w = surviving_active;
                end else begin
                    // All popped threads have RETed; just discard the stack entry
                    new_current_pc_w  = lo_pc_w;
                    new_active_mask_w = surviving_active;
                    new_stack_ptr_w   = stack_ptr - 1'b1;
                end
            end
        end else if (lo_pc_valid_w) begin
            // No divergence, no pop: just propagate
            new_current_pc_w  = lo_pc_w;
            new_active_mask_w = surviving_active;
        end else if (can_pop_when_empty) begin
            // surviving_active == 0, stack non-empty: pop and adopt
            if (pop_mask_w != {THREADS_PER_BLOCK{1'b0}}) begin
                new_current_pc_w  = top_pc_w;
                new_active_mask_w = pop_mask_w;
            end else begin
                // Popped group all RETed; pop and let next cycle handle the next pop
                new_current_pc_w  = current_pc;
                new_active_mask_w = {THREADS_PER_BLOCK{1'b0}};
            end
            new_stack_ptr_w = stack_ptr - 1'b1;
        end else begin
            // surviving_active == 0 AND stack empty -> block done
            new_active_mask_w = {THREADS_PER_BLOCK{1'b0}};
            block_done_w      = 1'b1;
        end
    end

    assign block_done         = block_done_w && (core_state == UPDATE);
    assign stack_ptr_dbg      = stack_ptr;
    assign stack_top_pc_dbg   = top_pc_w;
    assign stack_top_mask_dbg = top_mask_w;

    // ========= Sequential update =========
    integer si;
    always @(posedge clk) begin
        if (reset) begin
            current_pc  <= {PROGRAM_MEM_ADDR_BITS{1'b0}};
            active_mask <= {THREADS_PER_BLOCK{1'b0}};
            done_mask   <= {THREADS_PER_BLOCK{1'b0}};
            stack_ptr   <= {STACK_PTR_W{1'b0}};
            for (si = 0; si < STACK_DEPTH; si = si + 1) begin
                stack_pc[si]   <= {PROGRAM_MEM_ADDR_BITS{1'b0}};
                stack_mask[si] <= {THREADS_PER_BLOCK{1'b0}};
            end
        end else if (core_state == IDLE) begin
            // Prime active_mask from alive_mask before scheduler leaves IDLE.
            // Idempotent across multiple IDLE cycles.
            active_mask <= alive_mask;
            current_pc  <= {PROGRAM_MEM_ADDR_BITS{1'b0}};
            done_mask   <= {THREADS_PER_BLOCK{1'b0}};
            stack_ptr   <= {STACK_PTR_W{1'b0}};
        end else if (core_state == UPDATE) begin
            current_pc  <= new_current_pc_w;
            active_mask <= new_active_mask_w;
            done_mask   <= new_done_mask_w;
            stack_ptr   <= new_stack_ptr_w;
            if (stack_write_en_w) begin
                stack_pc[stack_write_idx_w]   <= stack_write_pc_w;
                stack_mask[stack_write_idx_w] <= stack_write_mask_w;
            end
        end
    end
endmodule
