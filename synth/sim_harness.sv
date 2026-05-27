`default_nettype none
`timescale 1ns/1ns

// SIM_HARNESS
// > Wraps gpu + mem_bridge instances + sim_program_rom + sim_data_ram into a
//   single top-level module for the mem_bridge isolation test.
// > Backdoor (init_*) lets cocotb load program/data memories before the kernel
//   starts. Tied off and never touched at runtime.
// > One mem_bridge per channel: 1 program + DATA_MEM_NUM_CHANNELS data.
// > NOT for FPGA synthesis. The synth top (synth/de1_soc.sv) instantiates a
//   different RAM topology suited to Cyclone V's BRAM constraints.
module sim_harness #(
    parameter DATA_MEM_ADDR_BITS = 8,
    parameter DATA_MEM_DATA_BITS = 8,
    parameter DATA_MEM_NUM_CHANNELS = 4,
    parameter PROGRAM_MEM_ADDR_BITS = 8,
    parameter PROGRAM_MEM_DATA_BITS = 16,
    parameter PROGRAM_MEM_NUM_CHANNELS = 1,
    parameter NUM_CORES = 2,
    parameter THREADS_PER_BLOCK = 4
) (
    input wire clk,
    input wire reset,

    input wire start,
    output wire done,

    input wire device_control_write_enable,
    input wire [7:0] device_control_data,

    // Backdoor for pre-start memory load (test-only)
    input wire init_we_program,
    input wire [PROGRAM_MEM_ADDR_BITS-1:0] init_addr_program,
    input wire [PROGRAM_MEM_DATA_BITS-1:0] init_data_program,
    input wire init_we_data,
    input wire [DATA_MEM_ADDR_BITS-1:0] init_addr_data,
    input wire [DATA_MEM_DATA_BITS-1:0] init_data_data
);
    // GPU <-> bridge wires
    wire [PROGRAM_MEM_NUM_CHANNELS-1:0] prog_mem_read_valid;
    wire [PROGRAM_MEM_ADDR_BITS-1:0] prog_mem_read_address [PROGRAM_MEM_NUM_CHANNELS-1:0];
    wire [PROGRAM_MEM_NUM_CHANNELS-1:0] prog_mem_read_ready;
    wire [PROGRAM_MEM_DATA_BITS-1:0] prog_mem_read_data [PROGRAM_MEM_NUM_CHANNELS-1:0];

    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready;
    wire [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid;
    wire [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready;

    localparam DBG_STACK_W = $clog2(THREADS_PER_BLOCK + 1);
    wire [PROGRAM_MEM_ADDR_BITS-1:0] dbg_current_pc_nc;
    wire [THREADS_PER_BLOCK-1:0] dbg_active_mask_nc;
    wire [THREADS_PER_BLOCK-1:0] dbg_done_mask_nc;
    wire [DBG_STACK_W-1:0] dbg_stack_ptr_nc;
    wire [2:0] dbg_core0_state_nc;
    wire [2:0] dbg_core0_fetcher_state_nc;
    wire [THREADS_PER_BLOCK-1:0] dbg_core0_lsu_waiting_nc;
    wire [THREADS_PER_BLOCK-1:0] dbg_core0_lsu_requesting_nc;
    wire dbg_core0_any_lsu_waiting_nc;
    wire fb_write_valid_nc;
    wire fb_is_line_nc;
    wire [7:0] fb_x0_nc;
    wire [7:0] fb_y0_nc;
    wire [7:0] fb_x_nc;
    wire [7:0] fb_y_nc;
    wire [7:0] fb_data_nc;
    wire fb_color_nc;

    gpu #(
        .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
        .DATA_MEM_NUM_CHANNELS(DATA_MEM_NUM_CHANNELS),
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .PROGRAM_MEM_NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) gpu_instance (
        .clk(clk),
        .reset(reset),
        .start(start),
        .done(done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        .program_mem_read_valid(prog_mem_read_valid),
        .program_mem_read_address(prog_mem_read_address),
        .program_mem_read_ready(prog_mem_read_ready),
        .program_mem_read_data(prog_mem_read_data),
        .data_mem_read_valid(data_mem_read_valid),
        .data_mem_read_address(data_mem_read_address),
        .data_mem_read_ready(data_mem_read_ready),
        .data_mem_read_data(data_mem_read_data),
        .data_mem_write_valid(data_mem_write_valid),
        .data_mem_write_address(data_mem_write_address),
        .data_mem_write_data(data_mem_write_data),
        .data_mem_write_ready(data_mem_write_ready),

        .fb_write_valid(fb_write_valid_nc),
        .fb_is_line(fb_is_line_nc),
        .fb_x0(fb_x0_nc),
        .fb_y0(fb_y0_nc),
        .fb_x(fb_x_nc),
        .fb_y(fb_y_nc),
        .fb_data(fb_data_nc),
        .fb_color(fb_color_nc),
        .fb_write_ready(1'b1),

        .dbg_current_pc(dbg_current_pc_nc),
        .dbg_active_mask(dbg_active_mask_nc),
        .dbg_done_mask(dbg_done_mask_nc),
        .dbg_stack_ptr(dbg_stack_ptr_nc),

        .dbg_core0_state(dbg_core0_state_nc),
        .dbg_core0_fetcher_state(dbg_core0_fetcher_state_nc),
        .dbg_core0_lsu_waiting(dbg_core0_lsu_waiting_nc),
        .dbg_core0_lsu_requesting(dbg_core0_lsu_requesting_nc),
        .dbg_core0_any_lsu_waiting(dbg_core0_any_lsu_waiting_nc)
    );

    // Program memory: bridges + ROM
    wire [PROGRAM_MEM_ADDR_BITS-1:0] prog_ram_addr [PROGRAM_MEM_NUM_CHANNELS-1:0];
    wire [PROGRAM_MEM_DATA_BITS-1:0] prog_ram_dout [PROGRAM_MEM_NUM_CHANNELS-1:0];

    genvar pi;
    generate
        for (pi = 0; pi < PROGRAM_MEM_NUM_CHANNELS; pi = pi + 1) begin : prog_bridges
            wire prog_ram_we_unused;
            wire [PROGRAM_MEM_DATA_BITS-1:0] prog_ram_din_unused;
            wire prog_write_ready_unused;
            mem_bridge #(
                .ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
                .DATA_BITS(PROGRAM_MEM_DATA_BITS),
                .WRITE_ENABLE(0)
            ) program_bridge (
                .clk(clk),
                .reset(reset),
                .mem_read_valid(prog_mem_read_valid[pi]),
                .mem_read_address(prog_mem_read_address[pi]),
                .mem_read_ready(prog_mem_read_ready[pi]),
                .mem_read_data(prog_mem_read_data[pi]),
                .mem_write_valid(1'b0),
                .mem_write_address({PROGRAM_MEM_ADDR_BITS{1'b0}}),
                .mem_write_data({PROGRAM_MEM_DATA_BITS{1'b0}}),
                .mem_write_ready(prog_write_ready_unused),
                .ram_addr(prog_ram_addr[pi]),
                .ram_we(prog_ram_we_unused),
                .ram_din(prog_ram_din_unused),
                .ram_dout(prog_ram_dout[pi])
            );
        end
    endgenerate

    sim_program_rom #(
        .ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS)
    ) program_rom (
        .clk(clk),
        .init_we(init_we_program),
        .init_addr(init_addr_program),
        .init_din(init_data_program),
        .addr(prog_ram_addr),
        .dout(prog_ram_dout)
    );

    // Data memory: 4 bridges + shared multi-port RAM
    wire [DATA_MEM_ADDR_BITS-1:0] data_ram_addr [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_NUM_CHANNELS-1:0] data_ram_we;
    wire [DATA_MEM_DATA_BITS-1:0] data_ram_din [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_DATA_BITS-1:0] data_ram_dout [DATA_MEM_NUM_CHANNELS-1:0];

    genvar di;
    generate
        for (di = 0; di < DATA_MEM_NUM_CHANNELS; di = di + 1) begin : data_bridges
            mem_bridge #(
                .ADDR_BITS(DATA_MEM_ADDR_BITS),
                .DATA_BITS(DATA_MEM_DATA_BITS),
                .WRITE_ENABLE(1)
            ) data_bridge (
                .clk(clk),
                .reset(reset),
                .mem_read_valid(data_mem_read_valid[di]),
                .mem_read_address(data_mem_read_address[di]),
                .mem_read_ready(data_mem_read_ready[di]),
                .mem_read_data(data_mem_read_data[di]),
                .mem_write_valid(data_mem_write_valid[di]),
                .mem_write_address(data_mem_write_address[di]),
                .mem_write_data(data_mem_write_data[di]),
                .mem_write_ready(data_mem_write_ready[di]),
                .ram_addr(data_ram_addr[di]),
                .ram_we(data_ram_we[di]),
                .ram_din(data_ram_din[di]),
                .ram_dout(data_ram_dout[di])
            );
        end
    endgenerate

    sim_data_ram #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_BITS(DATA_MEM_DATA_BITS),
        .NUM_CHANNELS(DATA_MEM_NUM_CHANNELS)
    ) data_ram (
        .clk(clk),
        .init_we(init_we_data),
        .init_addr(init_addr_data),
        .init_din(init_data_data),
        .addr(data_ram_addr),
        .we(data_ram_we),
        .din(data_ram_din),
        .dout(data_ram_dout)
    );
endmodule
