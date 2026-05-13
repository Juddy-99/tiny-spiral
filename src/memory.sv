`default_nettype none
`timescale 1ns/1ns

// SYNTHESIZABLE MEMORY
// > Provides the same valid/ready memory interface used by the tiny-gpu testbench
// > Initializes either the matadd program image or data image used by test/test_matadd.py
// > Uses register storage so the lab flow can synthesize it without external memory blocks
module memory #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 8,
    parameter NUM_CHANNELS = 1,
    parameter WRITE_ENABLE = 1,
    parameter INIT_IMAGE = 0
) (
    input wire clk,
    input wire reset,

    input wire [NUM_CHANNELS-1:0] read_valid,
    input wire [ADDR_BITS-1:0] read_address [NUM_CHANNELS-1:0],
    output reg [NUM_CHANNELS-1:0] read_ready,
    output reg [DATA_BITS-1:0] read_data [NUM_CHANNELS-1:0],

    input wire [NUM_CHANNELS-1:0] write_valid,
    input wire [ADDR_BITS-1:0] write_address [NUM_CHANNELS-1:0],
    input wire [DATA_BITS-1:0] write_data [NUM_CHANNELS-1:0],
    output reg [NUM_CHANNELS-1:0] write_ready,

    input wire [ADDR_BITS-1:0] debug_read_address,
    output reg [DATA_BITS-1:0] debug_read_data,
    output reg matadd_pass
);
    localparam INIT_MATADD_PROGRAM = 1;
    localparam INIT_MATADD_DATA = 2;
    localparam MEM_DEPTH = 1 << ADDR_BITS;

    reg [DATA_BITS-1:0] memory_array [MEM_DEPTH-1:0];

    integer i;
    integer channel;

    function [DATA_BITS-1:0] data_width;
        input [31:0] value;
        begin
            data_width = value[DATA_BITS-1:0];
        end
    endfunction

    task automatic load_image;
        begin
            for (i = 0; i < MEM_DEPTH; i = i + 1) begin
                memory_array[i] <= {DATA_BITS{1'b0}};
            end

            if (INIT_IMAGE == INIT_MATADD_PROGRAM) begin
                memory_array[0]  <= data_width(32'b0101000011011110); // MUL R0, %blockIdx, %blockDim
                memory_array[1]  <= data_width(32'b0011000000001111); // ADD R0, R0, %threadIdx
                memory_array[2]  <= data_width(32'b1001000100000000); // CONST R1, #0
                memory_array[3]  <= data_width(32'b1001001000001000); // CONST R2, #8
                memory_array[4]  <= data_width(32'b1001001100010000); // CONST R3, #16
                memory_array[5]  <= data_width(32'b0011010000010000); // ADD R4, R1, R0
                memory_array[6]  <= data_width(32'b0111010001000000); // LDR R4, R4
                memory_array[7]  <= data_width(32'b0011010100100000); // ADD R5, R2, R0
                memory_array[8]  <= data_width(32'b0111010101010000); // LDR R5, R5
                memory_array[9]  <= data_width(32'b0011011001000101); // ADD R6, R4, R5
                memory_array[10] <= data_width(32'b0011011100110000); // ADD R7, R3, R0
                memory_array[11] <= data_width(32'b1000000001110110); // STR R7, R6
                memory_array[12] <= data_width(32'b1111000000000000); // RET
            end else if (INIT_IMAGE == INIT_MATADD_DATA) begin
                memory_array[0]  <= data_width(32'd0);
                memory_array[1]  <= data_width(32'd1);
                memory_array[2]  <= data_width(32'd2);
                memory_array[3]  <= data_width(32'd3);
                memory_array[4]  <= data_width(32'd4);
                memory_array[5]  <= data_width(32'd5);
                memory_array[6]  <= data_width(32'd6);
                memory_array[7]  <= data_width(32'd7);
                memory_array[8]  <= data_width(32'd0);
                memory_array[9]  <= data_width(32'd1);
                memory_array[10] <= data_width(32'd2);
                memory_array[11] <= data_width(32'd3);
                memory_array[12] <= data_width(32'd4);
                memory_array[13] <= data_width(32'd5);
                memory_array[14] <= data_width(32'd6);
                memory_array[15] <= data_width(32'd7);
            end
        end
    endtask

    always @(*) begin
        for (channel = 0; channel < NUM_CHANNELS; channel = channel + 1) begin
            read_ready[channel] = read_valid[channel];
            read_data[channel] = read_valid[channel]
                ? memory_array[read_address[channel]]
                : {DATA_BITS{1'b0}};
            write_ready[channel] = WRITE_ENABLE && write_valid[channel];
        end

        debug_read_data = memory_array[debug_read_address];
        matadd_pass = (INIT_IMAGE == INIT_MATADD_DATA)
            && (memory_array[16] == data_width(32'd0))
            && (memory_array[17] == data_width(32'd2))
            && (memory_array[18] == data_width(32'd4))
            && (memory_array[19] == data_width(32'd6))
            && (memory_array[20] == data_width(32'd8))
            && (memory_array[21] == data_width(32'd10))
            && (memory_array[22] == data_width(32'd12))
            && (memory_array[23] == data_width(32'd14));
    end

    always @(posedge clk) begin
        if (reset) begin
            load_image();
        end else if (WRITE_ENABLE) begin
            for (channel = 0; channel < NUM_CHANNELS; channel = channel + 1) begin
                if (write_valid[channel]) begin
                    memory_array[write_address[channel]] <= write_data[channel];
                end
            end
        end
    end
endmodule
