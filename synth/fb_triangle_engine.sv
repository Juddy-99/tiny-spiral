`default_nettype none
`timescale 1ns/1ns

// FRAMEBUFFER TRIANGLE ENGINE
// > PS1-style flat-color triangle rasterizer.
// > Implements scanline DDA with integer Q16 slopes computed via the
//   combinational reciprocal LUT (synth/recip_lut.sv). No iterative
//   divider; setup is ~5 cycles, fill is ~area_pixels + ~1 cycle/row.
//
// Fill rule (must mirror test/helpers/raster.py exactly):
//   Left-inclusive, right-EXCLUSIVE; top-inclusive, bottom-EXCLUSIVE.
//   Vertex sort key (y, x) ascending. Degenerate (yt==yb or cross==0)
//   triangles produce zero pixels.
//
// Math widths (all sign-handled explicitly; no implicit widening):
//   coord input:        unsigned 11-bit (0..2047; we use 0..255)
//   dx (signed):        signed   12-bit (-255..255 plus sign bit)
//   recip[dy]:          unsigned 17-bit (max 65536 at dy=1)
//   slope (Q16):        signed   32-bit (dx*recip fits in ~26 bits)
//   accumulator (Q16):  signed   32-bit
//
// FSM:
//   IDLE -> SORT -> REJECT -> SLOPES -> INIT -> RUN -> FINISH -> IDLE
//
// Safety belts (every reg below has an explicit reset value; every case
// closes with `default`; pixel_write is pure-combinational so it cannot
// linger after RUN exits).
module fb_triangle_engine (
    input  wire        clk,
    input  wire        reset,
    input  wire        start,
    input  wire [10:0] x0,
    input  wire [10:0] y0,
    input  wire [10:0] x1,
    input  wire [10:0] y1,
    input  wire [10:0] x2,
    input  wire [10:0] y2,
    input  wire        pixel_color_in,
    output wire [10:0] x,
    output wire [10:0] y,
    output wire        pixel_color,
    output wire        pixel_write,
    output reg         done,
    output wire        busy
);
    localparam [2:0]
        IDLE   = 3'd0,
        SORT   = 3'd1,
        REJECT = 3'd2,
        SLOPES = 3'd3,
        INIT   = 3'd4,
        RUN    = 3'd5,
        FINISH = 3'd6;

    reg [2:0] state;

    // Latched input vertices (registered from IDLE -> SORT transition).
    reg [10:0] x0_r, y0_r, x1_r, y1_r, x2_r, y2_r;
    reg        color_r;

    // Sorted vertices (registered in SORT).
    reg [10:0] xt, yt, xm, ym, xb_v, yb_v;

    // Slopes and mid_is_left (registered in SLOPES).
    reg signed [31:0] slope_long, slope_top, slope_bot;
    reg               mid_is_left;

    // Per-row state (registered in INIT and updated in RUN).
    reg [10:0] cy_r;
    reg signed [31:0] xa_q, xb_q;
    reg [10:0] ix, xr_r;

    // -----------------------------------------------------------------
    // SORT - combinational 3-way sort by (y, x) ascending.
    // -----------------------------------------------------------------
    wire le01 = (y0_r < y1_r) || ((y0_r == y1_r) && (x0_r <= x1_r));
    wire le02 = (y0_r < y2_r) || ((y0_r == y2_r) && (x0_r <= x2_r));
    wire le12 = (y1_r < y2_r) || ((y1_r == y2_r) && (x1_r <= x2_r));

    wire [1:0] top_idx = (le01 && le02) ? 2'd0
                        : ((!le01) && le12) ? 2'd1
                        : 2'd2;
    wire [1:0] bot_idx = ((!le01) && (!le02)) ? 2'd0
                        : (le01 && (!le12))   ? 2'd1
                        : 2'd2;
    wire [1:0] mid_idx = 2'd3 - top_idx - bot_idx;

    wire [10:0] xt_c   = (top_idx == 2'd0) ? x0_r : (top_idx == 2'd1) ? x1_r : x2_r;
    wire [10:0] yt_c   = (top_idx == 2'd0) ? y0_r : (top_idx == 2'd1) ? y1_r : y2_r;
    wire [10:0] xm_c   = (mid_idx == 2'd0) ? x0_r : (mid_idx == 2'd1) ? x1_r : x2_r;
    wire [10:0] ym_c   = (mid_idx == 2'd0) ? y0_r : (mid_idx == 2'd1) ? y1_r : y2_r;
    wire [10:0] xb_c   = (bot_idx == 2'd0) ? x0_r : (bot_idx == 2'd1) ? x1_r : x2_r;
    wire [10:0] yb_c   = (bot_idx == 2'd0) ? y0_r : (bot_idx == 2'd1) ? y1_r : y2_r;

    // -----------------------------------------------------------------
    // REJECT - combinational cross product on sorted vertices.
    //   cross = (xm - xt)*(yb - yt) - (xb - xt)*(ym - yt)
    // -----------------------------------------------------------------
    wire signed [12:0] dx_top_s  = $signed({2'b00, xm}) - $signed({2'b00, xt});
    wire signed [12:0] dx_long_s = $signed({2'b00, xb_v}) - $signed({2'b00, xt});
    wire signed [12:0] dx_bot_s  = $signed({2'b00, xb_v}) - $signed({2'b00, xm});
    wire signed [12:0] dy_top_s  = $signed({2'b00, ym}) - $signed({2'b00, yt});
    wire signed [12:0] dy_long_s = $signed({2'b00, yb_v}) - $signed({2'b00, yt});
    wire signed [12:0] dy_bot_s  = $signed({2'b00, yb_v}) - $signed({2'b00, ym});

    wire signed [26:0] cross_c = (dx_top_s * dy_long_s) - (dx_long_s * dy_top_s);

    // -----------------------------------------------------------------
    // SLOPES - three Q16 multiplies using the reciprocal LUT.
    //   slope = dx_signed * recip[dy_unsigned]   (signed Q16)
    // -----------------------------------------------------------------
    wire [7:0] dy_long_u = yb_v[7:0] - yt[7:0];
    wire [7:0] dy_top_u  = ym[7:0]   - yt[7:0];
    wire [7:0] dy_bot_u  = yb_v[7:0] - ym[7:0];

    wire [16:0] recip_long_w, recip_top_w, recip_bot_w;
    recip_lut recip_long_lut (.dy(dy_long_u), .recip(recip_long_w));
    recip_lut recip_top_lut  (.dy(dy_top_u),  .recip(recip_top_w));
    recip_lut recip_bot_lut  (.dy(dy_bot_u),  .recip(recip_bot_w));

    wire signed [17:0] recip_long_s = $signed({1'b0, recip_long_w});
    wire signed [17:0] recip_top_s  = $signed({1'b0, recip_top_w});
    wire signed [17:0] recip_bot_s  = $signed({1'b0, recip_bot_w});

    wire signed [31:0] slope_long_c = dx_long_s * recip_long_s;
    wire signed [31:0] slope_top_c  = (dy_top_u == 8'd0) ? 32'sd0 : (dx_top_s * recip_top_s);
    wire signed [31:0] slope_bot_c  = (dy_bot_u == 8'd0) ? 32'sd0 : (dx_bot_s * recip_bot_s);

    //   mid_is_left = (xm << 16) < ((xt << 16) + slope_long * (ym - yt))
    // dy_top_s is the row count from top to mid (>= 0 after sort).
    wire signed [31:0] xt_q_c          = {{5{1'b0}}, xt,   16'd0};
    wire signed [31:0] xm_q_c          = {{5{1'b0}}, xm,   16'd0};
    wire signed [31:0] long_x_at_ym_c  = xt_q_c + (slope_long_c * dy_top_s);
    wire               mid_is_left_c   = (xm_q_c < long_x_at_ym_c);

    // -----------------------------------------------------------------
    // INIT - initialize accumulators for the first row (cy = yt).
    //   xa = xt (long edge); xb = xt, unless yt == ym in which case the
    //   top half is skipped entirely and we start the bot half by
    //   snapping xb to xm.
    // -----------------------------------------------------------------
    wire [10:0] init_xa_int = xt;
    wire [10:0] init_xb_int = (yt == ym) ? xm : xt;
    wire [10:0] init_xl     = mid_is_left ? init_xb_int : init_xa_int;
    wire [10:0] init_xr     = mid_is_left ? init_xa_int : init_xb_int;

    // -----------------------------------------------------------------
    // RUN - one cycle per pixel + one cycle per row-advance.
    // Compute next state combinationally so the always block stays
    // shallow and sv2v-friendly.
    // -----------------------------------------------------------------
    wire signed [31:0] slope_short_used = (cy_r < ym) ? slope_top : slope_bot;
    wire signed [31:0] new_xa_q_c       = xa_q + slope_long;
    wire signed [31:0] new_xb_q_pre     = xb_q + slope_short_used;
    wire [10:0]        new_cy_c         = cy_r + 11'd1;
    wire               snap_to_mid      = (new_cy_c == ym);
    wire signed [31:0] new_xb_q_c       = snap_to_mid
                                         ? {{5{1'b0}}, xm, 16'd0}
                                         : new_xb_q_pre;

    // Integer part of Q16 accumulator (signed arithmetic shift right by 16).
    wire signed [15:0] new_xa_int_s = new_xa_q_c[31:16];
    wire signed [15:0] new_xb_int_s = new_xb_q_c[31:16];

    wire signed [15:0] new_xl_raw = mid_is_left ? new_xb_int_s : new_xa_int_s;
    wire signed [15:0] new_xr_raw = mid_is_left ? new_xa_int_s : new_xb_int_s;

    wire [10:0] new_xl_c = (new_xl_raw < 16'sd0)        ? 11'd0
                          : (new_xl_raw > 16'sd2047)    ? 11'd2047
                          : new_xl_raw[10:0];
    wire [10:0] new_xr_c = (new_xr_raw < 16'sd0)        ? 11'd0
                          : (new_xr_raw > 16'sd2047)    ? 11'd2047
                          : new_xr_raw[10:0];

    // -----------------------------------------------------------------
    // Outputs.
    // -----------------------------------------------------------------
    assign x           = ix;
    assign y           = cy_r;
    assign pixel_color = color_r;
    assign pixel_write = (state == RUN) && (ix < xr_r);
    assign busy        = (state != IDLE);

    // -----------------------------------------------------------------
    // Sequential FSM.
    // -----------------------------------------------------------------
    always @(posedge clk) begin
        if (reset) begin
            state       <= IDLE;
            done        <= 1'b0;
            x0_r        <= 11'd0;
            y0_r        <= 11'd0;
            x1_r        <= 11'd0;
            y1_r        <= 11'd0;
            x2_r        <= 11'd0;
            y2_r        <= 11'd0;
            color_r     <= 1'b0;
            xt          <= 11'd0;
            yt          <= 11'd0;
            xm          <= 11'd0;
            ym          <= 11'd0;
            xb_v        <= 11'd0;
            yb_v        <= 11'd0;
            slope_long  <= 32'sd0;
            slope_top   <= 32'sd0;
            slope_bot   <= 32'sd0;
            mid_is_left <= 1'b0;
            cy_r        <= 11'd0;
            xa_q        <= 32'sd0;
            xb_q        <= 32'sd0;
            ix          <= 11'd0;
            xr_r        <= 11'd0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    if (start) begin
                        x0_r    <= x0;
                        y0_r    <= y0;
                        x1_r    <= x1;
                        y1_r    <= y1;
                        x2_r    <= x2;
                        y2_r    <= y2;
                        color_r <= pixel_color_in;
                        state   <= SORT;
                    end
                end
                SORT: begin
                    xt   <= xt_c;
                    yt   <= yt_c;
                    xm   <= xm_c;
                    ym   <= ym_c;
                    xb_v <= xb_c;
                    yb_v <= yb_c;
                    state <= REJECT;
                end
                REJECT: begin
                    if ((yt == yb_v) || (cross_c == 27'sd0)) begin
                        state <= FINISH;
                    end else begin
                        state <= SLOPES;
                    end
                end
                SLOPES: begin
                    slope_long  <= slope_long_c;
                    slope_top   <= slope_top_c;
                    slope_bot   <= slope_bot_c;
                    mid_is_left <= mid_is_left_c;
                    state       <= INIT;
                end
                INIT: begin
                    cy_r <= yt;
                    xa_q <= {{5{1'b0}}, xt, 16'd0};
                    xb_q <= (yt == ym)
                            ? {{5{1'b0}}, xm, 16'd0}
                            : {{5{1'b0}}, xt, 16'd0};
                    // init_xl and init_xr are already 11-bit; no further clip
                    // is needed at INIT. Coordinates inside the engine cannot
                    // exceed 2047 because input ports are 11-bit unsigned.
                    ix   <= init_xl;
                    xr_r <= init_xr;
                    state <= RUN;
                end
                RUN: begin
                    if (ix < xr_r) begin
                        ix <= ix + 11'd1;
                    end else begin
                        if (new_cy_c == yb_v) begin
                            state <= FINISH;
                        end else begin
                            cy_r <= new_cy_c;
                            xa_q <= new_xa_q_c;
                            xb_q <= new_xb_q_c;
                            ix   <= new_xl_c;
                            xr_r <= new_xr_c;
                        end
                    end
                end
                FINISH: begin
                    done  <= 1'b1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
