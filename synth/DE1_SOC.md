# DE1-SoC board UI (`de1_soc`)

LabsLand bring-up top: [`de1_soc.sv`](de1_soc.sv). Port names match [`lab2/DE1_SoC.sv`](../lab2/DE1_SoC.sv) so pin mapping is automatic.

The GPU runs a fixed kernel from generated [`kernel_memories.sv`](kernel_memories.sv). Default build uses `test_diverge_ifelse` (four threads, if/else on `threadIdx`). The VGA path accepts direct `STRFB` pixel writes and `LNS`/`LNE` line-drawer requests through the same framebuffer bridge. Regenerate with:

```bash
make synth_kernel KERNEL=test_diverge_ifelse
```

## Bring-up flow

1. Press **KEY[3]** (reset, active low). Release when you want a clean run.
2. Clock the GPU with either:
   - **SW[9] = 0** — one `gpu_clk` edge per **KEY[0]** press (single-step), or
   - **SW[9] = 1** — auto clock at ~5 Hz (`SLOW_CLK_DIV` from 50 MHz `CLOCK_50`).
3. A small boot FSM programs `thread_count` and asserts `start`; no host loader is required.
4. When the kernel finishes, **LEDR[9]** (`done`) goes high.

**KEY[1]** and **KEY[2]** are not wired in this design.

## Switches (`SW[9:0]`)

| Switch | Role |
|--------|------|
| **SW[9]** | `0` = single-step (`KEY[0]` advances `gpu_clk`); `1` = auto-tick |
| **SW[8]** | `0` = normal **LEDR** (status); `1` = hardware debug **LEDR** pages (use **SW[3:2]**) |
| **SW[7:4]** | Data RAM readback index for **HEX1** and **HEX0** (see below) |
| **SW[3:2]** | Debug LED page when **SW[8] = 1** (see [Debug LED pages](#debug-led-pages-sw8--1)) |
| **SW[1:0]** | Unused |

### Data memory address on **SW[7:4]**

Readback address is `{SW[7:4], 4'b0000}` — only **16-byte-aligned** bytes (0, 16, 32, …, 240). **HEX1** shows the high nibble, **HEX0** the low nibble of the 8-bit value (hex digits 0–9, A–F).

| SW[7:4] | Byte address | Default kernel (`test_diverge_ifelse`) |
|---------|--------------|----------------------------------------|
| 0 | `mem[0]` | |
| 1 | `mem[16]` | Thread 0 equal path → **100** (`0x64` on HEX) |
| 2 | `mem[32]` | Start of not-equal region (thread 1 at `mem[33]` is not directly selectable) |
| 3 | `mem[48]` | |

After **LEDR[9]** is on, set **SW[7:4] = 1** and check **HEX1..HEX0** for `64` (decimal 100).

## Keys (`KEY[3:0]`, active low)

| Key | Role |
|-----|------|
| **KEY[3]** | Reset (press = active) |
| **KEY[0]** | Single-step `gpu_clk` when **SW[9] = 0** |
| **KEY[2], KEY[1]** | Unused |

## Seven-segment displays (`HEX5` … `HEX0`)

Each display is one hex digit (active-low segments via [`seg7.sv`](seg7.sv)).

| Display | Source | Meaning |
|---------|--------|---------|
| **HEX5** | `current_pc[7:4]` | Program counter, high nibble |
| **HEX4** | `current_pc[3:0]` | Program counter, low nibble |
| **HEX3** | `active_mask[3:0]` | Which hardware threads are active in the warp (bit *i* = thread *i*) |
| **HEX2** | `{1'b0, stack_ptr[2:0]}` | Divergence reconvergence stack depth (0 if empty) |
| **HEX1** | `readback_data[7:4]` | Selected data RAM byte, high nibble (**SW[7:4]**) |
| **HEX0** | `readback_data[3:0]` | Selected data RAM byte, low nibble |

**HEX5..HEX4** together show the warp `current_pc` from the divergence unit (not a per-thread PC on the panel).

## Red LEDs (`LEDR[9:0]`)

### Normal mode (**SW[8] = 0**)

| LED | Signal |
|-----|--------|
| **LEDR[9]** | `done` — kernel finished |
| **LEDR[8]** | Stack non-empty (`stack_ptr != 0`) |
| **LEDR[7:4]** | `done_mask` — threads that have executed **RET** (bit *i* = thread *i*) |
| **LEDR[3:0]** | `active_mask` — threads currently executing (bit *i* = thread *i*) |

### Debug LED pages (**SW[8] = 1**)

**SW[3:2]** selects the page. **LEDR[9]** is `done` on every page.

#### Page 0 — `SW[3:2] = 00` (GPU ↔ bridge writes)

| LED | Signal |
|-----|--------|
| **LEDR[3:0]** | `data_mem_write_valid` per memory-controller channel (4 channels, not one LED per thread) |
| **LEDR[7:4]** | Per-channel write stuck: `valid & ~ready` |
| **LEDR[8]** | Any channel write stuck |
| **LEDR[9]** | `done` |

#### Page 1 — `SW[3:2] = 01` (RAM ports + reads)

| LED | Signal |
|-----|--------|
| **LEDR[3:0]** | `data_ram_we` per RAM port |
| **LEDR[7:4]** | `data_mem_read_valid` per channel |
| **LEDR[8]** | Read stuck: `valid & ~ready` |
| **LEDR[9]** | `done` |

#### Page 2 — `SW[3:2] = 10` (core 0 scheduler / fetcher)

| LED | Signal |
|-----|--------|
| **LEDR[2:0]** | `core_state` — scheduler FSM (core 0) |
| **LEDR[5:3]** | `fetcher_state` |
| **LEDR[6]** | Scheduler in **WAIT** |
| **LEDR[7]** | Data write stuck |
| **LEDR[8]** | Program fetch stuck |
| **LEDR[9]** | `done` |

Scheduler `core_state` encoding:

| Value | State |
|-------|--------|
| 0 | IDLE |
| 1 | FETCH |
| 2 | DECODE |
| 3 | REQUEST |
| 4 | WAIT |
| 5 | EXECUTE |
| 6 | UPDATE |
| 7 | DONE |

Fetcher `fetcher_state` encoding:

| Value | State |
|-------|--------|
| 0 | IDLE |
| 1 | FETCHING |
| 2 | FETCHED |

#### Page 3 — `SW[3:2] = 11` (core 0 LSU)

| LED | Signal |
|-----|--------|
| **LEDR[3:0]** | Per-thread LSU **waiting** |
| **LEDR[7:4]** | Per-thread LSU **requesting** |
| **LEDR[8]** | Any LSU waiting |
| **LEDR[9]** | `done` |

## Simulation

Cocotb tops that exercise this wiring:

- `make test_synth_top` — PC on **HEX5..HEX4**, **LEDR[9]**, readback at **SW[7:4]=1**
- `make test_synth_debug` — debug **LEDR** page 0 vs `data_mem_write_valid`
- `make test_fb_line_engine` — direct pixel and Bresenham line request behavior before the framebuffer

## Quartus Signal Tap

Probe `de1_hardware_dbg_keep`, `gpu_instance.dbg_core0_*`, and `data_mem_*` / `data_ram_we` in `de1_soc` (names are kept for STP).
