`default_nettype none
`timescale 1ns/1ns

// COMPUTE CORE
// > Handles processing 1 block at a time
// > The core also has it's own scheduler to manage control flow
// > Each core contains 1 fetcher & decoder, and register files, ALUs, LSUs, PC for each thread
module core #(
    parameter DATA_MEM_ADDR_BITS = 8,
    parameter DATA_MEM_DATA_BITS = 8,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16,
    parameter THREADS_PER_BLOCK = 4,
    parameter STACK_DBG_W = $clog2(THREADS_PER_BLOCK + 1)
) (
    input wire clk,
    input wire reset,

    // Kernel Execution
    input wire start,
    output wire done,

    // Block Metadata
    input wire [7:0] block_id,
    input wire [$clog2(THREADS_PER_BLOCK):0] thread_count,

    // Program Memory
    output reg program_mem_read_valid,
    output reg [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address,
    input reg program_mem_read_ready,
    input reg [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data,

    // Data Memory
    output reg [THREADS_PER_BLOCK-1:0] data_mem_read_valid,
    output reg [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [THREADS_PER_BLOCK-1:0],
    input reg [THREADS_PER_BLOCK-1:0] data_mem_read_ready,
    input reg [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [THREADS_PER_BLOCK-1:0],
    output reg [THREADS_PER_BLOCK-1:0] data_mem_write_valid,
    output reg [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [THREADS_PER_BLOCK-1:0],
    output reg [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [THREADS_PER_BLOCK-1:0],
    input reg [THREADS_PER_BLOCK-1:0] data_mem_write_ready,

    output wire [PROGRAM_MEM_ADDR_BITS-1:0] dbg_current_pc,
    output wire [THREADS_PER_BLOCK-1:0] dbg_active_mask,
    output wire [THREADS_PER_BLOCK-1:0] dbg_done_mask,
    output wire [STACK_DBG_W-1:0] dbg_stack_ptr,

    // Hardware / Signal Tap: scheduler + per-lane LSU handshake (core 0 on GPU top)
    output wire [2:0] dbg_core_state,
    output wire [2:0] dbg_fetcher_state,
    output wire [THREADS_PER_BLOCK-1:0] dbg_lsu_waiting,
    output wire [THREADS_PER_BLOCK-1:0] dbg_lsu_requesting,
    output wire dbg_any_lsu_waiting
);
    // State
    reg [2:0] core_state;
    reg [2:0] fetcher_state;
    reg [15:0] instruction;

    // Intermediate Signals
    wire [7:0] current_pc;
    wire [7:0] next_pc[THREADS_PER_BLOCK-1:0];
    reg [7:0] rs[THREADS_PER_BLOCK-1:0];
    reg [7:0] rt[THREADS_PER_BLOCK-1:0];
    reg [1:0] lsu_state[THREADS_PER_BLOCK-1:0];
    reg [7:0] lsu_out[THREADS_PER_BLOCK-1:0];
    wire [7:0] alu_out[THREADS_PER_BLOCK-1:0];

    // Divergence-unit signals: per-warp active mask, sticky RET mask, block done.
    // alive_mask gates "this slot has a real thread"; active_mask gates "this thread
    // is currently executing this cycle." Per-thread enables are the AND of the two,
    // which lets the divergence unit silently disable threads without clobbering
    // their stored next_pc / NZP / register state during the deferred period.
    wire [THREADS_PER_BLOCK-1:0] alive_mask;
    wire [THREADS_PER_BLOCK-1:0] active_mask;
    wire [THREADS_PER_BLOCK-1:0] done_mask;
    wire [THREADS_PER_BLOCK-1:0] thread_active;
    wire block_done;

    wire [STACK_DBG_W-1:0] stack_ptr_dbg_sig;

    // Decoded Instruction Signals
    reg [3:0] decoded_rd_address;
    reg [3:0] decoded_rs_address;
    reg [3:0] decoded_rt_address;
    reg [2:0] decoded_nzp;
    reg [7:0] decoded_immediate;

    // Decoded Control Signals
    reg decoded_reg_write_enable;           // Enable writing to a register
    reg decoded_mem_read_enable;            // Enable reading from memory
    reg decoded_mem_write_enable;           // Enable writing to memory
    reg decoded_nzp_write_enable;           // Enable writing to NZP register
    reg [1:0] decoded_reg_input_mux;        // Select input to register
    reg [1:0] decoded_alu_arithmetic_mux;   // Select arithmetic operation
    reg decoded_alu_output_mux;             // Select operation in ALU
    reg decoded_pc_mux;                     // Select source of next PC
    reg decoded_ret;

    // Fetcher
    fetcher #(
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS)
    ) fetcher_instance (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .current_pc(current_pc),
        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data),
        .fetcher_state(fetcher_state),
        .instruction(instruction) 
    );

    // Decoder
    decoder decoder_instance (
        .clk(clk),
        .reset(reset),
        .core_state(core_state),
        .instruction(instruction),
        .decoded_rd_address(decoded_rd_address),
        .decoded_rs_address(decoded_rs_address),
        .decoded_rt_address(decoded_rt_address),
        .decoded_nzp(decoded_nzp),
        .decoded_immediate(decoded_immediate),
        .decoded_reg_write_enable(decoded_reg_write_enable),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .decoded_nzp_write_enable(decoded_nzp_write_enable),
        .decoded_reg_input_mux(decoded_reg_input_mux),
        .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
        .decoded_alu_output_mux(decoded_alu_output_mux),
        .decoded_pc_mux(decoded_pc_mux),
        .decoded_ret(decoded_ret)
    );

    wire any_lsu_waiting;
    // Scheduler
    scheduler #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) scheduler_instance (
        .clk(clk),
        .reset(reset),
        .start(start),
        .fetcher_state(fetcher_state),
        .core_state(core_state),
        .decoded_mem_read_enable(decoded_mem_read_enable),
        .decoded_mem_write_enable(decoded_mem_write_enable),
        .lsu_state(lsu_state),
        .block_done(block_done),
        .done(done),
        .any_lsu_waiting(any_lsu_waiting)
    );

    assign dbg_any_lsu_waiting = any_lsu_waiting;

    // Divergence unit owns current_pc, active_mask, done_mask, and the SIMT
    // reconvergence stack. See src/divergence.sv for the algorithm.
    divergence #(
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .STACK_DEPTH(THREADS_PER_BLOCK)
    ) divergence_instance (
        .clk(clk),
        .reset(reset),
        .alive_mask(alive_mask),
        .core_state(core_state),
        .next_pc(next_pc),
        .decoded_ret(decoded_ret),
        .current_pc(current_pc),
        .active_mask(active_mask),
        .done_mask(done_mask),
        .block_done(block_done),
        .stack_ptr_dbg(stack_ptr_dbg_sig),
        .stack_top_pc_dbg(),
        .stack_top_mask_dbg()
    );

    assign dbg_current_pc = current_pc;
    assign dbg_active_mask = active_mask;
    assign dbg_done_mask = done_mask;
    assign dbg_stack_ptr = stack_ptr_dbg_sig;

    assign dbg_core_state = core_state;
    assign dbg_fetcher_state = fetcher_state;

    genvar dbg_li;
    generate
        for (dbg_li = 0; dbg_li < THREADS_PER_BLOCK; dbg_li = dbg_li + 1) begin : dbg_lsu_flags
            assign dbg_lsu_waiting[dbg_li]    = (lsu_state[dbg_li] == 2'b10);
            assign dbg_lsu_requesting[dbg_li] = (lsu_state[dbg_li] == 2'b01);
        end
    endgenerate

    // Per-thread enables. `i < thread_count` disables slots beyond the block's
    // alive thread count; `active_mask[i]` additionally disables threads that
    // are currently masked off by divergence (sitting on the reconvergence stack
    // or already RETed). thread_active gates the per-thread submodule enables
    // below so a deferred thread's pc / register / lsu state is held intact.
    genvar k;
    generate
        for (k = 0; k < THREADS_PER_BLOCK; k = k + 1) begin : alive_gen
            assign alive_mask[k]    = (k < thread_count);
            assign thread_active[k] = alive_mask[k] && active_mask[k];
        end
    endgenerate

    // Dedicated ALU, LSU, registers, & PC unit for each thread this core has capacity for
    genvar i;
    generate
        for (i = 0; i < THREADS_PER_BLOCK; i = i + 1) begin : threads
            // ALU
            alu alu_instance (
                .clk(clk),
                .reset(reset),
                .enable(thread_active[i]),
                .core_state(core_state),
                .decoded_alu_arithmetic_mux(decoded_alu_arithmetic_mux),
                .decoded_alu_output_mux(decoded_alu_output_mux),
                .rs(rs[i]),
                .rt(rt[i]),
                .alu_out(alu_out[i])
            );

            // LSU
            lsu lsu_instance (
                .clk(clk),
                .reset(reset),
                .enable(thread_active[i]),
                .core_state(core_state),
                .decoded_mem_read_enable(decoded_mem_read_enable),
                .decoded_mem_write_enable(decoded_mem_write_enable),
                .mem_read_valid(data_mem_read_valid[i]),
                .mem_read_address(data_mem_read_address[i]),
                .mem_read_ready(data_mem_read_ready[i]),
                .mem_read_data(data_mem_read_data[i]),
                .mem_write_valid(data_mem_write_valid[i]),
                .mem_write_address(data_mem_write_address[i]),
                .mem_write_data(data_mem_write_data[i]),
                .mem_write_ready(data_mem_write_ready[i]),
                .rs(rs[i]),
                .rt(rt[i]),
                .lsu_state(lsu_state[i]),
                .lsu_out(lsu_out[i])
            );

            // Register File
            registers #(
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                .THREAD_ID(i),
                .DATA_BITS(DATA_MEM_DATA_BITS)
            ) register_instance (
                .clk(clk),
                .reset(reset),
                .enable(thread_active[i]),
                .block_id(block_id),
                .core_state(core_state),
                .decoded_reg_write_enable(decoded_reg_write_enable),
                .decoded_reg_input_mux(decoded_reg_input_mux),
                .decoded_rd_address(decoded_rd_address),
                .decoded_rs_address(decoded_rs_address),
                .decoded_rt_address(decoded_rt_address),
                .decoded_immediate(decoded_immediate),
                .alu_out(alu_out[i]),
                .lsu_out(lsu_out[i]),
                .rs(rs[i]),
                .rt(rt[i])
            );

            // Program Counter
            pc #(
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS)
            ) pc_instance (
                .clk(clk),
                .reset(reset),
                .enable(thread_active[i]),
                .core_state(core_state),
                .decoded_nzp(decoded_nzp),
                .decoded_immediate(decoded_immediate),
                .decoded_nzp_write_enable(decoded_nzp_write_enable),
                .decoded_pc_mux(decoded_pc_mux),
                .alu_out(alu_out[i]),
                .current_pc(current_pc),
                .next_pc(next_pc[i])
            );
        end
    endgenerate
endmodule
