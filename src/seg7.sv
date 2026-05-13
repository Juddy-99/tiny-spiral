`default_nettype none
`timescale 1ns/1ns

// SEVEN SEGMENT DISPLAY
// > Drives active-low DE1-SoC HEX display segments for hexadecimal digits
module seg7 (
    input wire [3:0] hex,
    output reg [6:0] leds
);
    always @(*) begin
        case (hex)
            4'h0: leds = 7'b1000000;
            4'h1: leds = 7'b1111001;
            4'h2: leds = 7'b0100100;
            4'h3: leds = 7'b0110000;
            4'h4: leds = 7'b0011001;
            4'h5: leds = 7'b0010010;
            4'h6: leds = 7'b0000010;
            4'h7: leds = 7'b1111000;
            4'h8: leds = 7'b0000000;
            4'h9: leds = 7'b0010000;
            4'hA: leds = 7'b0001000;
            4'hB: leds = 7'b0000011;
            4'hC: leds = 7'b1000110;
            4'hD: leds = 7'b0100001;
            4'hE: leds = 7'b0000110;
            4'hF: leds = 7'b0001110;
        endcase
    end
endmodule
