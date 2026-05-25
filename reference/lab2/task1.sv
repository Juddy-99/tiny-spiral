/*
This module completes task 1 by instantiating the ram32x3 module.
*/
`timescale 1 ps / 1 ps
module task1(
	input logic [4:0] 	address,
	input logic 		clock,
	input logic [2:0] 	data,
	input logic 		wren,
	output logic [2:0] 	q1
);	

	logic [2:0] q;
	ram32x3 mem (.*);
	
	assign q1 = q;
	
endmodule