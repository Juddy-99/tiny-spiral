`default_nettype none
`timescale 1ns/1ns

// FRAMEBUFFER LINE ENGINE
// > Accepts one framebuffer request at a time in the CLOCK_50 domain.
// > Direct requests emit one pixel write. Line requests run line_drawer and
//   forward each generated pixel to VGA_framebuffer.
module fb_line_engine (
    input wire clk,
    input wire reset,
    input wire start,
    input wire is_line,
    input wire [10:0] x0,
    input wire [10:0] y0,
    input wire [10:0] x1,
    input wire [10:0] y1,
    input wire [7:0] pixel_color_in,
    output wire [10:0] x,
    output wire [10:0] y,
    output wire [7:0] pixel_color,
    output wire pixel_write,
    output reg done,
    output wire busy
);
    localparam reg [1:0] IDLE = 2'b00,
        DIRECT = 2'b01,
        LINE = 2'b10,
        FINISH = 2'b11;

    reg [1:0] state;
    reg line_start;
    reg [7:0] color_q;
    reg [10:0] direct_x;
    reg [10:0] direct_y;

    wire [10:0] line_x;
    wire [10:0] line_y;
    wire line_pixel_valid;
    wire line_done;
    wire line_busy;

    line_drawer line_drawer_instance (
        .clk(clk),
        .reset(reset),
        .start(line_start),
        .x0(x0),
        .y0(y0),
        .x1(x1),
        .y1(y1),
        .x(line_x),
        .y(line_y),
        .pixel_valid(line_pixel_valid),
        .done(line_done),
        .busy(line_busy)
    );

    assign x = (state == LINE) ? line_x : direct_x;
    assign y = (state == LINE) ? line_y : direct_y;
    assign pixel_color = color_q;
    assign pixel_write = (state == DIRECT) || ((state == LINE) && line_pixel_valid);
    assign busy = (state != IDLE);

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            line_start <= 1'b0;
            color_q <= 8'd0;
            direct_x <= 11'd0;
            direct_y <= 11'd0;
            done <= 1'b0;
        end else begin
            line_start <= 1'b0;
            done <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        color_q <= pixel_color_in;
                        if (is_line) begin
                            line_start <= 1'b1;
                            state <= LINE;
                        end else begin
                            direct_x <= x1;
                            direct_y <= y1;
                            state <= DIRECT;
                        end
                    end
                end
                DIRECT: begin
                    state <= FINISH;
                end
                LINE: begin
                    if (line_done) begin
                        state <= FINISH;
                    end
                end
                FINISH: begin
                    done <= 1'b1;
                    state <= IDLE;
                end
                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule
