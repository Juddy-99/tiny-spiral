"""Generate `synth/kernel_memories.sv` from a chosen cocotb test module.

The output file inlines the chosen kernel's `program` (instruction ROM) and
`data` (data RAM initial contents) lists into two SystemVerilog modules:
  - `program_rom` (256 x 16, async read, content set via `initial` block)
  - `data_ram`   (256 x 8, async read + sync write, content set via `initial`)

These modules are pin-compatible with `synth/sim_program_rom.sv` and
`synth/sim_data_ram.sv` (same port lists, no backdoor) so the synth top can
swap them in without rewiring.

Usage:
  make synth_kernel KERNEL=test_diverge_ifelse
  -- or --
  python3 -m test.helpers.synth_init test_diverge_ifelse

We pull the lists out via Python's `ast` module rather than executing the
test, so we don't need a working cocotb VPI environment to regenerate the
memory file.
"""
from __future__ import annotations

import ast
import os
import sys
import textwrap
from pathlib import Path
from typing import List

REPO_ROOT = Path(__file__).resolve().parents[2]
TEST_DIR = REPO_ROOT / "test"
SYNTH_OUT = REPO_ROOT / "synth" / "kernel_memories.sv"

# Synth top (`de1_soc`) wires `data_ram` with this many channels; unrolled writes
# in the generated SV must match.
DATA_RAM_NUM_CHANNELS = 4


def _eval_int_literal(node: ast.AST) -> int:
    """Evaluate an int literal expression (handles 0b/0x/decimal and unary ops)."""
    if isinstance(node, ast.Constant) and isinstance(node.value, int):
        return node.value
    if isinstance(node, ast.UnaryOp) and isinstance(node.op, ast.USub):
        return -_eval_int_literal(node.operand)
    raise ValueError(f"Unsupported list element {ast.dump(node)} (only int literals allowed)")


def _eval_list(node: ast.AST) -> List[int]:
    """Evaluate `[int, ...]` or `[int, ...] * N` -> list[int]. Supports the two
    shapes used across our cocotb tests; extend if a future test needs more."""
    if isinstance(node, ast.List):
        return [_eval_int_literal(elt) for elt in node.elts]
    if isinstance(node, ast.BinOp) and isinstance(node.op, ast.Mult):
        # [x] * N or N * [x]
        if isinstance(node.left, ast.List) and isinstance(node.right, ast.Constant):
            return _eval_list(node.left) * int(node.right.value)
        if isinstance(node.right, ast.List) and isinstance(node.left, ast.Constant):
            return _eval_list(node.right) * int(node.left.value)
    raise ValueError(f"Unsupported list expression: {ast.dump(node)}")


def _find_list_assignment(tree: ast.AST, name: str) -> List[int]:
    """Walk the AST looking for `name = [int, int, ...]` (or `[x] * N`) anywhere
    in the module. Returns the first match. Raises if not found."""
    for node in ast.walk(tree):
        if isinstance(node, ast.Assign) and len(node.targets) == 1:
            target = node.targets[0]
            if isinstance(target, ast.Name) and target.id == name:
                return _eval_list(node.value)
    raise ValueError(f"`{name} = [...]` not found in module")


def extract_kernel(test_name: str) -> tuple[List[int], List[int]]:
    test_path = TEST_DIR / f"{test_name}.py"
    if not test_path.exists():
        raise FileNotFoundError(f"No such test: {test_path}")
    tree = ast.parse(test_path.read_text())
    program = _find_list_assignment(tree, "program")
    data = _find_list_assignment(tree, "data")
    return program, data


def _emit_init_block(name: str, values: List[int], pad_to: int, width: int) -> str:
    """Emit `initial begin mem[i] = W'h..; ... end` covering all 256 slots so
    Quartus infers a complete ROM/RAM array (unset entries default to 0)."""
    lines: List[str] = ["    initial begin"]
    for addr in range(pad_to):
        val = values[addr] if addr < len(values) else 0
        lines.append(f"        mem[{addr:>3}] = {width}'h{val:0{width // 4}x};")
    lines.append("    end")
    return "\n".join(lines)


def _emit_unrolled_data_writes(num_channels: int) -> str:
    """One `if (we[i]) mem[addr[i]] <= din[i]` per channel (no `integer` loop).

    Quartus has been observed to mis-infer or mis-optimize a shared `mem[]` fed
    by a clocked `for (integer i ...)` with multiple write-enables; an unrolled
    chain matches simulation semantics (last listed channel wins on same-address
    collisions) and elaborates cleanly as ALM registers.
    """
    return "\n".join(
        f"        if (we[{c}]) mem[addr[{c}]] <= din[{c}];" for c in range(num_channels)
    )


