`default_nettype none
`timescale 1ns/1ns

// CLOCK_STEP
// > Generates a slow gpu_clk from CLOCK_50.
//   - mode_auto = 0: single-step. Each rising edge of step_btn (already
//     button-active-high; caller passes ~KEY[0]) generates one CLOCK_50-cycle
//     pulse on clk_out. The button is synchronized through a 3-stage shift
//     register and edge-detected (a crude debounce -- a real button bounce
//     filter would add more state, but for a demo this is enough since the GPU
//     completes a kernel in <500 cycles and the user only presses once).
//   - mode_auto = 1: free-run. clk_out toggles every AUTO_DIV cycles of clk_in.
//     At AUTO_DIV=28_000 with CLOCK_50 = 50 MHz this gives ~893 Hz on gpu_clk
//     (full period = 2 * AUTO_DIV / 50 MHz ~= 1.12 ms). The spiral kernel
//     (test/test_spiral.py) runs one STRFB per ~223 gpu_clk cycles per thread
//     -- a precomputed dense pixel sequence is loaded for thread 0 and
//     rotated 90 deg per thread, four MULs per pixel -- so each of the 4
//     threads paints roughly 4 pixels per second. With 120 emits per thread
//     the entire pinwheel finishes in ~30 s, slow enough for the spiral to
//     visibly grow yet fast enough for an interactive demo.
// > AUTO_DIV is parameterized so cocotb tests of the synth top can override it
//   with `-Pde1_soc.SLOW_CLK_DIV=2` (see Makefile test_synth_top), without
//   waiting tens of thousands of sim ticks per gpu_clk edge.
//
// Note: gating CLOCK_50 to derive a slower clock would normally trip Quartus's
// clock-domain warnings. We use a registered toggle (clk_out is a flip-flop on
// CLOCK_50) so the resulting "slow clock" is actually a divided clock from
// CLOCK_50, which Quartus will infer as a derived clock.
module clock_step #(
    parameter AUTO_DIV = 32'd28_000   // half-period in clk_in cycles (~893 Hz gpu_clk)
) (
    input  wire clk_in,
    input  wire reset,
    input  wire mode_auto,
    input  wire step_btn,    // active-high
    output reg  clk_out
);
    reg [31:0] divider;
    reg [2:0]  step_sync;

    always @(posedge clk_in or posedge reset) begin
        if (reset) begin
            divider   <= 32'd0;
            step_sync <= 3'b000;
            clk_out   <= 1'b0;
        end else begin
            // Always sync the button so the FF chain has settled before we use it.
            step_sync <= {step_sync[1:0], step_btn};

            if (mode_auto) begin
                if (divider >= AUTO_DIV - 1) begin
                    divider <= 32'd0;
                    clk_out <= ~clk_out;     // toggle => one full GPU cycle every 2*AUTO_DIV clk_in cycles
                end else begin
                    divider <= divider + 1;
                end
            end else begin
                divider <= 32'd0;
                // Single-step: 1 clk_in-cycle pulse on rising edge of synced button
                clk_out <= step_sync[1] && !step_sync[2];
            end
        end
    end
endmodule
