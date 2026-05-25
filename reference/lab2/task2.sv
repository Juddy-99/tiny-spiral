/*
This module completes task 2 by providing the necessary functionality as Task 1 but using a 
multidimensional array.
*/
`timescale 1 ps / 1 ps
module task2 (
    input logic [4:0] 	address,
	input logic 		clock,
	input logic [2:0] 	data,
	input logic 		wren,
	output logic [2:0] 	q1
);

    logic [2:0] memory_array [31:0];

    always_ff @(posedge clock) begin
        if (wren)
            memory_array[address] <= data; 
    end

    assign q1 = memory_array[address];

endmodule