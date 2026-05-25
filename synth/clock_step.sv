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
//     At AUTO_DIV=10_000_000 with CLOCK_50 = 50 MHz this gives ~5 Hz on the GPU
//     -- slow enough to watch HEX displays change, fast enough that small
//     kernels finish in seconds.
// > AUTO_DIV is parameterized so cocotb tests can set it small (e.g. 4) without
//   waiting 10 million sim ticks per gpu_clk edge.
//
// Note: gating CLOCK_50 to derive a slower clock would normally trip Quartus's
// clock-domain warnings. We use a registered toggle (clk_out is a flip-flop on
// CLOCK_50) so the resulting "slow clock" is actually a divided clock from
// CLOCK_50, which Quartus will infer as a derived clock.
module clock_step #(
    parameter AUTO_DIV = 32'd10_000_000   // half-period in clk_in cycles
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
