`default_nettype none
`timescale 1ns/1ns

// SIM_PROGRAM_ROM
// > Async-read program ROM for the mem_bridge isolation test.
// > Uses an unpacked reg array so cocotb can backdoor-load instructions via
//   the init_we / init_addr / init_din ports BEFORE the kernel starts.
// > Async read keeps the bridge purely combinational so cycle counts match the
//   Python Memory model in test/helpers/memory.py exactly.
// > For FPGA synthesis the *generated* synth/kernel_memories.sv replaces this
//   file with an `initial`-block-loaded ROM (no backdoor port needed there).
module sim_program_rom #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 16,
    parameter NUM_CHANNELS = 1
) (
    input wire clk,

    // Backdoor loader (test-only; tied off in synth)
    input wire init_we,
    input wire [ADDR_BITS-1:0] init_addr,
    input wire [DATA_BITS-1:0] init_din,

    // Async-read ports (one per channel)
    input wire [ADDR_BITS-1:0] addr [NUM_CHANNELS-1:0],
    output wire [DATA_BITS-1:0] dout [NUM_CHANNELS-1:0]
);
    reg [DATA_BITS-1:0] mem [0:(1<<ADDR_BITS)-1];

    always @(posedge clk) begin
        if (init_we) mem[init_addr] <= init_din;
    end

    genvar g;
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : ports
            assign dout[g] = mem[addr[g]];
        end
    endgenerate
endmodule
