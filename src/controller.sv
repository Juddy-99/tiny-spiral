`default_nettype none
`timescale 1ns/1ns

// MEMORY CONTROLLER
// > Receives memory requests from all cores
// > Throttles requests based on limited external memory bandwidth
// > Waits for responses from external memory and distributes responses back to cores
// > Arbitration uses a combinational always @* block (serving_tmp + remaining mask)
//   followed by registered updates only with <=. This matches the simulation intent
//   of the old blocking channel_serving_consumer pattern but avoids Quartus
//   mis-inferring shared blocking assigns inside always @(posedge clk).
module controller #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 16,
    parameter NUM_CONSUMERS = 4, // The number of consumers accessing memory through this controller
    parameter NUM_CHANNELS = 1,  // The number of concurrent channels available to send requests to global memory
    parameter WRITE_ENABLE = 1   // Whether this memory controller can write to memory (program memory is read-only)
) (
    input wire clk,
    input wire reset,

    // Consumer Interface (Fetchers / LSUs)
    input reg [NUM_CONSUMERS-1:0] consumer_read_valid,
    input reg [ADDR_BITS-1:0] consumer_read_address [NUM_CONSUMERS-1:0],
    output reg [NUM_CONSUMERS-1:0] consumer_read_ready,
    output reg [DATA_BITS-1:0] consumer_read_data [NUM_CONSUMERS-1:0],
    input reg [NUM_CONSUMERS-1:0] consumer_write_valid,
    input reg [ADDR_BITS-1:0] consumer_write_address [NUM_CONSUMERS-1:0],
    input reg [DATA_BITS-1:0] consumer_write_data [NUM_CONSUMERS-1:0],
    output reg [NUM_CONSUMERS-1:0] consumer_write_ready,

    // Memory Interface (Data / Program)
    output reg [NUM_CHANNELS-1:0] mem_read_valid,
    output reg [ADDR_BITS-1:0] mem_read_address [NUM_CHANNELS-1:0],
    input reg [NUM_CHANNELS-1:0] mem_read_ready,
    input reg [DATA_BITS-1:0] mem_read_data [NUM_CHANNELS-1:0],
    output reg [NUM_CHANNELS-1:0] mem_write_valid,
    output reg [ADDR_BITS-1:0] mem_write_address [NUM_CHANNELS-1:0],
    output reg [DATA_BITS-1:0] mem_write_data [NUM_CHANNELS-1:0],
    input reg [NUM_CHANNELS-1:0] mem_write_ready
);
    localparam IDLE = 3'b000,
        READ_WAITING = 3'b010,
        WRITE_WAITING = 3'b011,
        READ_RELAYING = 3'b100,
        WRITE_RELAYING = 3'b101;

    reg [2:0] controller_state [NUM_CHANNELS-1:0];
    reg [$clog2(NUM_CONSUMERS)-1:0] current_consumer [NUM_CHANNELS-1:0];
    reg [NUM_CONSUMERS-1:0] serving_reg;

    // Combinational picks: -1 means no grant for this channel this cycle
    integer pick_rd [NUM_CHANNELS-1:0];
    integer pick_wr [NUM_CHANNELS-1:0];
    reg [NUM_CONSUMERS-1:0] serving_next;
    reg [NUM_CONSUMERS-1:0] remaining_tmp;

    integer ci;
    integer cj;

    always @* begin
        // Release consumers finishing RELAYING (same-cycle release then other channels may pick)
        serving_next = serving_reg;
        for (ci = 0; ci < NUM_CHANNELS; ci = ci + 1) begin
            case (controller_state[ci])
                READ_RELAYING: begin
                    if (!consumer_read_valid[current_consumer[ci]]) begin
                        serving_next[current_consumer[ci]] = 1'b0;
                    end
                end
                WRITE_RELAYING: begin
                    if (!consumer_write_valid[current_consumer[ci]]) begin
                        serving_next[current_consumer[ci]] = 1'b0;
                    end
                end
                default: ;
            endcase
        end

        for (ci = 0; ci < NUM_CHANNELS; ci = ci + 1) begin
            pick_rd[ci] = -1;
            pick_wr[ci] = -1;
        end

        remaining_tmp = ~serving_next;
        for (ci = 0; ci < NUM_CHANNELS; ci = ci + 1) begin
            if (controller_state[ci] == IDLE) begin
                for (cj = 0; cj < NUM_CONSUMERS; cj = cj + 1) begin
                    if (consumer_read_valid[cj] && remaining_tmp[cj]) begin
                        pick_rd[ci] = cj;
                        remaining_tmp[cj] = 1'b0;
                        serving_next[cj] = 1'b1;
                        break;
                    end else if (WRITE_ENABLE && consumer_write_valid[cj] && remaining_tmp[cj]) begin
                        pick_wr[ci] = cj;
                        remaining_tmp[cj] = 1'b0;
                        serving_next[cj] = 1'b1;
                        break;
                    end
                end
            end
        end
    end

    always @(posedge clk) begin
        if (reset) begin
            mem_read_valid <= {NUM_CHANNELS{1'b0}};
            mem_read_address <= '{NUM_CHANNELS{{ADDR_BITS{1'b0}}}};

            mem_write_valid <= {NUM_CHANNELS{1'b0}};
            mem_write_address <= '{NUM_CHANNELS{{ADDR_BITS{1'b0}}}};
            mem_write_data <= '{NUM_CHANNELS{{DATA_BITS{1'b0}}}};

            consumer_read_ready <= {NUM_CONSUMERS{1'b0}};
            consumer_read_data <= '{NUM_CONSUMERS{{DATA_BITS{1'b0}}}};
            consumer_write_ready <= {NUM_CONSUMERS{1'b0}};

            current_consumer <= '{NUM_CHANNELS{{$clog2(NUM_CONSUMERS){1'b0}}}};
            controller_state <= '{NUM_CHANNELS{IDLE}};

            serving_reg <= {NUM_CONSUMERS{1'b0}};
        end else begin
            serving_reg <= serving_next;

            for (ci = 0; ci < NUM_CHANNELS; ci = ci + 1) begin
                case (controller_state[ci])
                    IDLE: begin
                        if (pick_wr[ci] >= 0) begin
                            current_consumer[ci] <= pick_wr[ci];
                            mem_write_valid[ci] <= 1'b1;
                            mem_write_address[ci] <= consumer_write_address[pick_wr[ci]];
                            mem_write_data[ci] <= consumer_write_data[pick_wr[ci]];
                            controller_state[ci] <= WRITE_WAITING;
                        end else if (pick_rd[ci] >= 0) begin
                            current_consumer[ci] <= pick_rd[ci];
                            mem_read_valid[ci] <= 1'b1;
                            mem_read_address[ci] <= consumer_read_address[pick_rd[ci]];
                            controller_state[ci] <= READ_WAITING;
                        end
                    end
                    READ_WAITING: begin
                        if (mem_read_ready[ci]) begin
                            mem_read_valid[ci] <= 1'b0;
                            consumer_read_ready[current_consumer[ci]] <= 1'b1;
                            consumer_read_data[current_consumer[ci]] <= mem_read_data[ci];
                            controller_state[ci] <= READ_RELAYING;
                        end
                    end
                    WRITE_WAITING: begin
                        if (mem_write_ready[ci]) begin
                            mem_write_valid[ci] <= 1'b0;
                            consumer_write_ready[current_consumer[ci]] <= 1'b1;
                            controller_state[ci] <= WRITE_RELAYING;
                        end
                    end
                    READ_RELAYING: begin
                        if (!consumer_read_valid[current_consumer[ci]]) begin
                            consumer_read_ready[current_consumer[ci]] <= 1'b0;
                            controller_state[ci] <= IDLE;
                        end
                    end
                    WRITE_RELAYING: begin
                        if (!consumer_write_valid[current_consumer[ci]]) begin
                            consumer_write_ready[current_consumer[ci]] <= 1'b0;
                            controller_state[ci] <= IDLE;
                        end
                    end
                endcase
            end
        end
    end
endmodule
