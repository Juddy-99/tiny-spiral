/*
This module is a a general counter
*/
module counter #(parameter WIDTH = 32) (
    input  logic              clk,
    input  logic              reset, // Active high reset
    input  logic              en,    // Enable signal
    output logic [WIDTH-1:0]  count
);

    always_ff @(posedge clk) begin
        if (reset)
            count <= '0;         // Sets all bits to 0 regardless of WIDTH
        else if (en)
            count <= count + 1'b1;
    end

endmodule