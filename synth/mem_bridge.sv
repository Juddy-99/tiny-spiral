`default_nettype none
`timescale 1ns/1ns

// MEM_BRIDGE
// > One-channel adapter between the GPU memory controller's valid/ready handshake
//   (see src/controller.sv) and an inferred RAM block (async read, sync write).
// > Reads: register ready + captured data so the controller spends two cycles
//   in READ_WAITING (matches Python Memory.run scheduling in cocotb).
// > Writes: Python sets mem_write_ready=1 in the same step whenever
//   mem_write_valid=1 (memory.py). That is combinational ready == valid for
//   the write handshake. A registered write_ready_q added one extra cycle that
//   still worked in Icarus but failed on some FPGA builds (STR hang at fixed PC).
//   So mem_write_ready is combinational from mem_write_valid when WRITE_ENABLE=1.
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

    reg                  read_ready_q;
    reg [DATA_BITS-1:0]  read_data_q;

    always @(posedge clk) begin
        if (reset) begin
            read_ready_q  <= 1'b0;
            read_data_q   <= {DATA_BITS{1'b0}};
        end else begin
            read_ready_q  <= mem_read_valid;
            read_data_q   <= ram_dout;
        end
    end

    assign mem_read_ready  = read_ready_q;
    assign mem_read_data   = read_data_q;
    assign mem_write_ready = writing;
endmodule
