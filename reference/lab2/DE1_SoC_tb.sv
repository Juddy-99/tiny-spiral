/* testbench for the DE1_SoC */
`timescale 1 ps / 1 ps
module DE1_SoC_tb();

  // define signals
  logic       CLOCK_50;
  logic [9:0]  SW;
  logic [3:0]  KEY;
  logic [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
  logic [9:0] LEDR;
  wire [35:0] V_GPIO;
  
  DE1_SoC dut (.*);
  
  // define simulated clock
  parameter T = 20;
  initial begin
		CLOCK_50 <= 0;
		forever  #(T/2)  CLOCK_50 <= ~CLOCK_50;
  end  // initial clock

  
  initial begin
		// Reset
		KEY[3] <= 0; repeat(2) @(posedge CLOCK_50); // Reset Pulse
		KEY[3] <= 1; repeat(2) @(posedge CLOCK_50);

		// Test Task 2 (SW9 = 0)
		SW[9] <= 0; SW[8:4] <= 5'b00001; SW[3:1] <= 3'b101; SW[0] <= 1;
		repeat(3) @(posedge CLOCK_50); // Wait for sync

		KEY[0] <= 0; @(posedge CLOCK_50); // Pulse KEY0 (The Task 2 Clock)
		KEY[0] <= 1; @(posedge CLOCK_50);

		SW[0] <= 0; repeat(3) @(posedge CLOCK_50); // Read check

		// Test Task 3 (SW9 = 1)
		SW[9] <= 1; SW[8:4] <= 5'b00010; SW[3:1] <= 3'b011; SW[0] <= 1;
		repeat(3) @(posedge CLOCK_50); // Task 3 writes on CLOCK_50, just need sync

		SW[0] <= 0; repeat(3) @(posedge CLOCK_50);

		$stop;

	end 
  
endmodule  // DE1_SoC_tb
