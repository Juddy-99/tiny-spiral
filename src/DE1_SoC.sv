/* Top-level module for LabsLand hardware connections to run tiny-gpu matadd. */
`timescale 1ns/1ns

module DE1_SoC (CLOCK_50, SW, HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, LEDR, KEY);
    input  logic        CLOCK_50;
    input  logic [9:0]  SW;
    input  logic [3:0]  KEY;        // KEY3 = reset, KEY0 = manual device clock; both active low
    output logic [6:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
    output logic [9:0]  LEDR;

    localparam DATA_MEM_ADDR_BITS = 8;
    localparam DATA_MEM_DATA_BITS = 8;
    localparam DATA_MEM_NUM_CHANNELS = 4;
    localparam PROGRAM_MEM_ADDR_BITS = 8;
    localparam PROGRAM_MEM_DATA_BITS = 16;
    localparam PROGRAM_MEM_NUM_CHANNELS = 1;
    localparam NUM_CORES = 2;
    localparam THREADS_PER_BLOCK = 4;
    localparam [7:0] THREAD_COUNT = 8'd8;

    logic reset;
    assign reset = ~KEY[3];

    // Synchronize user inputs before using them in the 50 MHz clock domain.
    logic [9:0] sw_sync;
    logic [9:0] sw_temp;
    logic [3:0] key_sync;
    logic [3:0] key_temp;
    logic key0_was_high;
    logic key0_pressed;
    logic device_clk;
    logic manual_clk;
    logic step_pending;

    always_ff @(posedge CLOCK_50) begin
        if (reset) begin
            sw_temp <= 10'b0;
            sw_sync <= 10'b0;
            key_temp <= 4'hF;
            key_sync <= 4'hF;
            key0_was_high <= 1'b1;
            manual_clk <= 1'b0;
            step_pending <= 1'b0;
        end else begin
            sw_temp <= SW;
            sw_sync <= sw_temp;

            key_temp <= KEY;
            key_sync <= key_temp;
            key0_was_high <= key_sync[0];

            if (key0_pressed) begin
                step_pending <= 1'b1;
            end

            // Convert one synchronized negative edge into one full manual clock pulse.
            if (step_pending && !manual_clk) begin
                manual_clk <= 1'b1;
            end else if (manual_clk) begin
                manual_clk <= 1'b0;
                step_pending <= 1'b0;
            end
        end
    end

    assign key0_pressed = key0_was_high && !key_sync[0];
    assign device_clk = reset ? CLOCK_50 : manual_clk;

    // The first manual step writes the DCR; later steps hold start high and advance execution.
    logic configured;
    logic gpu_start;
    logic device_control_write_enable;
    logic [7:0] device_control_data;

    assign device_control_data = THREAD_COUNT;

    always_ff @(posedge CLOCK_50) begin
        if (reset) begin
            configured <= 1'b0;
            gpu_start <= 1'b0;
            device_control_write_enable <= 1'b0;
        end else begin
            if (key0_pressed && !step_pending && !manual_clk) begin
                if (!configured) begin
                    device_control_write_enable <= 1'b1;
                end else begin
                    gpu_start <= 1'b1;
                    device_control_write_enable <= 1'b0;
                end
            end else if (manual_clk) begin
                configured <= 1'b1;
                device_control_write_enable <= 1'b0;
            end
        end
    end

    logic gpu_done;

    logic [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_valid;
    logic [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_read_address [PROGRAM_MEM_NUM_CHANNELS-1:0];
    logic [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_read_ready;
    logic [PROGRAM_MEM_DATA_BITS-1:0] program_mem_read_data [PROGRAM_MEM_NUM_CHANNELS-1:0];

    logic [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_write_valid;
    logic [PROGRAM_MEM_ADDR_BITS-1:0] program_mem_write_address [PROGRAM_MEM_NUM_CHANNELS-1:0];
    logic [PROGRAM_MEM_DATA_BITS-1:0] program_mem_write_data [PROGRAM_MEM_NUM_CHANNELS-1:0];
    logic [PROGRAM_MEM_NUM_CHANNELS-1:0] program_mem_write_ready;

    logic [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_valid;
    logic [DATA_MEM_ADDR_BITS-1:0] data_mem_read_address [DATA_MEM_NUM_CHANNELS-1:0];
    logic [DATA_MEM_NUM_CHANNELS-1:0] data_mem_read_ready;
    logic [DATA_MEM_DATA_BITS-1:0] data_mem_read_data [DATA_MEM_NUM_CHANNELS-1:0];
    logic [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_valid;
    logic [DATA_MEM_ADDR_BITS-1:0] data_mem_write_address [DATA_MEM_NUM_CHANNELS-1:0];
    logic [DATA_MEM_DATA_BITS-1:0] data_mem_write_data [DATA_MEM_NUM_CHANNELS-1:0];
    logic [DATA_MEM_NUM_CHANNELS-1:0] data_mem_write_ready;

    logic [DATA_MEM_ADDR_BITS-1:0] debug_data_address;
    logic [DATA_MEM_DATA_BITS-1:0] debug_data;
    logic matadd_pass;

    always_comb begin
        program_mem_write_valid = '0;
        program_mem_write_address[0] = '0;
        program_mem_write_data[0] = '0;

        // SW9 switches between raw data-memory addresses and the C[0:7] result window.
        debug_data_address = sw_sync[9]
            ? (8'd16 + {5'b0, sw_sync[2:0]})
            : {3'b0, sw_sync[4:0]};
    end

    gpu #(
        .DATA_MEM_ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_MEM_DATA_BITS(DATA_MEM_DATA_BITS),
        .DATA_MEM_NUM_CHANNELS(DATA_MEM_NUM_CHANNELS),
        .PROGRAM_MEM_ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .PROGRAM_MEM_DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .PROGRAM_MEM_NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .NUM_CORES(NUM_CORES),
        .THREADS_PER_BLOCK(THREADS_PER_BLOCK)
    ) gpu_instance (
        .clk(device_clk),
        .reset(reset),
        .start(gpu_start),
        .done(gpu_done),
        .device_control_write_enable(device_control_write_enable),
        .device_control_data(device_control_data),
        .program_mem_read_valid(program_mem_read_valid),
        .program_mem_read_address(program_mem_read_address),
        .program_mem_read_ready(program_mem_read_ready),
        .program_mem_read_data(program_mem_read_data),
        .data_mem_read_valid(data_mem_read_valid),
        .data_mem_read_address(data_mem_read_address),
        .data_mem_read_ready(data_mem_read_ready),
        .data_mem_read_data(data_mem_read_data),
        .data_mem_write_valid(data_mem_write_valid),
        .data_mem_write_address(data_mem_write_address),
        .data_mem_write_data(data_mem_write_data),
        .data_mem_write_ready(data_mem_write_ready)
    );

    memory #(
        .ADDR_BITS(PROGRAM_MEM_ADDR_BITS),
        .DATA_BITS(PROGRAM_MEM_DATA_BITS),
        .NUM_CHANNELS(PROGRAM_MEM_NUM_CHANNELS),
        .WRITE_ENABLE(0),
        .INIT_IMAGE(1)
    ) program_memory_instance (
        .clk(device_clk),
        .reset(reset),
        .read_valid(program_mem_read_valid),
        .read_address(program_mem_read_address),
        .read_ready(program_mem_read_ready),
        .read_data(program_mem_read_data),
        .write_valid(program_mem_write_valid),
        .write_address(program_mem_write_address),
        .write_data(program_mem_write_data),
        .write_ready(program_mem_write_ready),
        .debug_read_address({PROGRAM_MEM_ADDR_BITS{1'b0}}),
        .debug_read_data(),
        .matadd_pass()
    );

    memory #(
        .ADDR_BITS(DATA_MEM_ADDR_BITS),
        .DATA_BITS(DATA_MEM_DATA_BITS),
        .NUM_CHANNELS(DATA_MEM_NUM_CHANNELS),
        .WRITE_ENABLE(1),
        .INIT_IMAGE(2)
    ) data_memory_instance (
        .clk(device_clk),
        .reset(reset),
        .read_valid(data_mem_read_valid),
        .read_address(data_mem_read_address),
        .read_ready(data_mem_read_ready),
        .read_data(data_mem_read_data),
        .write_valid(data_mem_write_valid),
        .write_address(data_mem_write_address),
        .write_data(data_mem_write_data),
        .write_ready(data_mem_write_ready),
        .debug_read_address(debug_data_address),
        .debug_read_data(debug_data),
        .matadd_pass(matadd_pass)
    );

    logic [15:0] cycle_count;
    always_ff @(posedge device_clk) begin
        if (reset || !gpu_start) begin
            cycle_count <= 16'b0;
        end else if (!gpu_done) begin
            cycle_count <= cycle_count + 16'b1;
        end
    end

    logic [3:0] h5_in, h4_in, h3_in, h2_in, h1_in, h0_in;

    always_comb begin
        h5_in = debug_data_address[7:4];
        h4_in = debug_data_address[3:0];
        h3_in = cycle_count[7:4];
        h2_in = cycle_count[3:0];
        h1_in = debug_data[7:4];
        h0_in = debug_data[3:0];
    end

    seg7 hex5 (.hex(h5_in), .leds(HEX5));
    seg7 hex4 (.hex(h4_in), .leds(HEX4));
    seg7 hex3 (.hex(h3_in), .leds(HEX3));
    seg7 hex2 (.hex(h2_in), .leds(HEX2));
    seg7 hex1 (.hex(h1_in), .leds(HEX1));
    seg7 hex0 (.hex(h0_in), .leds(HEX0));

    assign LEDR[7:0] = debug_data;
    assign LEDR[8] = gpu_done;
    assign LEDR[9] = matadd_pass;
endmodule  // DE1_SoC