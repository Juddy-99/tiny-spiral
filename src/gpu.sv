`default_nettype none
`timescale 1ns/1ns

// GPU
// > Built to use an external async memory with multi-channel read/write
// > Assumes that the program is loaded into program memory, data into data memory, and threads into
//   the device control register before the start signal is triggered
// > Has memory controllers to interface between external memory and its multiple cores
// > Configurable number of cores and thread capacity per core
module gpu #(
    parameter DATA_MEM_ADDR_BITS = 8,        // Number of bits in data memory address (256 rows)
    parameter DATA_MEM_DATA_BITS = 8,        // Number of bits in data memory value (8 bit data)
    parameter DATA_MEM_NUM_CHANNELS = 4,     // Number of concurrent channels for sending requests to data memory
    parameter PROGRAM_MEM_ADDR_BITS = 8,     // Number of bits in program memory address (256 rows)
    parameter PROGRAM_MEM_DATA_BITS = 16,    // Number of bits in program memory value (16 bit instruction)
    parameter PROGRAM_MEM_NUM_CHANNELS = 1,  // Number of concurrent channels for sending requests to program memory
    parameter NUM_CORES = 2,                 // Number of cores to include in this GPU
    parameter THREADS_PER_BLOCK = 4,         // Number of threads to handle per block (determines the compute resources of each core)
    parameter DBG_STACK_W = $clog2(THREADS_PER_BLOCK + 1)
) (
    input wire clk,
    input wire reset,

    // Kernel Execution
    input wire start,
    output wire done,

    // Device Control Register
    input wire device_control_write_enable,
    input wire [7:0] device_control_data,

    // Program Memory
    output wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid,
    output wire [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS-1:0],
    input wire [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready,
    input wire [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data [PROGRAM_MEM_NUM_CHANNELS-1:0],

    // Data Memory
    output wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [DATA_MEM_NUM_CHANNELS-1:0],
    input wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready,
    input wire [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS-1:0],
    output wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid,
    output wire [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [DATA_MEM_NUM_CHANNELS-1:0],
    output wire [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS-1:0],
    input wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready,

    // Framebuffer Write Port (single 1-channel write-only interface). All
    // per-thread STRFB/LNE/TRE requests are serialized through a dedicated
    // controller and presented here. Coordinates are 8 bits today (reachable
    // window is 256x256 of the 640x480 VGA screen). fb_mode selects between
    // PIXEL (2'b00), LINE (2'b01), and TRI (2'b10).
    output wire fb_write_valid,
    output wire [1:0] fb_mode,
    output wire [7:0] fb_x0,
    output wire [7:0] fb_y0,
    output wire [7:0] fb_x1,
    output wire [7:0] fb_y1,
    output wire [7:0] fb_x,
    output wire [7:0] fb_y,
    output wire [7:0] fb_data,
    output wire fb_color,
    input wire fb_write_ready,

    output wire [PROGRAM_MEM_ADDR_BITS-1:0] dbg_current_pc,
    output wire [THREADS_PER_BLOCK-1:0] dbg_active_mask,
    output wire [THREADS_PER_BLOCK-1:0] dbg_done_mask,
    output wire [DBG_STACK_W-1:0] dbg_stack_ptr,

    // Core 0 only (block runs on core 0 in single-block bring-up)
    output wire [2:0] dbg_core0_state,
    output wire [2:0] dbg_core0_fetcher_state,
    output wire [THREADS_PER_BLOCK-1:0] dbg_core0_lsu_waiting,
    output wire [THREADS_PER_BLOCK-1:0] dbg_core0_lsu_requesting,
    output wire dbg_core0_any_lsu_waiting
);
    // Control
    wire [7:0] thread_count;

    wire [PROGRAM_MEM_ADDR_BITS-1:0] dbg_cur_pc_c [NUM_CORES-1:0];
    wire [THREADS_PER_BLOCK-1:0] dbg_am_c [NUM_CORES-1:0];
    wire [THREADS_PER_BLOCK-1:0] dbg_dm_c [NUM_CORES-1:0];
    wire [DBG_STACK_W-1:0] dbg_sp_c [NUM_CORES-1:0];
    wire [2:0] dbg_core_state_c [NUM_CORES-1:0];
    wire [2:0] dbg_fetcher_state_c [NUM_CORES-1:0];
    wire [THREADS_PER_BLOCK-1:0] dbg_lsu_waiting_c [NUM_CORES-1:0];
    wire [THREADS_PER_BLOCK-1:0] dbg_lsu_requesting_c [NUM_CORES-1:0];
    wire dbg_any_lsu_waiting_c [NUM_CORES-1:0];

    // Compute Core State
    reg [NUM_CORES-1:0] core_start;
    reg [NUM_CORES-1:0] core_reset;
    reg [NUM_CORES-1:0] core_done;
    reg [7:0] core_block_id [NUM_CORES-1:0];
    reg [$clog2(THREADS_PER_BLOCK):0] core_thread_count [NUM_CORES-1:0];

    // LSU <> Data Memory Controller Channels
    localparam NUM_LSUS = NUM_CORES * THREADS_PER_BLOCK;
    reg [NUM_LSUS-1:0] lsu_read_valid;
    reg [DATA_MEM_ADDR_BITS-1:0] lsu_read_address [NUM_LSUS-1:0];
    reg [NUM_LSUS-1:0] lsu_read_ready;
    reg [DATA_MEM_DATA_BITS-1:0] lsu_read_data [NUM_LSUS-1:0];
    reg [NUM_LSUS-1:0] lsu_write_valid;
    reg [DATA_MEM_ADDR_BITS-1:0] lsu_write_address [NUM_LSUS-1:0];
    reg [DATA_MEM_DATA_BITS-1:0] lsu_write_data [NUM_LSUS-1:0];
    reg [NUM_LSUS-1:0] lsu_write_ready;

    // Fetcher <> Program Memory Controller Channels
    localparam NUM_FETCHERS = NUM_CORES;
    reg [NUM_FETCHERS-1:0] fetcher_read_valid;
    reg [PROGRAM_MEM_ADDR_BITS-1:0] fetcher_read_address [NUM_FETCHERS-1:0];
    reg [NUM_FETCHERS-1:0] fetcher_read_ready;
    reg [PROGRAM_MEM_DATA_BITS-1:0] fetcher_read_data [NUM_FETCHERS-1:0];

    // LSU <> Framebuffer Controller Channels
    // Address = {fb_y, fb_x, fb_y1, fb_x1, fb_y0, fb_x0} (48b), Data =
    // {fb_mode[1:0], fb_color, fb_data} (11b). One controller channel
    // serializes all NUM_LSUS write requests. Reads are tied off so the
    // controller only ever takes the write path.
    localparam FB_ADDR_BITS = 48;
    localparam FB_DATA_BITS = 11;
    reg [NUM_LSUS-1:0] lsu_fb_write_valid;
    reg [FB_ADDR_BITS-1:0] lsu_fb_write_address [NUM_LSUS-1:0];
    reg [FB_DATA_BITS-1:0] lsu_fb_write_data [NUM_LSUS-1:0];
    wire [NUM_LSUS-1:0] lsu_fb_write_ready;
    wire [NUM_LSUS-1:0] lsu_fb_read_valid_tie;
    wire [FB_ADDR_BITS-1:0] lsu_fb_read_address_tie [NUM_LSUS-1:0];
    wire [NUM_LSUS-1:0] fb_read_ready_unused;
    wire [FB_DATA_BITS-1:0] fb_read_data_unused [NUM_LSUS-1:0];
    wire fb_mem_read_valid_unused;
    wire [FB_ADDR_BITS-1:0] fb_mem_read_address_unused;
    wire fb_mem_read_ready_tie;
    wire [FB_DATA_BITS-1:0] fb_mem_read_data_tie;
    wire fb_mem_write_valid_w;
    wire [FB_ADDR_BITS-1:0] fb_mem_write_address_w;
    wire [FB_DATA_BITS-1:0] fb_mem_write_data_w;

    assign lsu_fb_read_valid_tie = {NUM_LSUS{1'b0}};
    assign fb_mem_read_ready_tie = 1'b0;
    assign fb_mem_read_data_tie  = {FB_DATA_BITS{1'b0}};

    genvar fbi;
    generate
        for (fbi = 0; fbi < NUM_LSUS; fbi = fbi + 1) begin : fb_read_tie
            assign lsu_fb_read_address_tie[fbi] = {FB_ADDR_BITS{1'b0}};
        end
    endgenerate
    
    // Device Control Register
    dcr dcr_instance (
        .clk(clk),
        .reset(reset),

        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        .thread_count(thread_count)
    );

    // Data Memory Controller
    controller #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_BITS(DATA_MEM_DATA_BITS),
        .NUM_CONSUMERS(NUM_LSUS),
        .NUM_CHANNELS(DATA_MEM_NUM_CHANNELS)
    ) data_memory_controller (
        .clk(clk),
        .reset(reset),

        .consumer_read_valid(lsu_read_valid),
        .consumer_read_address(lsu_read_address),
        .consumer_read_ready(lsu_read_ready),
        .consumer_read_data(lsu_read_data),
        .consumer_write_valid(lsu_write_valid),
        .consumer_write_address(lsu_write_address),
        .consumer_write_data(lsu_write_data),
        .consumer_write_ready(lsu_write_ready),

        .mem_read_valid(data_mem_read_valid),
        .mem_read_address(data_mem_read_address),
        .mem_read_ready(data_mem_read_ready),
        .mem_read_data(data_mem_read_data),
        .mem_write_valid(data_mem_write_valid),
        .mem_write_address(data_mem_write_address),
        .mem_write_data(data_mem_write_data),
        .mem_write_ready(data_mem_write_ready)
    );

    // Program Memory Controller
    controller #(
        .ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .NUM_CONSUMERS(NUM_FETCHERS),
        .NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .WRITE_ENABLE(0)
    ) program_memory_controller (
        .clk(clk),
        .reset(reset),

        .consumer_read_valid(fetcher_read_valid),
        .consumer_read_address(fetcher_read_address),
        .consumer_read_ready(fetcher_read_ready),
        .consumer_read_data(fetcher_read_data),

        .mem_read_valid(program_mem_read_valid),
        .mem_read_address(program_mem_read_address),
        .mem_read_ready(program_mem_read_ready),
        .mem_read_data(program_mem_read_data)
    );

    // Framebuffer Controller. Serializes per-LSU STRFB requests onto a single
    // 1-channel write port exposed at the GPU top. Reads are tied off so the
    // controller only ever exercises the write half of its state machine.
    wire [0:0] fb_mem_write_valid_ch;
    wire [FB_ADDR_BITS-1:0] fb_mem_write_address_ch [0:0];
    wire [FB_DATA_BITS-1:0] fb_mem_write_data_ch [0:0];
    wire [0:0] fb_mem_write_ready_ch;
    wire [0:0] fb_mem_read_valid_ch;
    wire [FB_ADDR_BITS-1:0] fb_mem_read_address_ch [0:0];
    wire [0:0] fb_mem_read_ready_ch;
    wire [FB_DATA_BITS-1:0] fb_mem_read_data_ch [0:0];

    assign fb_mem_read_ready_ch[0] = fb_mem_read_ready_tie;
    assign fb_mem_read_data_ch[0]  = fb_mem_read_data_tie;
    assign fb_mem_read_valid_unused   = fb_mem_read_valid_ch[0];
    assign fb_mem_read_address_unused = fb_mem_read_address_ch[0];
    assign fb_mem_write_valid_w   = fb_mem_write_valid_ch[0];
    assign fb_mem_write_address_w = fb_mem_write_address_ch[0];
    assign fb_mem_write_data_w    = fb_mem_write_data_ch[0];
    assign fb_mem_write_ready_ch[0] = fb_write_ready;

    controller #(
        .ADDR_BITS(FB_ADDR_BITS),
        .DATA_BITS(FB_DATA_BITS),
        .NUM_CONSUMERS(NUM_LSUS),
        .NUM_CHANNELS(1),
        .WRITE_ENABLE(1)
    ) fb_controller (
        .clk(clk),
        .reset(reset),

        .consumer_read_valid(lsu_fb_read_valid_tie),
        .consumer_read_address(lsu_fb_read_address_tie),
        .consumer_read_ready(fb_read_ready_unused),
        .consumer_read_data(fb_read_data_unused),
        .consumer_write_valid(lsu_fb_write_valid),
        .consumer_write_address(lsu_fb_write_address),
        .consumer_write_data(lsu_fb_write_data),
        .consumer_write_ready(lsu_fb_write_ready),

        .mem_read_valid(fb_mem_read_valid_ch),
        .mem_read_address(fb_mem_read_address_ch),
        .mem_read_ready(fb_mem_read_ready_ch),
        .mem_read_data(fb_mem_read_data_ch),
        .mem_write_valid(fb_mem_write_valid_ch),
        .mem_write_address(fb_mem_write_address_ch),
        .mem_write_data(fb_mem_write_data_ch),
        .mem_write_ready(fb_mem_write_ready_ch)
    );

    // Unpack the controller's single-channel output back into the top-level
    // framebuffer signals.
    assign fb_write_valid = fb_mem_write_valid_w;
    assign fb_x0          = fb_mem_write_address_w[7:0];
    assign fb_y0          = fb_mem_write_address_w[15:8];
    assign fb_x1          = fb_mem_write_address_w[23:16];
    assign fb_y1          = fb_mem_write_address_w[31:24];
    assign fb_x           = fb_mem_write_address_w[39:32];
    assign fb_y           = fb_mem_write_address_w[47:40];
    assign fb_data        = fb_mem_write_data_w[7:0];
    assign fb_color       = fb_mem_write_data_w[8];
    assign fb_mode        = fb_mem_write_data_w[10:9];

    // Dispatcher
    dispatch #(
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) dispatch_instance (
        .clk(clk),
        .reset(reset),
        .start(start),
        .thread_count(thread_count),
        .core_done(core_done),
        .core_start(core_start),
        .core_reset(core_reset),
        .core_block_id(core_block_id),
        .core_thread_count(core_thread_count),
        .done(done)
    );

    // Compute Cores
    genvar i;
    generate
        for (i = 0; i < NUM_CORES; i = i + 1) begin : cores
            // EDA: We create separate signals here to pass to cores because of a requirement
            // by the OpenLane EDA flow (uses Verilog 2005) that prevents slicing the top-level signals
            reg [THREADS_PER_BLOCK-1:0] core_lsu_read_valid;
            reg [DATA_MEM_ADDR_BITS-1:0] core_lsu_read_address [THREADS_PER_BLOCK-1:0];
            reg [THREADS_PER_BLOCK-1:0] core_lsu_read_ready;
            reg [DATA_MEM_DATA_BITS-1:0] core_lsu_read_data [THREADS_PER_BLOCK-1:0];
            reg [THREADS_PER_BLOCK-1:0] core_lsu_write_valid;
            reg [DATA_MEM_ADDR_BITS-1:0] core_lsu_write_address [THREADS_PER_BLOCK-1:0];
            reg [DATA_MEM_DATA_BITS-1:0] core_lsu_write_data [THREADS_PER_BLOCK-1:0];
            // Combinational (no extra gpu_clk FF): write handshake must reach the LSU in the
            // same cycle the controller asserts consumer_write_ready. An extra register here
            // matched cocotb timing in Icarus but can miss the ready window on FPGA (PC stuck on STR).
            wire [THREADS_PER_BLOCK-1:0] core_lsu_write_ready;

            // Per-core framebuffer write bus. Mirrors the data path: registered
            // valid/address/data on the way out, combinational ready on the way
            // back so the LSU sees the controller's write_ready in the same cycle.
            wire [THREADS_PER_BLOCK-1:0] core_fb_write_valid;
            wire [1:0] core_fb_mode [THREADS_PER_BLOCK-1:0];
            wire [7:0] core_fb_x0 [THREADS_PER_BLOCK-1:0];
            wire [7:0] core_fb_y0 [THREADS_PER_BLOCK-1:0];
            wire [7:0] core_fb_x1 [THREADS_PER_BLOCK-1:0];
            wire [7:0] core_fb_y1 [THREADS_PER_BLOCK-1:0];
            wire [7:0] core_fb_x [THREADS_PER_BLOCK-1:0];
            wire [7:0] core_fb_y [THREADS_PER_BLOCK-1:0];
            wire [7:0] core_fb_data [THREADS_PER_BLOCK-1:0];
            wire [THREADS_PER_BLOCK-1:0] core_fb_color;
            wire [THREADS_PER_BLOCK-1:0] core_fb_write_ready;

            // Pass through signals between LSUs and data memory controller
            genvar j;
            for (j = 0; j < THREADS_PER_BLOCK; j = j + 1) begin : threads
                localparam lsu_index = i * THREADS_PER_BLOCK + j;
                assign core_lsu_write_ready[j] = lsu_write_ready[lsu_index];
                assign core_fb_write_ready[j]  = lsu_fb_write_ready[lsu_index];

                always @(posedge clk) begin 
                    lsu_read_valid[lsu_index] <= core_lsu_read_valid[j];
                    lsu_read_address[lsu_index] <= core_lsu_read_address[j];

                    lsu_write_valid[lsu_index] <= core_lsu_write_valid[j];
                    lsu_write_address[lsu_index] <= core_lsu_write_address[j];
                    lsu_write_data[lsu_index] <= core_lsu_write_data[j];

                    lsu_fb_write_valid[lsu_index]   <= core_fb_write_valid[j];
                    lsu_fb_write_address[lsu_index] <= {
                        core_fb_y[j], core_fb_x[j],
                        core_fb_y1[j], core_fb_x1[j],
                        core_fb_y0[j], core_fb_x0[j]
                    };
                    lsu_fb_write_data[lsu_index]    <= {
                        core_fb_mode[j], core_fb_color[j], core_fb_data[j]
                    };

                    core_lsu_read_ready[j] <= lsu_read_ready[lsu_index];
                    core_lsu_read_data[j] <= lsu_read_data[lsu_index];
                end
            end

            // Compute Core
            core #(
                .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
                .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
                .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
                .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
                .THREADS_PER_BLOCK(THREADS_PER_BLOCK),
                .STACK_DBG_W(DBG_STACK_W)
            ) core_instance (
                .clk(clk),
                .reset(core_reset[i]),
                .start(core_start[i]),
                .done(core_done[i]),
                .block_id(core_block_id[i]),
                .thread_count(core_thread_count[i]),
                
                .program_mem_read_valid(fetcher_read_valid[i]),
                .program_mem_read_address(fetcher_read_address[i]),
                .program_mem_read_ready(fetcher_read_ready[i]),
                .program_mem_read_data(fetcher_read_data[i]),

                .data_mem_read_valid(core_lsu_read_valid),
                .data_mem_read_address(core_lsu_read_address),
                .data_mem_read_ready(core_lsu_read_ready),
                .data_mem_read_data(core_lsu_read_data),
                .data_mem_write_valid(core_lsu_write_valid),
                .data_mem_write_address(core_lsu_write_address),
                .data_mem_write_data(core_lsu_write_data),
                .data_mem_write_ready(core_lsu_write_ready),

                .fb_write_valid(core_fb_write_valid),
                .fb_mode(core_fb_mode),
                .fb_x0(core_fb_x0),
                .fb_y0(core_fb_y0),
                .fb_x1(core_fb_x1),
                .fb_y1(core_fb_y1),
                .fb_x(core_fb_x),
                .fb_y(core_fb_y),
                .fb_data(core_fb_data),
                .fb_color(core_fb_color),
                .fb_write_ready(core_fb_write_ready),

                .dbg_current_pc(dbg_cur_pc_c[i]),
                .dbg_active_mask(dbg_am_c[i]),
                .dbg_done_mask(dbg_dm_c[i]),
                .dbg_stack_ptr(dbg_sp_c[i]),

                .dbg_core_state(dbg_core_state_c[i]),
                .dbg_fetcher_state(dbg_fetcher_state_c[i]),
                .dbg_lsu_waiting(dbg_lsu_waiting_c[i]),
                .dbg_lsu_requesting(dbg_lsu_requesting_c[i]),
                .dbg_any_lsu_waiting(dbg_any_lsu_waiting_c[i])
            );
        end
    endgenerate

    assign dbg_current_pc = dbg_cur_pc_c[0];
    assign dbg_active_mask = dbg_am_c[0];
    assign dbg_done_mask = dbg_dm_c[0];
    assign dbg_stack_ptr = dbg_sp_c[0];
    assign dbg_core0_state = dbg_core_state_c[0];
    assign dbg_core0_fetcher_state = dbg_fetcher_state_c[0];
    assign dbg_core0_lsu_waiting = dbg_lsu_waiting_c[0];
    assign dbg_core0_lsu_requesting = dbg_lsu_requesting_c[0];
    assign dbg_core0_any_lsu_waiting = dbg_any_lsu_waiting_c[0];
endmodule
