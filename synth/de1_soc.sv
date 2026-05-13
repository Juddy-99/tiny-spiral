`default_nettype none
`timescale 1ns/1ns

// DE1_SOC
// > Top-level FPGA module for LabsLand DE1-SoC bring-up.
// > Port shape matches lab2/DE1_SoC.sv exactly so LabsLand auto-maps pins
//   based on top-level port names (no .qsf / PCF required).
// > Wires up:
//     - clock_step (KEY[0] single-step OR SW[9] auto-tick) -> gpu_clk
//     - gpu instance with NUM_CORES=1, THREADS_PER_BLOCK=4
//     - 1 program bridge + program_rom (from auto-generated kernel_memories.sv)
//     - 4 data bridges + data_ram
//     - HEX/LED panel reflecting GPU divergence/PC state
// > thread_count and start are driven from a tiny boot FSM so the kernel runs
//   automatically out of reset without needing JTAG / serial intervention --
//   user just presses KEY[3] to reset and then KEY[0] (or flips SW[9]) to step.
//
// HEX / LED layout (per the SIMT-IPDOM bring-up plan):
//   HEX5..HEX4 : current_pc[7:0]   (high nibble first)
//   HEX3       : active_mask[3:0]
//   HEX2       : {1'b0, stack_ptr[2:0]}
//   HEX1..HEX0 : data_ram[SW[7:4]]  (8-bit hex readback for arbitrary scrubbing)
//   LEDR (SW[8]=0, normal):
//     [9] done  [8] stack_ptr!=0  [7:4] done_mask  [3:0] active_mask
//   LEDR (SW[8]=1, debug — see SW[3:2] pages in module comment below)
//
// Switches / buttons:
//   KEY[3]  : reset (active low)
//   KEY[0]  : single-step gpu_clk (active low; debounced via clock_step)
//   SW[9]   : 0 = single-step mode, 1 = auto-tick at SLOW_CLK_DIV cadence
//   SW[7:4] : data_ram readback address for HEX1..HEX0
//   SW[8]   : 0 = normal LEDR (done / masks). 1 = hardware debug LEDR pages (below).
//   SW[3:2] : debug page when SW[8]=1:
//               0 = data write GPU↔bridge: [3:0]=mem wr_valid (per RAM port /
//                   controller channel — 4 ports for 8 LSUs), [7:4]=per-ch stuck (v&~r),
//                   [8]=|stuck, [9]=done
//               1 = data RAM + read: [3:0]=data_ram_we, [7:4]=rd_valid,
//                   [8]=stuck read, [9]=done
//               2 = core0 FSM: [2:0]=core_state (sched: 0=IDLE 1=FETCH 2=DECODE
//                   3=REQUEST 4=WAIT 5=EXECUTE 6=UPDATE 7=DONE), [5:3]=fetcher
//                   (0=IDLE 1=FETCHING 2=FETCHED), [6]=in_WAIT, [7]=stuck data wr,
//                   [8]=prog fetch stuck, [9]=done
//               3 = core0 LSU: [3:0]=waiting, [7:4]=requesting, [8]=|waiting, [9]=done
//   Signal Tap: probe `de1_hardware_dbg_keep`, `gpu_instance.dbg_core0_*`, and
//   `data_mem_*` / `data_ram_we` in de1_soc (names survive in Quartus STP).
module de1_soc #(
    parameter SLOW_CLK_DIV = 32'd10_000_000,    // ~5 Hz at 50 MHz
    parameter THREADS = 8'd4
) (
    input  wire        CLOCK_50,
    input  wire [9:0]  SW,
    input  wire [3:0]  KEY,
    output wire [6:0]  HEX0,
    output wire [6:0]  HEX1,
    output wire [6:0]  HEX2,
    output wire [6:0]  HEX3,
    output wire [6:0]  HEX4,
    output wire [6:0]  HEX5,
    output wire [9:0]  LEDR
);
    // Active-low buttons -> active-high internal signals.
    wire reset_btn = ~KEY[3];
    wire step_btn  = ~KEY[0];

    // ---- Slow gpu_clk generation ----
    wire gpu_clk;
    clock_step #(.AUTO_DIV(SLOW_CLK_DIV)) clock_step_instance (
        .clk_in(CLOCK_50),
        .reset(reset_btn),
        .mode_auto(SW[9]),
        .step_btn(step_btn),
        .clk_out(gpu_clk)
    );

    // ---- Boot FSM: drive thread_count and start out of reset ----
    // Boot_state advances one gpu_clk cycle at a time after reset_btn drops:
    //   state 0 (also = "GPU reset") -> 1 (write thread_count) -> 2 (start) -> stay
    // We hold GPU.reset HIGH while boot_state==0 so the GPU's synchronous reset
    // sees a posedge gpu_clk -- without this, clock_step holds gpu_clk=0 during
    // reset_btn=1, and after release the GPU's regs would never be cleared.
    reg [1:0] boot_state;
    reg gpu_start;
    reg dcr_we;
    always @(posedge gpu_clk or posedge reset_btn) begin
        if (reset_btn) begin
            boot_state <= 2'd0;
            gpu_start  <= 1'b0;
            dcr_we     <= 1'b0;
        end else begin
            case (boot_state)
                2'd0: begin
                    // First gpu_clk after reset_btn drops. GPU still sees reset=1
                    // this edge (gpu_reset = boot_state==0). Schedule DCR write.
                    dcr_we     <= 1'b1;
                    boot_state <= 2'd1;
                end
                2'd1: begin
                    dcr_we     <= 1'b0;
                    gpu_start  <= 1'b1;
                    boot_state <= 2'd2;
                end
                default: begin
                    dcr_we    <= 1'b0;
                    gpu_start <= 1'b1;
                end
            endcase
        end
    end

    // GPU sees reset until boot_state has advanced past the first gpu_clk edge,
    // guaranteeing the synchronous reset latches inside src/scheduler.sv and
    // src/divergence.sv have at least one posedge gpu_clk to act on.
    wire gpu_reset = reset_btn || (boot_state == 2'd0);

    // ---- GPU instance and bridges ----
    // NUM_CORES = 2 (not 1) so NUM_LSUS = 8 matches the gpu top regression
    // configuration. Iverilog has trouble with $clog2(NUM_CONSUMERS) for
    // NUM_CONSUMERS=4 in some elaboration paths through controller.sv. With
    // 8 LSUs we use the same elaboration that the matadd/matmul tests use.
    // The kernel only dispatches one block of THREADS_PER_BLOCK threads, so
    // core 1 stays in IDLE for the entire run.
    localparam NUM_CORES = 2;
    localparam THREADS_PER_BLOCK = 4;
    localparam DATA_MEM_NUM_CHANNELS = 4;
    localparam PROGRAM_MEM_NUM_CHANNELS = 1;

    wire gpu_done;
    wire [7:0] cur_pc;
    wire [THREADS_PER_BLOCK-1:0] active_mask;
    wire [THREADS_PER_BLOCK-1:0] done_mask;
    localparam DBG_STACK_W = $clog2(THREADS_PER_BLOCK + 1);
    wire [DBG_STACK_W-1:0] stack_ptr;

    wire [2:0] dbg_core0_state;
    wire [2:0] dbg_core0_fetcher_state;
    wire [THREADS_PER_BLOCK-1:0] dbg_core0_lsu_waiting;
    wire [THREADS_PER_BLOCK-1:0] dbg_core0_lsu_requesting;

    wire [PROGRAM_MEM_NUM_CHANNELS-1:0] prog_mem_read_valid;
    wire [7:0] prog_mem_read_address [PROGRAM_MEM_NUM_CHANNELS-1:0];
    wire [PROGRAM_MEM_NUM_CHANNELS-1:0] prog_mem_read_ready;
    wire [15:0] prog_mem_read_data [PROGRAM_MEM_NUM_CHANNELS-1:0];

    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid;
    wire [7:0] data_mem_read_address [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready;
    wire [7:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid;
    wire [7:0] data_mem_write_address [DATA_MEM_NUM_CHANNELS-1:0];
    wire [7:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready;

    gpu #(
        .DATA_MEM_ADDR_BITS(8),
        .DATA_MEM_DATA_BITS(8),
        .DATA_MEM_NUM_CHANNELS(DATA_MEM_NUM_CHANNELS),
        .PROGRAM_MEM_ADDR_BITS(8),
        .PROGRAM_MEM_DATA_BITS(16),
        .PROGRAM_MEM_NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) gpu_instance (
        .clk(gpu_clk),
        .reset(gpu_reset),
        .start(gpu_start),
        .done(gpu_done),
        .device_control_write_enable(dcr_we),
        .device_control_data(THREADS),
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

        .dbg_current_pc(cur_pc),
        .dbg_active_mask(active_mask),
        .dbg_done_mask(done_mask),
        .dbg_stack_ptr(stack_ptr),

        .dbg_core0_state(dbg_core0_state),
        .dbg_core0_fetcher_state(dbg_core0_fetcher_state),
        .dbg_core0_lsu_waiting(dbg_core0_lsu_waiting),
        .dbg_core0_lsu_requesting(dbg_core0_lsu_requesting)
    );

    // ---- Program memory: bridge + ROM ----
    wire [7:0]  prog_ram_addr [PROGRAM_MEM_NUM_CHANNELS-1:0];
    wire [15:0] prog_ram_dout [PROGRAM_MEM_NUM_CHANNELS-1:0];

    genvar pi;
    generate
        for (pi = 0; pi < PROGRAM_MEM_NUM_CHANNELS; pi = pi + 1) begin : prog_bridges
            wire prog_ram_we_unused;
            wire [15:0] prog_ram_din_unused;
            wire prog_write_ready_unused;
            mem_bridge #(
                .ADDR_BITS(8),
                .DATA_BITS(16),
                .WRITE_ENABLE(0)
            ) program_bridge (
                .clk(gpu_clk),
                .reset(gpu_reset),
                .mem_read_valid(prog_mem_read_valid[pi]),
                .mem_read_address(prog_mem_read_address[pi]),
                .mem_read_ready(prog_mem_read_ready[pi]),
                .mem_read_data(prog_mem_read_data[pi]),
                .mem_write_valid(1'b0),
                .mem_write_address(8'b0),
                .mem_write_data(16'b0),
                .mem_write_ready(prog_write_ready_unused),
                .ram_addr(prog_ram_addr[pi]),
                .ram_we(prog_ram_we_unused),
                .ram_din(prog_ram_din_unused),
                .ram_dout(prog_ram_dout[pi])
            );
        end
    endgenerate

    program_rom #(
        .ADDR_BITS(8),
        .DATA_BITS(16),
        .NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS)
    ) program_rom_instance (
        .clk(gpu_clk),
        .addr(prog_ram_addr),
        .dout(prog_ram_dout)
    );

    // ---- Data memory: bridges + RAM ----
    wire [7:0] data_ram_addr [DATA_MEM_NUM_CHANNELS-1:0];
    wire [DATA_MEM_NUM_CHANNELS-1:0] data_ram_we;
    wire [7:0] data_ram_din [DATA_MEM_NUM_CHANNELS-1:0];
    wire [7:0] data_ram_dout [DATA_MEM_NUM_CHANNELS-1:0];

    genvar di;
    generate
        for (di = 0; di < DATA_MEM_NUM_CHANNELS; di = di + 1) begin : data_bridges
            mem_bridge #(
                .ADDR_BITS(8),
                .DATA_BITS(8),
                .WRITE_ENABLE(1)
            ) data_bridge (
                .clk(gpu_clk),
                .reset(gpu_reset),
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

    // HEX data readback: SW[7:4] selects a 16-byte region base (async dbg port on
    // data_ram — Quartus cannot hierarchically reference inferred mem[]).
    wire [7:0] readback_addr = {SW[7:4], 4'b0000};
    wire [7:0] readback_data;

    data_ram #(
        .ADDR_BITS(8),
        .DATA_BITS(8),
        .NUM_CHANNELS(DATA_MEM_NUM_CHANNELS)
    ) data_ram_instance (
        .clk(gpu_clk),
        .addr(data_ram_addr),
        .we(data_ram_we),
        .din(data_ram_din),
        .dout(data_ram_dout),
        .dbg_addr(readback_addr),
        .dbg_dout(readback_data)
    );

    // ---- HEX / LED panel ----
    // Divergence debug taps are exported as explicit gpu ports (Quartus cannot
    // reliably elaborate deep hierarchical refs into generated cores).

    seg7 hex5_drv (.nibble(cur_pc[7:4]),     .segs(HEX5));
    seg7 hex4_drv (.nibble(cur_pc[3:0]),     .segs(HEX4));
    seg7 hex3_drv (.nibble(active_mask),     .segs(HEX3));
    seg7 hex2_drv (.nibble({1'b0, stack_ptr}), .segs(HEX2));
    seg7 hex1_drv (.nibble(readback_data[7:4]), .segs(HEX1));
    seg7 hex0_drv (.nibble(readback_data[3:0]), .segs(HEX0));

    // Packed bus for Quartus Signal Tap (add in STP by name: de1_hardware_dbg_keep)
    (* keep = 1 *) wire [31:0] de1_hardware_dbg_keep;
    assign de1_hardware_dbg_keep = {
        4'b0,
        prog_mem_read_valid[0],
        prog_mem_read_ready[0],
        data_ram_we,
        data_mem_read_valid,
        data_mem_read_ready,
        data_mem_write_valid,
        data_mem_write_ready,
        dbg_core0_state,
        dbg_core0_fetcher_state
    };

    localparam CORE_WAIT = 3'b100;

    wire [DATA_MEM_NUM_CHANNELS-1:0] ch_wr_stuck =
        data_mem_write_valid & ~data_mem_write_ready;
    wire stuck_data_write   = |ch_wr_stuck;
    wire stuck_data_read    = |(data_mem_read_valid & ~data_mem_read_ready);
    wire stuck_prog_read    = prog_mem_read_valid[0] & ~prog_mem_read_ready[0];
    wire in_scheduler_wait  = (dbg_core0_state == CORE_WAIT);
    wire any_lsu_wait       = |dbg_core0_lsu_waiting;

    wire [9:0] ledr_normal;
    wire [9:0] ledr_debug_p0;
    wire [9:0] ledr_debug_p1;
    wire [9:0] ledr_debug_p2;
    wire [9:0] ledr_debug_p3;
    wire [9:0] ledr_debug_sel;

    assign ledr_normal[9]   = gpu_done;
    assign ledr_normal[8]   = (stack_ptr != 3'b0);
    assign ledr_normal[7:4] = done_mask;
    assign ledr_normal[3:0] = active_mask;

    assign ledr_debug_p0[3:0] = data_mem_write_valid;
    assign ledr_debug_p0[7:4] = ch_wr_stuck;
    assign ledr_debug_p0[8]   = stuck_data_write;
    assign ledr_debug_p0[9]   = gpu_done;

    assign ledr_debug_p1[3:0] = data_ram_we;
    assign ledr_debug_p1[7:4] = data_mem_read_valid;
    assign ledr_debug_p1[8]   = stuck_data_read;
    assign ledr_debug_p1[9]   = gpu_done;

    assign ledr_debug_p2[2:0] = dbg_core0_state;
    assign ledr_debug_p2[5:3] = dbg_core0_fetcher_state;
    assign ledr_debug_p2[6]   = in_scheduler_wait;
    assign ledr_debug_p2[7]   = stuck_data_write;
    assign ledr_debug_p2[8]   = stuck_prog_read;
    assign ledr_debug_p2[9]   = gpu_done;

    assign ledr_debug_p3[3:0] = dbg_core0_lsu_waiting;
    assign ledr_debug_p3[7:4] = dbg_core0_lsu_requesting;
    assign ledr_debug_p3[8]   = any_lsu_wait;
    assign ledr_debug_p3[9]   = gpu_done;

    assign ledr_debug_sel = (SW[3:2] == 2'b00) ? ledr_debug_p0
        : (SW[3:2] == 2'b01) ? ledr_debug_p1
        : (SW[3:2] == 2'b10) ? ledr_debug_p2
        : ledr_debug_p3;

    assign LEDR = SW[8] ? ledr_debug_sel : ledr_normal;
endmodule
