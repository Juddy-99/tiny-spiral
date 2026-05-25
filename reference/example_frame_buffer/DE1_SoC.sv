/* Top level module of the FPGA that takes the onboard resources 
 * as input and outputs the lines drawn from the VGA port.
 *
 * Inputs:
 *   KEY 			- On board keys of the FPGA
 *   SW 			- On board switches of the FPGA
 *   CLOCK_50 		- On board 50 MHz clock of the FPGA
 *
 * Outputs:
 *   HEX 			- On board 7 segment displays of the FPGA
 *   LEDR 			- On board LEDs of the FPGA
 *   VGA_R 			- Red data of the VGA connection
 *   VGA_G 			- Green data of the VGA connection
 *   VGA_B 			- Blue data of the VGA connection
 *   VGA_BLANK_N 	- Blanking interval of the VGA connection
 *   VGA_CLK 		- VGA's clock signal
 *   VGA_HS 		- Horizontal Sync of the VGA connection
 *   VGA_SYNC_N 	- Enable signal for the sync of the VGA connection
 *   VGA_VS 		- Vertical Sync of the VGA connection
 */
module DE1_SoC (HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, KEY, LEDR, SW, CLOCK_50, 
	VGA_R, VGA_G, VGA_B, VGA_BLANK_N, VGA_CLK, VGA_HS, VGA_SYNC_N, VGA_VS);
	
	output logic [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5;
	output logic [9:0] LEDR;
	input logic [3:0] KEY;
	input logic [9:0] SW;
	input CLOCK_50;
	output [7:0] VGA_R;
	output [7:0] VGA_G;
	output [7:0] VGA_B;
	output VGA_BLANK_N;
	output VGA_CLK;
	output VGA_HS;
	output VGA_SYNC_N;
	output VGA_VS;
	
	assign HEX0 = '1;
	assign HEX1 = '1;
	assign HEX2 = '1;
	assign HEX3 = '1;
	assign HEX4 = '1;
	assign HEX5 = '1;
	assign LEDR[5:0] = SW[5:0];
	
	logic [10:0] x0, y0, x1, y1, x, y;

	// ------ My additions ------
	// KEY[0] active-low: hold = sweep screen black; release = restart animation
	logic key_hold, key_hold_prev, key_press, key_release;
	assign key_hold = ~KEY[0];
	assign key_press = key_hold & ~key_hold_prev;
	assign key_release = key_hold_prev & ~key_hold;

	logic obj_done;
	// Pac-Man: 3 straights (top, left, bottom) + 4 corner/cheek diagonals + 2 mouth diagonals
	// Ghost: left + 5 top segments + right + 8 bottom scallops
	localparam int NumLines = 27;
	localparam logic [4:0] LastLine = NumLines - 1;
	localparam int NumBurst = 16;
	localparam logic [4:0] BurstLast = NumBurst - 1;
	localparam logic signed [11:0] BurstR = 12'sd90;
	logic [7:0] line_i;

	// Mouth: 10 frames open -> 10 closed -> 10 closed (hold) -> repeat
	localparam logic [4:0] MouthFrames = 5'd10;
	localparam logic [4:0] MouthLast   = 3 * MouthFrames - 1;  // 29
	logic [4:0] mouth_cnt;
	logic       mouth_open;
	assign mouth_open = (mouth_cnt < MouthFrames);

	typedef enum logic [1:0] {CLEAR, DRAW, WAIT} state_t;
	state_t ps, ns;

	localparam logic [25:0] WaitCycles = 26'd1_000_000;  // ~.02 s at 50 MHz
	logic [25:0] wait_cnt;

	logic pixel_color;
	logic pixel_write;
	logic [10:0] clear_x;
	logic [10:0] clear_y;
	logic line_reset;
	logic [1:0] line_reset_cnt;
	logic done;
	logic done_q;
	logic done_rise;
	logic [10:0] line_drawer_x;
	logic [10:0] line_drawer_y;
	logic [10:0] x_off;
	localparam logic [10:0] MoveStep     = 11'd2;
	localparam logic [10:0] PacLeftBase  = 11'd145;
	localparam logic [10:0] PacRightBase = 11'd210;
	localparam logic [10:0] PacTopBase   = 11'd200;
	localparam logic [10:0] PacBotBase   = 11'd270;
	localparam logic [10:0] PacCenterBase = (PacLeftBase + PacRightBase) >> 1;  // 177
	localparam logic [10:0] PacCenterY  = (PacTopBase + PacBotBase) >> 1;      // 235
	localparam logic [10:0] GhostLeft    = 11'd400;
	localparam logic [10:0] GhostRight   = 11'd435;
	localparam logic [10:0] GhostTop     = 11'd205;
	localparam logic [10:0] GhostBot     = 11'd250;
	localparam logic [10:0] MaxXOff      = GhostLeft - PacRightBase;  // 190

	logic [10:0] pac_left;
	logic [10:0] pac_right;
	logic        ghost_touch;
	logic [10:0] touch_x;
	logic [10:0] touch_y;
	logic [10:0] ovl_x_lo;
	logic [10:0] ovl_x_hi;
	logic [10:0] ovl_y_lo;
	logic [10:0] ovl_y_hi;
	logic signed [12:0] burst_end_x;
	logic signed [12:0] burst_end_y;
	localparam logic [7:0] SpriteLast = {3'b0, LastLine};
	localparam logic [7:0] BurstBase   = SpriteLast + 8'd1;
	logic [7:0] draw_last;

	assign pac_left  = PacLeftBase + x_off;
	assign pac_right = PacRightBase + x_off;
	assign ghost_touch = (pac_right >= GhostLeft) && (pac_left <= GhostRight)
		&& (PacBotBase >= GhostTop) && (PacTopBase <= GhostBot);

	always_comb begin
		ovl_x_lo = (pac_left > GhostLeft) ? pac_left : GhostLeft;
		ovl_x_hi = (pac_right < GhostRight) ? pac_right : GhostRight;
		touch_x = (ovl_x_lo + ovl_x_hi) >> 1;
		ovl_y_lo = (PacTopBase > GhostTop) ? PacTopBase : GhostTop;
		ovl_y_hi = (PacBotBase < GhostBot) ? PacBotBase : GhostBot;
		touch_y = (ovl_y_lo + ovl_y_hi) >> 1;
	end

	// Radial burst: 16 spokes every 22.5 deg from touch center (ghost_touch only)

	// Food: 10x10 dots via line_drawer (3 pellets x 10 horizontal lines), same DRAW path as Pac-Man
	localparam int NumFood = 3;
	localparam int NumFoodLines = NumFood * 10;
	localparam logic [7:0] FoodLinesLast = NumFoodLines - 1;
	localparam logic [10:0] FoodHalf = 11'd5;
	// Centers at 1/4, 2/4, 3/4 along Pac center travel (177 .. 367)
	localparam logic [10:0] Food0CX = PacCenterBase + (MaxXOff >> 2);              // 224
	localparam logic [10:0] Food1CX = PacCenterBase + (MaxXOff >> 1);              // 272
	localparam logic [10:0] Food2CX = PacCenterBase + MaxXOff - (MaxXOff >> 2);    // 320
	// Eat when Pac-Man right edge (210+x_off) reaches food left edge (FoodCX-5)
	localparam logic [10:0] Food0EatXOff = Food0CX - PacRightBase - FoodHalf;      // 9
	localparam logic [10:0] Food1EatXOff = Food1CX - PacRightBase - FoodHalf;      // 57
	localparam logic [10:0] Food2EatXOff = Food2CX - PacRightBase - FoodHalf;      // 105

	logic [2:0] food_eaten;
	logic [7:0] food_base;
	logic [7:0] food_line_local;
	logic [1:0] food_sel;
	logic [3:0] food_row;
	logic [10:0] food_cx;
	logic       draw_food;
	logic [10:0] x_off_next;
	logic       lines_done;
	logic       skip_line;

	assign x_off_next = (x_off < MaxXOff) ? (x_off + MoveStep) : x_off;
	assign done_rise = done & ~done_q;
	assign food_base = SpriteLast + 8'd1
		+ (ghost_touch ? (BurstLast + 8'd1) : 8'd0);
	assign draw_food = (line_i >= food_base);
	assign food_line_local = line_i - food_base;
	assign food_sel = (food_line_local < 8'd10) ? 2'd0 :
	                  (food_line_local < 8'd20) ? 2'd1 : 2'd2;
	assign food_row = (food_line_local < 8'd10) ? food_line_local[3:0] :
	                  (food_line_local < 8'd20) ? 4'(food_line_local - 8'd10) :
	                  4'(food_line_local - 8'd20);
	assign food_cx = (food_sel == 2'd0) ? Food0CX :
	                 (food_sel == 2'd1) ? Food1CX : Food2CX;
	assign draw_last = food_base + FoodLinesLast;
	assign lines_done = (ps == DRAW) && done_rise && (line_i == draw_last)
		&& (line_reset_cnt == 2'd0);

	always_comb begin
		case (ps)
			CLEAR: begin
				if (!key_hold && clear_x == 11'd639 && clear_y == 11'd479) begin
					ns = DRAW;
				end else begin
					ns = CLEAR;
				end
				x = clear_x;
				y = clear_y;
				pixel_color = 1'b0;
				pixel_write = 1'b1;
			end
			DRAW: begin
				x = line_drawer_x;
				y = line_drawer_y;
				pixel_color = 1'b1;
				pixel_write = !skip_line;
				ns = DRAW;
			end
			WAIT: begin
				if (wait_cnt >= WaitCycles)
					ns = CLEAR;
				else
					ns = WAIT;
				x = '0;
				y = '0;
				pixel_color = 1'b0;
				pixel_write = 1'b0;
			end
			default: begin
				ns = CLEAR;
				x = '0;
				y = '0;
				pixel_color = 1'b0;
				pixel_write = 1'b0;
			end
		endcase
	end

	// Body walks CCW: top -> TL diag -> left -> BL diag -> bottom -> cheek diags; mouth opens right
	// Lines 7-8: open mouth (cheek -> center). Line 9: closed mouth (vertical right edge).
	logic [3:0] spoke;
	logic signed [11:0] bdx, bdy;

	always_comb begin
		skip_line = ghost_touch && (line_i <= SpriteLast);
		x0 = '0;
		y0 = '0;
		x1 = '0;
		y1 = '0;
		burst_end_x = '0;
		burst_end_y = '0;
		bdx = '0;
		bdy = '0;
		spoke = 4'd0;

		if (ghost_touch && (line_i > SpriteLast) && (line_i < food_base)) begin
			x0 = touch_x;
			y0 = touch_y;
			spoke = line_i - BurstBase;
			unique case (spoke)
				4'd0:  begin bdx = BurstR;  bdy = 12'sd0;   end
				4'd1:  begin bdx = 12'sd83;  bdy = 12'sd34;  end
				4'd2:  begin bdx = 12'sd64;  bdy = 12'sd64;  end
				4'd3:  begin bdx = 12'sd34;  bdy = 12'sd83;  end
				4'd4:  begin bdx = 12'sd0;   bdy = BurstR;   end
				4'd5:  begin bdx = -12'sd34; bdy = 12'sd83;  end
				4'd6:  begin bdx = -12'sd64; bdy = 12'sd64;  end
				4'd7:  begin bdx = -12'sd83; bdy = 12'sd34;  end
				4'd8:  begin bdx = -BurstR;  bdy = 12'sd0;   end
				4'd9:  begin bdx = -12'sd83; bdy = -12'sd34; end
				4'd10: begin bdx = -12'sd64; bdy = -12'sd64; end
				4'd11: begin bdx = -12'sd34; bdy = -12'sd83; end
				4'd12: begin bdx = 12'sd0;   bdy = -BurstR;  end
				4'd13: begin bdx = 12'sd34;  bdy = -12'sd83; end
				4'd14: begin bdx = 12'sd64;  bdy = -12'sd64; end
				4'd15: begin bdx = 12'sd83;  bdy = -12'sd34; end
				default: begin bdx = '0; bdy = '0; end
			endcase
			burst_end_x = $signed({1'b0, touch_x}) + bdx;
			burst_end_y = $signed({1'b0, touch_y}) + bdy;
			if (burst_end_x < 0)
				x1 = 11'd0;
			else if (burst_end_x > 12'sd639)
				x1 = 11'd639;
			else
				x1 = burst_end_x[10:0];
			if (burst_end_y < 0)
				y1 = 11'd0;
			else if (burst_end_y > 12'sd479)
				y1 = 11'd479;
			else
				y1 = burst_end_y[10:0];
		end else if (draw_food) begin
			skip_line = food_eaten[food_sel];
			x0 = food_cx - FoodHalf;
			x1 = food_cx + FoodHalf - 11'd1;
			y0 = PacCenterY - FoodHalf + {7'b0, food_row};
			y1 = y0;
		end else begin
		unique case (line_i[4:0])
			// ----- Pac-Man -----
			4'd0: begin  // straight: top
				x0 = 11'd165 + x_off; y0 = 11'd200;
				x1 = 11'd200 + x_off; y1 = 11'd200;
			end
			4'd1: begin  // diagonal: top-left corner
				x0 = 11'd165 + x_off; y0 = 11'd200;
				x1 = 11'd145 + x_off; y1 = 11'd220;
			end
			4'd2: begin  // straight: left side
				x0 = 11'd145 + x_off; y0 = 11'd220;
				x1 = 11'd145 + x_off; y1 = 11'd250;
			end
			4'd3: begin  // diagonal: bottom-left corner
				x0 = 11'd145 + x_off; y0 = 11'd250;
				x1 = 11'd165 + x_off; y1 = 11'd270;
			end
			4'd4: begin  // straight: bottom
				x0 = 11'd165 + x_off; y0 = 11'd270;
				x1 = 11'd200 + x_off; y1 = 11'd270;
			end
			4'd5: begin  // diagonal: bottom-right side
				x0 = 11'd200 + x_off; y0 = 11'd270;
				x1 = 11'd210 + x_off; y1 = 11'd260;
			end
			4'd6: begin  // diagonal: top-right side
				x0 = 11'd200 + x_off; y0 = 11'd200;
				x1 = 11'd210 + x_off; y1 = 11'd210;
			end
			4'd7: begin  // open: lower cheek (210,260) -> mouth center (170,235)
				skip_line = skip_line || !mouth_open;
				x0 = 11'd210 + x_off; y0 = 11'd260;
				x1 = 11'd170 + x_off; y1 = 11'd235;
			end
			4'd8: begin  // open: upper cheek (210,210) -> mouth center (170,235)
				skip_line = skip_line || !mouth_open;
				x0 = 11'd210 + x_off; y0 = 11'd210;
				x1 = 11'd170 + x_off; y1 = 11'd235;
			end
			4'd9: begin  // closed: vertical right edge (210,260) -> (210,210)
				skip_line = skip_line || mouth_open;
				x0 = 11'd210 + x_off; y0 = 11'd260;
				x1 = 11'd210 + x_off; y1 = 11'd210;
			end

			// ----- Ghost -----
			5'd10: begin  // straight: left side
				x0 = 11'd400; y0 = 11'd220;
				x1 = 11'd400; y1 = 11'd250;
			end
			5'd11: begin  // diagonal: top-left1
				x0 = 11'd400; y0 = 11'd220;
				x1 = 11'd405; y1 = 11'd210;
			end
			5'd12: begin  // diagonal: top-left2
				x0 = 11'd405; y0 = 11'd210;
				x1 = 11'd415; y1 = 11'd205;
			end
			5'd13: begin  // straight: top
				x0 = 11'd415; y0 = 11'd205;
				x1 = 11'd420; y1 = 11'd205;
			end
			5'd14: begin  // diagonal: top-right2
				x0 = 11'd420; y0 = 11'd205;
				x1 = 11'd430; y1 = 11'd210;
			end
			5'd15: begin  // diagonal: top-right1
				x0 = 11'd430; y0 = 11'd210;
				x1 = 11'd435; y1 = 11'd220;
			end
			5'd16: begin  // straight: right side
				x0 = 11'd435; y0 = 11'd220;
				x1 = 11'd435; y1 = 11'd250;
			end
			// bottom: (435,250) -> (400,250); dx = 4,5,4,5,4,5,4,4 (sum 35)
			5'd17: begin
				x0 = 11'd435; y0 = 11'd250;
				x1 = 11'd431; y1 = 11'd245;
			end
			5'd18: begin
				x0 = 11'd431; y0 = 11'd245;
				x1 = 11'd426; y1 = 11'd250;
			end
			5'd19: begin
				x0 = 11'd426; y0 = 11'd250;
				x1 = 11'd422; y1 = 11'd245;
			end
			5'd20: begin
				x0 = 11'd422; y0 = 11'd245;
				x1 = 11'd417; y1 = 11'd250;
			end
			5'd21: begin
				x0 = 11'd417; y0 = 11'd250;
				x1 = 11'd413; y1 = 11'd245;
			end
			5'd22: begin
				x0 = 11'd413; y0 = 11'd245;
				x1 = 11'd408; y1 = 11'd250;
			end
			5'd23: begin
				x0 = 11'd408; y0 = 11'd250;
				x1 = 11'd404; y1 = 11'd245;
			end
			5'd24: begin
				x0 = 11'd404; y0 = 11'd245;
				x1 = 11'd400; y1 = 11'd250;
			end
			// left eye
			5'd25: begin
				x0 = 11'd410; y0 = 11'd230;
				x1 = 11'd410; y1 = 11'd240;
			end
			// right eye
			5'd26: begin
				x0 = 11'd420; y0 = 11'd230;
				x1 = 11'd420; y1 = 11'd240;
			end

			default: begin x0 = '0; y0 = '0; x1 = '0; y1 = '0; end
		endcase
		end
	end

	// FSM and clear counter
	// Keep line_drawer idle except during DRAW (avoids stray coords on other states)
	wire line_drawer_hold = (ps != DRAW) || key_hold;

	always_ff @(posedge CLOCK_50) begin
		key_hold_prev <= key_hold;
		done_q <= done;
		line_reset <= line_drawer_hold;
		if (line_reset_cnt != 2'd0 && !line_drawer_hold) begin
			line_reset <= 1'b1;
			line_reset_cnt <= line_reset_cnt - 2'd1;
		end

		if (key_hold) begin
			ps <= CLEAR;
			if (key_press) begin
				clear_x <= '0;
				clear_y <= '0;
			end else if (clear_x == 11'd639 && clear_y == 11'd479) begin
				clear_x <= clear_x;
				clear_y <= clear_y;
			end else if (clear_x == 11'd639) begin
				clear_x <= '0;
				clear_y <= clear_y + 11'd1;
			end else begin
				clear_x <= clear_x + 11'd1;
			end
		end else if (key_release) begin
			ps <= CLEAR;
			line_i <= '0;
			clear_x <= '0;
			clear_y <= '0;
			wait_cnt <= '0;
			line_reset_cnt <= '0;
			x_off <= '0;
			mouth_cnt <= '0;
			food_eaten <= '0;
			done_q <= 1'b0;
		end else if (lines_done) begin
			ps <= WAIT;
			line_i <= '0;
			wait_cnt <= '0;
			line_reset_cnt <= '0;
			if (mouth_cnt == MouthLast)
				mouth_cnt <= '0;
			else
				mouth_cnt <= mouth_cnt + 5'd1;
		end else begin
			ps <= ns;

			if (ps == WAIT)
				wait_cnt <= wait_cnt + 26'd1;

			if (ns == CLEAR && ps == WAIT) begin
				clear_x <= '0;
				clear_y <= '0;
				wait_cnt <= '0;
				if (x_off < MaxXOff)
					x_off <= x_off + MoveStep;
				if (x_off_next >= Food0EatXOff)
					food_eaten[0] <= 1'b1;
				if (x_off_next >= Food1EatXOff)
					food_eaten[1] <= 1'b1;
				if (x_off_next >= Food2EatXOff)
					food_eaten[2] <= 1'b1;
			end

			if (ps == CLEAR) begin
				if (clear_x == 11'd639 && clear_y == 11'd479) begin
					clear_x <= clear_x;
					clear_y <= clear_y;
				end else if (clear_x == 11'd639) begin
					clear_x <= '0;
					clear_y <= clear_y + 11'd1;
				end else begin
					clear_x <= clear_x + 11'd1;
				end
			end

			if (ns == DRAW && ps == CLEAR)
				line_reset_cnt <= 2'd2;

			if (ps == DRAW && line_reset_cnt == 2'd0) begin
				if (skip_line && line_i < draw_last) begin
					line_i <= line_i + 1'b1;
					line_reset_cnt <= 2'd2;
				end else if (done_rise && line_i < draw_last) begin
					line_i <= line_i + 1'b1;
					line_reset_cnt <= 2'd2;
				end
			end
		end
	end

	// ------------------------
	
	VGA_framebuffer fb (
		.clk50			(CLOCK_50), 
		.reset			(1'b0), 
		.x(x), 
		.y(y),
		.pixel_color	(pixel_color), 
		.pixel_write	(pixel_write),
		.VGA_R, 
		.VGA_G, 
		.VGA_B, 
		.VGA_CLK, 
		.VGA_HS, 
		.VGA_VS,
		.VGA_BLANK_n	(VGA_BLANK_N), 
		.VGA_SYNC_n		(VGA_SYNC_N));
				
	line_drawer lines (.clk(CLOCK_50), .reset(line_reset), .x0, .y0, .x1, .y1,
		.x(line_drawer_x), .y(line_drawer_y), .done);

	assign LEDR[9] = done;
	assign LEDR[8:7] = ps;  // debug: 0=CLEAR, 1=DRAW, 2=WAIT
	assign LEDR[6] = ghost_touch;

endmodule  // DE1_SoC
