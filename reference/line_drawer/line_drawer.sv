/* Given two points on the screen this module draws a line between
 * those two points by coloring necessary pixels
 *
 * Inputs:
 *   clk    - should be connected to a 50 MHz clock
 *   reset  - resets the module and starts over the drawing process
 *	 x0 	- x coordinate of the first end point
 *   y0 	- y coordinate of the first end point
 *   x1 	- x coordinate of the second end point
 *   y1 	- y coordinate of the second end point
 *
 * Outputs:
 *   x 		- x coordinate of the pixel to color
 *   y 		- y coordinate of the pixel to color
 *   done	- flag that line has finished drawing
 *
 */
module line_drawer(clk, reset, x0, y0, x1, y1, x, y, done);
	input logic clk, reset;
	input logic [10:0]	x0, y0, x1, y1;
	output logic done;
	output logic [10:0]	x, y;
	
	/* You'll need to create some registers to keep track of things
	 * such as error and direction.
	 */
	logic signed [11:0] error;  // example - feel free to change/delete
	logic [10:0]	x0_swap, y0_swap, x1_swap, y1_swap;
	logic [10:0]	x0_new, y0_new, x1_new, y1_new;
	logic [10:0]	x_current, x_next;
	logic signed [11:0] y_current, y_next;
	logic signed [11:0] error_next;
	logic is_steep;
	logic [10:0] dx, dy;
	logic signed [10:0] y_step;
	logic draw_done;

	typedef enum logic [1:0] {INIT, DRAW, DONE} state_t;
	state_t ps, ns;

	// Setup: steep swap, left-to-right normalization, deltax/deltay/y_step
	always_comb begin
		is_steep = ((x1 >= x0) ? (x1 - x0) : (x0 - x1))
		         < ((y1 >= y0) ? (y1 - y0) : (y0 - y1));
		if (is_steep) begin
			x0_swap = y0;
			y0_swap = x0;
			x1_swap = y1;
			y1_swap = x1;
		end else begin
			x0_swap = x0;
			y0_swap = y0;
			x1_swap = x1;
			y1_swap = y1;
		end

		if (x0_swap > x1_swap) begin
			x0_new = x1_swap;
			y0_new = y1_swap;
			x1_new = x0_swap;
			y1_new = y0_swap;
		end else begin
			x0_new = x0_swap;
			y0_new = y0_swap;
			x1_new = x1_swap;
			y1_new = y1_swap;
		end

		dx = x1_new - x0_new;
		dy = (y1_new >= y0_new) ? (y1_new - y0_new) : (y0_new - y1_new);
		y_step = (y0_new < y1_new) ? 11'sd1 : -11'sd1;

		draw_done = (x_current == x1_new);
	end

	// Draw logic
	always_comb begin
		x_next = x_current;
		y_next = y_current;
		error_next = error;

		if (ps == DRAW && !draw_done) begin
			error_next = error + $signed({1'b0, dy});
			y_next = y_current;
			if (error_next >= 0) begin
				y_next = y_current + $signed(y_step);
				error_next = error_next - $signed({1'b0, dx});
			end
			x_next = x_current + 11'd1;
		end
	end

	// FSM next state
	always_comb begin
		ns = ps;
		unique case (ps)
			INIT: ns = DRAW;
			DRAW: ns = draw_done ? DONE : DRAW;
			DONE: ns = DONE;
			default: ns = INIT;
		endcase
	end

	// FSM state registers
	always_ff @(posedge clk) begin
		if (reset) begin
			ps <= INIT;
			x_current <= '0;
			y_current <= '0;
			error <= '0;
			done <= 1'b0;
		end else begin
			ps <= ns;
			case (ps)
				INIT: begin
					x_current <= x0_new;
					y_current <= $signed({1'b0, y0_new});
					error <= -($signed({1'b0, dx}) >>> 1);
					done <= 1'b0;
				end
				DRAW: begin
					if (draw_done) begin
						done <= 1'b1;
					end else begin
						x_current <= x_next;
						y_current <= y_next;
						error <= error_next;
					end
				end
				DONE: begin
					done <= 1'b1;
				end
				default: ;
			endcase
		end
	end

	// Map algorithm coords to screen; if steep, draw_pixel(y, x)
	logic [10:0] y_out;
	assign y_out = (y_current < 0) ? 11'd0
	             : ((y_current > 11'd479) ? 11'd479 : y_current[10:0]);
	assign x = is_steep ? y_out : x_current;
	assign y = is_steep ? x_current : y_out;

endmodule  // line_drawer
