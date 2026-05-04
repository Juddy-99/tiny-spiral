`default_nettype none
`timescale 1ns/1ns

// MEM_BRIDGE
// > One-channel adapter between the GPU memory controller's valid/ready handshake
//   (see src/controller.sv) and an inferred RAM block (async read, sync write).
// > Cycle-count parity with the Python Memory model (test/helpers/memory.py)
//   requires the controller to spend exactly TWO cycles in READ_WAITING /
//   WRITE_WAITING -- one to assert valid, one to see ready. Python achieves
//   that by reading the new valid mid-cycle and asserting ready before the
//   next edge. We mirror that timing by registering ready (and the captured
//   data for reads), so:
//      cycle K   : controller transitions IDLE -> WAITING, drives valid=1.
//      cycle K+1 : bridge samples valid=1, registers ready_q<=1 and
//                  data_q<=ram_dout (which equals mem[address] this cycle
//                  because the RAM is async-read).
//      cycle K+2 : controller samples ready=1, drops valid, transitions to
//                  RELAYING. mem_read_data is the registered data_q.
// > A bare combinational `assign ready = valid` was 1 cycle FASTER per
//   transaction (matadd ran in 159 vs 178 cycles), which broke the cycle-
//   parity contract with the Python model. The 1-cycle ready register matches
//   Python exactly, and both shapes are equally synthesizable.
//
// One bridge instance per controller channel:
//   - 1 for the program controller (WRITE_ENABLE=0).
//   - 1 per data channel for the data controller (WRITE_ENABLE=1).
module mem_bridge #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 16,
    parameter WRITE_ENABLE = 0
) (
    input wire clk,
    input wire reset,

    // GPU controller side
    input wire mem_read_valid,
    input wire [ADDR_BITS-1:0] mem_read_address,
    output wire mem_read_ready,
    output wire [DATA_BITS-1:0] mem_read_data,

    input wire mem_write_valid,
    input wire [ADDR_BITS-1:0] mem_write_address,
    input wire [DATA_BITS-1:0] mem_write_data,
    output wire mem_write_ready,

    // RAM port (asynchronous read, synchronous write)
    output wire [ADDR_BITS-1:0] ram_addr,
    output wire ram_we,
    output wire [DATA_BITS-1:0] ram_din,
    input wire [DATA_BITS-1:0] ram_dout
);
    // Writes take priority on the address bus. The controller protocol prevents
    // simultaneous read+write on the same channel (distinct WAITING states), so
    // this priority is belt-and-suspenders.
    wire writing = WRITE_ENABLE && mem_write_valid;

    assign ram_addr = writing ? mem_write_address : mem_read_address;
    assign ram_we   = writing;
    assign ram_din  = mem_write_data;

    // Registered ready + data: 1-cycle latency from valid -> ready, matching
    // Python's Memory.run timing.
    reg                  read_ready_q;
    reg [DATA_BITS-1:0]  read_data_q;
    reg                  write_ready_q;

    always @(posedge clk) begin
        if (reset) begin
            read_ready_q  <= 1'b0;
            read_data_q   <= {DATA_BITS{1'b0}};
            write_ready_q <= 1'b0;
        end else begin
            read_ready_q  <= mem_read_valid;
            read_data_q   <= ram_dout;
            write_ready_q <= writing;
        end
    end

    assign mem_read_ready  = read_ready_q;
    assign mem_read_data   = read_data_q;
    assign mem_write_ready = write_ready_q;
endmodule