def emit_kernel_memories(test_name: str, program: List[int], data: List[int]) -> str:
    if len(program) > 256:
        raise ValueError(f"program has {len(program)} entries, exceeds 256-slot ROM")
    if len(data) > 256:
        raise ValueError(f"data has {len(data)} entries, exceeds 256-slot RAM")

    program_init = _emit_init_block("program", program, 256, 16)
    data_init = _emit_init_block("data", data, 256, 8)
    data_writes = _emit_unrolled_data_writes(DATA_RAM_NUM_CHANNELS)

    return f"""\
`default_nettype none
`timescale 1ns/1ns

// AUTO-GENERATED by test/helpers/synth_init.py from `{test_name}`.
// Do not hand-edit. To regenerate:  make synth_kernel KERNEL={test_name}
//
// program_rom: async read, one logical array; Quartus typically maps the 256x16
// ROM to MLABs or ALM registers (inlined `initial` -- no .mif/.hex).
//
// data_ram: async combinational read + up to {DATA_RAM_NUM_CHANNELS} independent
// sync write strobes per cycle. That is NOT inferrable as a single M10K (one write
// port); `ramstyle="logic"` plus unrolled writes keep the whole array in
// flip-flops / soft logic so behavior matches Icarus. Do not strip those attributes.
//
// Port shape MATCHES synth/sim_program_rom.sv and synth/sim_data_ram.sv (minus
// the test-only init backdoor). data_ram adds dbg_addr/dbg_dout for FPGA HEX
// readback (synthesis tools cannot hierarchically tap internal mem[]).

module program_rom #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 16,
    parameter NUM_CHANNELS = 1
) (
    input wire clk,
    input wire [ADDR_BITS-1:0] addr [NUM_CHANNELS-1:0],
    output wire [DATA_BITS-1:0] dout [NUM_CHANNELS-1:0]
);
    reg [DATA_BITS-1:0] mem [0:(1<<ADDR_BITS)-1];

{program_init}

    genvar g;
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : ports
            assign dout[g] = mem[addr[g]];
        end
    endgenerate

    wire _unused = &{{1'b0, clk}};
endmodule

module data_ram #(
    parameter ADDR_BITS = 8,
    parameter DATA_BITS = 8,
    parameter NUM_CHANNELS = 4
) (
    input wire clk,
    input wire [ADDR_BITS-1:0] addr [NUM_CHANNELS-1:0],
    input wire [NUM_CHANNELS-1:0] we,
    input wire [DATA_BITS-1:0] din [NUM_CHANNELS-1:0],
    output wire [DATA_BITS-1:0] dout [NUM_CHANNELS-1:0],
    input wire [ADDR_BITS-1:0] dbg_addr,
    output wire [DATA_BITS-1:0] dbg_dout
);
    // Stay in ALM registers: never promote this to block RAM (multi-we is not a
    // legal single M10K port map). `ramstyle="logic"` is the portable hint; avoid
    // invalid altera_attribute names (Quartus rejects some .qsf-only settings in HDL).
    (* ramstyle = "logic" *)
    reg [DATA_BITS-1:0] mem [0:(1<<ADDR_BITS)-1];

{data_init}

    always @(posedge clk) begin
{data_writes}
    end

    genvar g;
    generate
        for (g = 0; g < NUM_CHANNELS; g = g + 1) begin : ports
            assign dout[g] = mem[addr[g]];
        end
    endgenerate

    assign dbg_dout = mem[dbg_addr];
endmodule
"""


def main(argv: List[str]) -> int:
    if len(argv) != 2:
        print("Usage: python -m test.helpers.synth_init <test_name>", file=sys.stderr)
        print("  e.g. python -m test.helpers.synth_init test_diverge_ifelse", file=sys.stderr)
        return 1

    test_name = argv[1]
    program, data = extract_kernel(test_name)
    contents = emit_kernel_memories(test_name, program, data)
    SYNTH_OUT.parent.mkdir(parents=True, exist_ok=True)
    SYNTH_OUT.write_text(contents)
    print(
        f"Wrote {SYNTH_OUT.relative_to(REPO_ROOT)} "
        f"(program={len(program)} insns, data={len(data)} bytes) "
        f"from {test_name}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
