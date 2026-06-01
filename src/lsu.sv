`default_nettype none
`timescale 1ns/1ns

// LOAD-STORE UNIT
// > Handles asynchronous memory load and store operations and waits for response
// > Each thread in each core has it's own LSU
// > LDR, STR, STRFB, LNS, LNE, TRV, TRE instructions are executed here.
// > The framebuffer (STRFB/LNE/TRE) write path mirrors the STR path: it walks
//   the IDLE -> REQUESTING -> WAITING -> DONE ladder and contributes to
//   lsu_state, so any_lsu_waiting in the scheduler stalls the warp on FB
//   back-pressure exactly the way it does for ordinary stores.
// > fb_mode is the request kind seen by the framebuffer engine:
//     2'b00 = PIXEL (STRFB)
//     2'b01 = LINE  (LNE)
//     2'b10 = TRI   (TRE)
//     2'b11 = reserved
// > Triangle latches (tri_v0_*, tri_v1_*, tri_idx) reset ONLY on module reset,
//   not per-instruction. tri_idx is reset to 0 again after a TRE submit so the
//   next triangle's first TRV writes v0.
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
    input reg decoded_line_start_enable,
    input reg decoded_line_end_enable,
    input reg decoded_tri_vertex_enable,
    input reg decoded_tri_submit_enable,

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

    // Framebuffer Write Port. fb_mode selects between PIXEL / LINE / TRI:
    //   PIXEL: (fb_x, fb_y) -> one pixel
    //   LINE:  (fb_x0, fb_y0) -> (fb_x, fb_y)
    //   TRI:   v0=(fb_x0,fb_y0), v1=(fb_x1,fb_y1), v2=(fb_x,fb_y)
    // fb_color is the 8-bit RGB-3-3-2 pixel color (Rt passed through directly).
    output reg fb_write_valid,
    output reg [1:0] fb_mode,
    output reg [7:0] fb_x0,
    output reg [7:0] fb_y0,
    output reg [7:0] fb_x1,
    output reg [7:0] fb_y1,
    output reg [7:0] fb_x,
    output reg [7:0] fb_y,
    output reg [7:0] fb_color,
    input reg fb_write_ready,

    // LSU Outputs
    output reg [1:0] lsu_state,
    output reg [7:0] lsu_out
);
    localparam IDLE = 2'b00, REQUESTING = 2'b01, WAITING = 2'b10, DONE = 2'b11;
    localparam [1:0] MODE_PIXEL = 2'b00, MODE_LINE = 2'b01, MODE_TRI = 2'b10;

    reg [7:0] line_x0;
    reg [7:0] line_y0;

    // Triangle vertex latches. Persist across instructions (only reset on
    // module reset and on TRE submit). tri_idx selects which vertex slot the
    // next TRV writes (0 = v0, 1 = v1).
    reg [7:0] tri_v0_x, tri_v0_y;
    reg [7:0] tri_v1_x, tri_v1_y;
    reg       tri_idx;

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
            fb_mode <= MODE_PIXEL;
            fb_x0 <= 0;
            fb_y0 <= 0;
            fb_x1 <= 0;
            fb_y1 <= 0;
            fb_x <= 0;
            fb_y <= 0;
            fb_color <= 0;
            line_x0 <= 0;
            line_y0 <= 0;
            tri_v0_x <= 0;
            tri_v0_y <= 0;
            tri_v1_x <= 0;
            tri_v1_y <= 0;
            tri_idx <= 0;
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
                        fb_mode <= MODE_PIXEL;
                        fb_x0 <= rd_val;
                        fb_y0 <= rs;
                        fb_x1 <= 0;
                        fb_y1 <= 0;
                        fb_x <= rd_val;
                        fb_y <= rs;
                        // 8-bit RGB-3-3-2 color: pass Rt through directly.
                        fb_color <= rt;
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

            // If line start enable is triggered (LNS instruction)
            if (decoded_line_start_enable) begin
                case (lsu_state)
                    IDLE: begin
                        if (core_state == 3'b011) begin
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin
                        line_x0 <= rd_val;
                        line_y0 <= rs;
                        lsu_state <= DONE;
                    end
                    DONE: begin
                        if (core_state == 3'b110) begin
                            lsu_state <= IDLE;
                        end
                    end
                    default: ;
                endcase
            end

            // If line end enable is triggered (LNE instruction)
            if (decoded_line_end_enable) begin
                case (lsu_state)
                    IDLE: begin
                        if (core_state == 3'b011) begin
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin
                        fb_write_valid <= 1;
                        fb_mode <= MODE_LINE;
                        fb_x0 <= line_x0;
                        fb_y0 <= line_y0;
                        fb_x1 <= 0;
                        fb_y1 <= 0;
                        fb_x <= rd_val;
                        fb_y <= rs;
                        fb_color <= rt;
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

            // If triangle vertex enable is triggered (TRV instruction). TRV
            // latches (rd_val, rs) into the active vertex slot and toggles
            // tri_idx. It does NOT assert fb_write_valid and skips WAITING so
            // the scheduler does not stall on FB back-pressure for setup.
            if (decoded_tri_vertex_enable) begin
                case (lsu_state)
                    IDLE: begin
                        if (core_state == 3'b011) begin
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin
                        if (tri_idx == 1'b0) begin
                            tri_v0_x <= rd_val;
                            tri_v0_y <= rs;
                        end else begin
                            tri_v1_x <= rd_val;
                            tri_v1_y <= rs;
                        end
                        tri_idx <= ~tri_idx;
                        lsu_state <= DONE;
                    end
                    DONE: begin
                        if (core_state == 3'b110) begin
                            lsu_state <= IDLE;
                        end
                    end
                    default: ;
                endcase
            end

            // If triangle submit enable is triggered (TRE instruction). TRE
            // submits {v0, v1, (rd_val, rs), rt-color, mode=TRI} to the FB
            // controller and resets tri_idx so the next TRV writes v0.
            if (decoded_tri_submit_enable) begin
                case (lsu_state)
                    IDLE: begin
                        if (core_state == 3'b011) begin
                            lsu_state <= REQUESTING;
                        end
                    end
                    REQUESTING: begin
                        fb_write_valid <= 1;
                        fb_mode <= MODE_TRI;
                        fb_x0 <= tri_v0_x;
                        fb_y0 <= tri_v0_y;
                        fb_x1 <= tri_v1_x;
                        fb_y1 <= tri_v1_y;
                        fb_x <= rd_val;
                        fb_y <= rs;
                        fb_color <= rt;
                        lsu_state <= WAITING;
                    end
                    WAITING: begin
                        if (fb_write_ready) begin
                            fb_write_valid <= 0;
                            tri_idx <= 1'b0;
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
