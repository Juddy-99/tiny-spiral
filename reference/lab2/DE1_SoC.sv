/* Top-level module for LabsLand hardware connections to implement the task 2 and 3 memory.*/

module DE1_SoC (CLOCK_50, SW, HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, LEDR, KEY);
    input  logic        CLOCK_50;
    input  logic [9:0]  SW;
    input  logic [3:0]  KEY;        // KEY0 = clock input (active low)
    output logic [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    output logic [9:0]  LEDR;
    //inout  logic [35:0] V_GPIO;

    assign LEDR[8:3] = '0;

    assign reset = ~KEY[3];

    // Synchronize switches w/ two FFs in series
    logic [9:0] sw_sync;
    logic [9:0] sw_temp;
    always_ff @(posedge CLOCK_50) begin
        sw_temp <= SW;
        sw_sync <= sw_temp;
    end

    // Logic for 1-second interval
    logic [31:0] timer_count;
    logic tick;
    
    // Timer to count 50,000,000 cycles
    counter #(.WIDTH(32)) timer (
        .clk(CLOCK_50),
        .reset(reset || tick),
        .en(1'b1),
        .count(timer_count)
    );
    
    // Create a tick pulse when timer hits 50M (requires timer reset)
    assign tick = (timer_count == 32'd50_000_000);

    // Read address counter (Task 3)
    logic [4:0] read_addr_t3;
    counter #(.WIDTH(5)) addr_counter (
        .clk(CLOCK_50),
        .reset(reset), // Reset on KEY3 or when timer finishes
        .en(tick),
        .count(read_addr_t3)
    );

    // Task 2: Multidimensional Array
    logic [2:0] q_t2;
    task2 t2_mem (
        .clock   (~KEY[0]), 
        .address (sw_sync[8:4]),
        .data    (sw_sync[3:1]),
        .wren    (sw_sync[0]),
        .q2      (q_t2)
    );

    // Task 3: Dual-Port Library RAM (M10K)
    logic [2:0] q_t3;
    ram32x3port2 t3_mem (
        .clock     (CLOCK_50),
        .data      (sw_sync[3:1]),   // Write Data
        .rdaddress (read_addr_t3),    // Read Address (from counter)
        .wraddress (sw_sync[8:4]),   // Write Address (from switches)
        .wren      (sw_sync[0]),
        .q         (q_t3)
    );
    
    // Logic to choose what hex values go to which display based on SW9
    logic [3:0] h5_in, h4_in, h3_in, h2_in, h1_in, h0_in;
    
    always_comb begin
        if (sw_sync[9]) begin // Task 3
            h5_in = {3'b000, sw_sync[8]}; // Write Addr High
            h4_in = sw_sync[7:4];        // Write Addr Low
            h3_in = {3'b000, read_addr_t3[4]}; // Read Addr High
            h2_in = read_addr_t3[3:0];        // Read Addr Low
            h1_in = {1'b0, sw_sync[3:1]}; // Write Data
            h0_in = {1'b0, q_t3};         // Read Data
        end else begin        // Task 2
            h5_in = {3'b000, sw_sync[8]}; // Addr High
            h4_in = sw_sync[7:4];        // Addr Low
            h3_in = 4'hF;                 // blank
            h2_in = 4'hF;                 // blank
            h1_in = {1'b0, sw_sync[3:1]}; // Data In
            h0_in = {1'b0, q_t2};         // Data Out
        end
    end

    // Drive the HEX displays
    seg7 hex5 (.hex(h5_in), .leds(HEX5));
    seg7 hex4 (.hex(h4_in), .leds(HEX4));
    
    // Simple conditional: if Task 2, turn HEX3/2 off, else show addr
    logic [6:0] h3_out, h2_out;
    seg7 hex3 (.hex(h3_in), .leds(h3_out));
    seg7 hex2 (.hex(h2_in), .leds(h2_out));

    seg7 hex1 (.hex(h1_in), .leds(HEX1));
    seg7 hex0 (.hex(h0_in), .leds(HEX0));
	 
	assign HEX3 = (sw_sync[9]) ? h3_out : 7'b1111111;
    assign HEX2 = (sw_sync[9]) ? h2_out : 7'b1111111;

endmodule  // DE1_SoC