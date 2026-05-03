/*
This module verifies that I can read and write to the memory in simulation
*/
`timescale 1 ps / 1 ps
module task1_tb();
    logic [4:0] 	address;
	 logic 		   clock;
    logic [2:0] 	data;
    logic 		   wren;
    logic [2:0] 	q1;
	 logic [2:0]	q2;

    task1 dut1 (.*);
    task2 dut2 (.*);

    parameter T = 20;
    
    // define simulated clock
    initial begin
        clock <= 0;
        forever  #(T/2)  clock <= ~clock;
    end  // initial clock

    initial begin
        address <= 5'b00001; data <= 3'b001; wren <= 1'b1; @(posedge clock);
        address <= 5'b00001; data <= 3'b001; wren <= 1'b0; @(posedge clock);

        address <= 5'b00010; data <= 3'b011; wren <= 1'b1; @(posedge clock);
        address <= 5'b00001; data <= 3'b010; wren <= 1'b1; @(posedge clock);
        address <= 5'b00010; data <= 3'b001; wren <= 1'b0; @(posedge clock);
        address <= 5'b00001; data <= 3'b001; wren <= 1'b0; @(posedge clock);
        @(posedge clock);
        
        $stop;
    end
endmodule