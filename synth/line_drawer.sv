`default_nettype none
`timescale 1ns/1ns

// LINE DRAWER
// > Draws one Bresenham line from (x0, y0) to (x1, y1), emitting one pixel per
//   clk while busy.
// > Coordinates are 11 bits to match the 640x480 VGA framebuffer interface.
// > `start` is sampled in IDLE. `pixel_valid` marks each emitted pixel, and
//   `done` pulses for one cycle after the final pixel has been emitted.
module line_drawer (
    input wire clk,
    input wire reset,
    input wire start,
    input wire [10:0] x0,
    input wire [10:0] y0,
    input wire [10:0] x1,
    input wire [10:0] y1,
    output wire [10:0] x,
    output wire [10:0] y,
    output wire pixel_valid,
    output reg done,
    output wire busy
);
    localparam reg [0:0] IDLE = 1'b0,
        DRAW = 1'b1;

    reg state;

    wire [10:0] abs_dx_orig = (x1 >= x0) ? (x1 - x0) : (x0 - x1);
    wire [10:0] abs_dy_orig = (y1 >= y0) ? (y1 - y0) : (y0 - y1);
    wire is_steep = (abs_dx_orig < abs_dy_orig);

    wire [10:0] x0_swap = is_steep ? y0 : x0;
    wire [10:0] y0_swap = is_steep ? x0 : y0;
    wire [10:0] x1_swap = is_steep ? y1 : x1;
    wire [10:0] y1_swap = is_steep ? x1 : y1;

    wire reverse = (x0_swap > x1_swap);
    wire [10:0] x0_new = reverse ? x1_swap : x0_swap;
    wire [10:0] y0_new = reverse ? y1_swap : y0_swap;
    wire [10:0] x1_new = reverse ? x0_swap : x1_swap;
    wire [10:0] y1_new = reverse ? y0_swap : y1_swap;

    wire [10:0] dx = x1_new - x0_new;
    wire [10:0] dy = (y1_new >= y0_new) ? (y1_new - y0_new) : (y0_new - y1_new);
    wire signed [11:0] y_step = (y0_new < y1_new) ? 12'sd1 : -12'sd1;

    reg [10:0] x_current;
    reg signed [11:0] y_current;
    reg signed [11:0] error;
    reg steep_current;
    reg [10:0] x_last;
    reg [10:0] dx_current;
    reg [10:0] dy_current;
    reg signed [11:0] y_step_current;

    wire draw_done = (x_current == x_last);
    wire signed [11:0] error_added = error + $signed({1'b0, dy_current});
    wire take_y_step = (error_added >= 12'sd0);
    wire signed [11:0] y_next = take_y_step ? (y_current + y_step_current) : y_current;
    wire signed [11:0] error_next =
        take_y_step ? (error_added - $signed({1'b0, dx_current})) : error_added;

    wire [10:0] y_clamped = (y_current < 12'sd0) ? 11'd0
        : (y_current > 12'sd479) ? 11'd479
        : y_current[10:0];

    assign x = steep_current ? y_clamped : x_current;
    assign y = steep_current ? x_current : y_clamped;
    assign busy = (state == DRAW);
    assign pixel_valid = (state == DRAW);

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            x_current <= 11'd0;
            y_current <= 12'sd0;
            error <= 12'sd0;
            steep_current <= 1'b0;
            x_last <= 11'd0;
            dx_current <= 11'd0;
            dy_current <= 11'd0;
            y_step_current <= 12'sd1;
            done <= 1'b0;
        end else begin
            done <= 1'b0;

            case (state)
                IDLE: begin
                    if (start) begin
                        state <= DRAW;
                        x_current <= x0_new;
                        y_current <= $signed({1'b0, y0_new});
                        error <= -($signed({1'b0, dx}) >>> 1);
                        steep_current <= is_steep;
                        x_last <= x1_new;
                        dx_current <= dx;
                        dy_current <= dy;
                        y_step_current <= y_step;
                    end
                end
                DRAW: begin
                    if (draw_done) begin
                        state <= IDLE;
                        done <= 1'b1;
                    end else begin
                        x_current <= x_current + 11'd1;
                        y_current <= y_next;
                        error <= error_next;
                    end
                end
                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end
endmodule
