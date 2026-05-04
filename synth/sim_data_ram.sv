`default_nettype none
`timescale 1ns/1ns

// SIM_DATA_RAM
// > Async-read multi-port data RAM for the mem_bridge isolation test.
// > Single shared reg array with NUM_CHANNELS independent address/we/din/dout
//   ports. All channels see coherent memory (controller protocol guarantees no
//   simultaneous writes to the same address from different LSUs).
// > Async read + sync write -> bridge stays purely combinational, so cycle
//   counts match the Python Memory model.
// > For real FPGA synthesis the *generated* synth/kernel_memories.sv replaces
//   this file with a different RAM topology (typically single-port BRAM with
//   NUM_CHANNELS=1 to fit within Cyclone V's M10K constraints).
module sim_data_ram #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 8,
    parameter NUM_CHANNELS = 4
) (
    input wire clk,

    // Backdoor loader (test-only; tied off in synth)
    input wire init_we,
    input wire [ADDR_BITS-1:0] init_addr,
    input wire [DATA_BITS-1:0] init_din,

    input wire [ADDR_BITS-1:0] addr [NUM_CHANNELS-1:0],
    input wire [NUM_CHANNELS-1:0] we,
    input wire [DATA_BITS-1:0] din [NUM_CHANNELS-1:0],
    output wire [DATA_BITS-1:0] dout [NUM_CHANNELS-1:0]
);
    reg [DATA_BITS-1:0] mem [0:(1<<ADDR_BITS)-1];

    integer i;
    always @(posedge clk) begin
        if (init_we) begin
            mem[init_addr] <= init_din;
        end else begin
            // Lower-indexed channel wins on simultaneous same-address writes;
            // controller protocol means this never happens for distinct
            // addresses, so behavior is well-defined either way.
            for (i = 0; i < NUM_CHANNELS; i = i + 1) begin
                if (we[i]) mem[addr[i]] <= din[i];
            end
        end
    end

    genvar g;
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : ports
            assign dout[g] = mem[addr[g]];
        end
    endgenerate
endmodule
