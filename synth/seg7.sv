`default_nettype none
`timescale 1ns/1ns

// SEG7
// > 4-bit hex to 7-segment cathode driver for the DE1-SoC HEX displays.
// > Active-low cathodes (HEX0..HEX5 on DE1-SoC), so each segment is set to 0
//   when on and 1 when off.
// > Local copy under synth/ -- the lab2/ version is reference-only per the
//   `lab2-reference-only` Cursor rule.
//
// Bit layout per HEX display (DE1-SoC convention):
//   HEXn[6:0] = {g, f, e, d, c, b, a}
module seg7 (
    input  wire [3:0] nibble,
    output reg  [6:0] segs
);
    always @(*) begin
        case (nibble)
            4'h0: segs = 7'b1000000;
            4'h1: segs = 7'b1111001;
            4'h2: segs = 7'b0100100;
            4'h3: segs = 7'b0110000;
            4'h4: segs = 7'b0011001;
            4'h5: segs = 7'b0010010;
            4'h6: segs = 7'b0000010;
            4'h7: segs = 7'b1111000;
            4'h8: segs = 7'b0000000;
            4'h9: segs = 7'b0010000;
            4'hA: segs = 7'b0001000;
            4'hB: segs = 7'b0000011;
            4'hC: segs = 7'b1000110;
            4'hD: segs = 7'b0100001;
            4'hE: segs = 7'b0000110;
            4'hF: segs = 7'b0001110;
            default: segs = 7'b1111111;
        endcase
    end
endmodule
