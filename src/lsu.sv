`default_nettype none
`timescale 1ns/1ns

// LOAD-STORE UNIT
// > Handles asynchronous memory load and store operations and waits for response
// > Each thread in each core has it's own LSU
// > LDR, STR, STRFB instructions are executed here
// > The framebuffer (STRFB) write path mirrors the STR path: it walks the
//   IDLE -> REQUESTING -> WAITING -> DONE ladder and contributes to lsu_state,
//   so any_lsu_waiting in the scheduler stalls the warp on FB back-pressure
//   exactly the way it does for ordinary stores.
module lsu (
    input wire clk,
    input wire reset,
    input wire enable, // If current block has less threads then block size, some LSUs will be inactive

    // State
    input reg [2:0] core_state,

    // Memory Control Sgiansl
    input reg decoded_mem_read_enable,
    input reg decoded_mem_write_enable,
    input reg decoded_fb_write_enable,

    // Registers
    input reg [7:0] rs,
    input reg [7:0] rt,
    input reg [7:0] rd_val,

    // Data Memory
    output reg mem_read_valid,
    output reg [7:0] mem_read_address,
    input reg mem_read_ready,
    input reg [7:0] mem_read_data,
    output reg mem_write_valid,
    output reg [7:0] mem_write_address,
    output reg [7:0] mem_write_data,
    input reg mem_write_ready,

    // Framebuffer Write Port (STRFB). x = Rd, y = Rs, data = Rt.
    // fb_color is the monochrome thresholded pixel value (rt != 0). Carries
    // the per-thread "is this pixel on?" decision into the GPU top so a
    // later upgrade to color framebuffers can swap the math without touching
    // the LSU again.
    output reg fb_write_valid,
    output reg [7:0] fb_x,
    output reg [7:0] fb_y,
    output reg [7:0] fb_data,
    output reg fb_color,
    input reg fb_write_ready,

    // LSU Outputs
    output reg [1:0] lsu_state,
    output reg [7:0] lsu_out
);
    localparam IDLE = 2'b00, REQUESTING = 2'b01, WAITING = 2'b10, DONE = 2'b11;

    always @(posedge clk) begin
        if (reset) begin
            lsu_state <= IDLE;
            lsu_out <= 0;
            mem_read_valid <= 0;
            mem_read_address <= 0;
            mem_write_valid <= 0;
            mem_write_address <= 0;
            mem_write_data <= 0;
            fb_write_valid <= 0;
            fb_x <= 0;
            fb_y <= 0;
            fb_data <= 0;
            fb_color <= 0;
        end else if (enable) begin
            // If memory read enable is triggered (LDR instruction)
            if (decoded_mem_read_enable) begin 
                case (lsu_state)
                    IDLE: begin
                        // Only read when core_state = REQUEST
                        if (core_state == 3'b011) begin 
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin 
                        mem_read_valid <= 1;
                        mem_read_address <= rs;
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        if (mem_read_ready == 1) begin
                            mem_read_valid <= 0;
                            lsu_out <= mem_read_data;
                            lsu_state <= DONE;
                        end
                    end
                    DONE: begin 
                        // Reset when core_state = UPDATE
                        if (core_state == 3'b110) begin 
                            lsu_state <= IDLE;
                        end
                    end
                endcase
            end

            // If memory write enable is triggered (STR instruction)
            if (decoded_mem_write_enable) begin 
                case (lsu_state)
                    IDLE: begin
                        // Only read when core_state = REQUEST
                        if (core_state == 3'b011) begin 
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin 
                        mem_write_valid <= 1;
                        mem_write_address <= rs;
                        mem_write_data <= rt;
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        if (mem_write_ready) begin
                            mem_write_valid <= 0;
                            lsu_state <= DONE;
                        end
                    end
                    DONE: begin 
                        // Reset when core_state = UPDATE
                        if (core_state == 3'b110) begin 
                            lsu_state <= IDLE;
                        end
                    end
                endcase
            end

            // If framebuffer write enable is triggered (STRFB instruction)
            if (decoded_fb_write_enable) begin
                case (lsu_state)
                    IDLE: begin
                        if (core_state == 3'b011) begin
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin
                        fb_write_valid <= 1;
                        fb_x <= rd_val;
                        fb_y <= rs;
                        fb_data <= rt;
                        // Monochrome thresholding: any nonzero pixel data => white.
                        // Future color upgrade swaps this for a passthrough or palette
                        // lookup without touching the rest of the pipeline.
                        fb_color <= (rt != 8'b0);
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        if (fb_write_ready) begin
                            fb_write_valid <= 0;
                            lsu_state <= DONE;
                        end
                    end
                    DONE: begin
                        if (core_state == 3'b110) begin
                            lsu_state <= IDLE;
                        end
                    end
                endcase
            end
        end
    end
endmodule
