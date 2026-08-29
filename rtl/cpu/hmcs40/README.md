# HMCS40 core + ALPHA-8201 wrapper

Standalone, additive SystemVerilog port of a Hitachi HMCS40-family MCU
(fixed to the HD44801 / HMCS44 configuration), plus the ALPHA-8201
protection-MCU wrapper that Champion Base Ball / Exciting Soccer / Talbot
need. Built for `Arcade-ChampionBaseball_MiSTer`, targeting Quartus 17.0 /
Cyclone V 5CSEBA6U23I7. **Not wired into the build** — no existing file was
modified, nothing was added to `files.qip` or the `.qsf`. See "What remains
before integration" at the bottom.

Every behavioural claim in the RTL comments and in this README cites a line
in the staged MAME source:

- `Useful Information/mame/cpu/hmcs40/hmcs40.cpp` — core, timers, interrupts, LFSR PC
- `Useful Information/mame/cpu/hmcs40/hmcs40op.cpp` — all 84 instruction handlers
- `Useful Information/mame/cpu/hmcs40/hmcs40.h` — device variants / constructor parameters
- `Useful Information/mame/cpu/hmcs40/hmcs40d.cpp` — disassembler (decode table + LFSR builder)
- `Useful Information/mame/alpha8201.cpp` / `.h` — the ALPHA-8201 wrapper this ports

## Files

| File | What it is |
|---|---|
| `hmcs40_decoder.sv` | Standalone combinational opcode decoder (10-bit opcode -> instruction id). Split out on purpose — see "Opcode coverage proof" below. |
| `hmcs40.sv` | The CPU core: decoder instance, ALU, register file, LFSR PC, 4-level stack, 160x4 data RAM, timer/prescaler, interrupts. ROM is external (request/ack handshake), not embedded. |
| `alpha8201.sv` | ALPHA-8201 wrapper: instantiates `hmcs40`, bridges its word-oriented ROM interface to a `champbas_rom.sv`-compatible byte-addressed port, implements the 1KB Z80/MCU shared RAM and the R0-R3/D-port address+data-bus emulation. |
| `hmcs40_coverage.py` | The mechanical coverage-proof script (see below). Also exports the golden table the Verilator harness diffs the RTL decoder against. |

Verilator harness (not part of the deliverable RTL, lives in
`verilator/hmcs40/`, fully self-contained — does not touch the sibling
`verilator/Makefile` / `sim_main.cpp` / `tb_top.sv`, which belong to the
video-debugging harness in active use elsewhere):

| File | What it is |
|---|---|
| `verilator/hmcs40/Makefile` | Two targets: `decode` (opcode coverage sweep) and `cpu` (boots the real MCU ROM). |
| `verilator/hmcs40/sim_decode.cpp` + golden hex | Instantiates `hmcs40_decoder` directly, sweeps all 1024 opcodes, diffs against `golden/hmcs40_decode_golden.hex`. |
| `verilator/hmcs40/tb_top.sv` + `sim_cpu.cpp` | Instantiates `alpha8201` (which instantiates `hmcs40`), a behavioural ROM model loaded from the real extracted MCU ROM, and drives/observes it. |
| `verilator/hmcs40/rom/alpha-8201_44801a75_2f25.bin`, `rom/alpha8201_mcu.hex` | Extracted from the staged `_Arcade/mame/exctsccr.zip` (constraint #6 permits extracting an MCU ROM to feed a simulation). CRC32 cross-checked at **`b77931ac`**, matching `champbas.cpp`'s `ROM_LOAD` line exactly — extraction integrity confirmed, contents never decoded/interpreted by hand. |

## HD44801 = HMCS44 family, not HMCS43 (correction to the task brief)

The task brief says "confirm which `hmcs4x_cpu_device` constructor matches"
and separately states "HD44801, i.e. the HMCS43 variant" as a given fact.
**That given fact is wrong.** Read directly from the source:

- `hmcs40.cpp:46`: `DEFINE_DEVICE_TYPE(HD44801, hd44801_device, "hd44801", "Hitachi HD44801")` sits in the **HMCS44A/C/CL** block (`hmcs40.cpp:43`: "HMCS44A/C/CL, 42 pins, 32 I/O lines, (2048+128)x10 ROM, 160x4 RAM"), not the HMCS43 block above it.
- `hmcs40.cpp:123-125`: `hd44801_device::hd44801_device(...) : hmcs44_cpu_device(mconfig, HD44801, tag, owner, clock, IS_CMOS) {}` — the constructor chain is `hd44801_device -> hmcs44_cpu_device`, never touching `hmcs43_cpu_device`.
- `hmcs40.h:366-370`: `class hd44801_device : public hmcs44_cpu_device` — confirmed again at the class-declaration level.

So the parameters actually used throughout this port, from
`hmcs44_cpu_device`'s constructor (`hmcs40.cpp:113-114`):

| Parameter | Value | Source |
|---|---|---|
| family | HMCS44_FAMILY | hmcs40.cpp:114 |
| polarity | IS_CMOS (`~0`, all-ones) | hmcs40.cpp:124 |
| stack_levels | 4 | hmcs40.cpp:114 |
| pcwidth | 11 (pc 0-2047) | hmcs40.cpp:114 |
| prgwidth | 12 (4096 words, `program_2k`) | hmcs40.cpp:114, :341-344 |
| datawidth | 8 (`data_160x4`, 160 unique 4-bit cells) | hmcs40.cpp:114, :353-358 |

This matters beyond pedantry: HMCS43 has only 3 stack levels and 80x4 RAM
(would silently corrupt a design built against those numbers), and its
`read_r`/`write_r` overrides restrict R0-R3 differently (R0 input-only, R2/R3
output-only, no R4/R5) than HMCS44's (R0-R3 i/o, R4/R5 exist as dead extra
registers, `hmcs40.cpp:460-482`) — which the ALPHA-8201 wrapper's R0/R1
bidirectional binding (`alpha8201.cpp:323-326`) actually depends on.

## Opcode coverage proof

**Claim to prove:** every one of the 1024 possible 10-bit opcode words is
either mapped to exactly one of the 84 real instructions, or explicitly
classified illegal — at the granularity hardware actually dispatches on
(the raw 10-bit word), not by eyeballing mnemonics.

**Method — two independent proofs, not one eyeballed transcription:**

1. `hmcs40_coverage.py` transcribes, separately and by hand from the staged
   source, **both** of MAME's own decode representations:
   - `hmcs40d.cpp:111-200`'s flat `hmcs40_mnemonic[0x400]` lookup table (the
     disassembler's ground truth)
   - `hmcs40.cpp:686-793`'s nested `switch` in `execute_run()` (the
     interpreter's ground truth — what MAME actually *executes*, not just
     what it prints)

   It then sweeps all 1024 opcodes through both, canonicalizes (the single
   `NOP` disassembler-only alias at opcode `0x000` folds into `XSP`, since
   `0x000` dispatches to `op_xsp()` in the interpreter — `hmcs40.cpp:714`),
   and asserts they agree everywhere. **They do: 0 mismatches.**

2. `hmcs40_decoder.sv` (the actual RTL used inside `hmcs40.sv`) is a
   third, independent transcription of the same nested switch, built as
   its own standalone module specifically so it can be instantiated
   directly by a Verilator testbench (`verilator/hmcs40/sim_decode.cpp`)
   and swept over all 1024 opcodes, diffed against the golden id-per-opcode
   table `hmcs40_coverage.py` exports. **This was run — VERIFIED, not
   believed:**

   ```
   hmcs40_decoder opcode coverage sweep: 1024 opcodes checked, 480 legal, 544 illegal (golden)
   Mismatches between RTL decoder and golden table: 0
   PASS: RTL decoder (hmcs40_decoder.sv) matches the golden table bit-for-bit on all 1024 opcodes.
   ```

**Script output (run 2026-08-01, reproducible via
`python3 hmcs40_coverage.py <outdir>`):**

```
Checked 1024 opcodes (10-bit space).
Mismatches between disassembler table and interpreter switch: 0
Illegal (unmapped) encodings: 544
Legal encodings: 480
Distinct instruction mnemonics (excl. ILL): 84
op_ handlers (excl. op_illegal) from hmcs40.h: 84
In decode table but no matching op_ handler: []
Has op_ handler but never appears in decode table: []
```

I.e. the 84 mnemonics that actually appear across the 1024-entry table are
in **exact bijection** with the 84 `op_xxx` handlers declared in
`hmcs40.h:212-304` (set-difference both directions is empty) — the "84 real
instructions" claim in the task brief is now a proven fact, not an assertion.

Per-instruction encoding-count table (how many of the 1024 words decode to
each mnemonic — useful for sanity-checking any future re-encode):

```
  AI        16      LAI       16      REC        1      TC         1
  ALEI      16      LAM        4      RECF       1      TD         1
  ALEM       1      LAR        8      RED        1      TI0        1
  AM         1      LASPX      1      REDD       4      TI1        1
  AMC        1      LASPY      1      REIE       1      TIF0       1
  ANEM       1      LAT        1      REIF0      1      TIF1       1
  AYY        1      LAY        1      REIF1      1      TM         4
  BLEM       1      LBA        1      REM        4      TTF        1
  BNEM       1      LBI       16      RETF       1      XAMR      16
  BR        64      LBM        4      ROTL       1      XMA        4
  CAL       64      LBR        8      ROTR       1      XMB        4
  COMB       1      LMADY      2      RTN        1      XSP        4
  DAA        1      LMAIY      2      RTNI       1      YNEI      16
  DAS        1      LMIIY     16      SEC        1      ILL      544
  DB         1      LPU       32      SECF       1      TOTAL   1024
  DY         1      LRA        8      SED        1
  IB         1      LRB        8      SEDD       4
  IY         1      LTA        1      SEIE       1
  LAB        1      LTI       16      SEIF0      1
  LXA        1      LXI       16      SEIF1      1
  LYA        1      LYI       16      SEM        4
  MNEI      16      NEGA       1      SETF       1
  OR         1      P          8      SMC        1
                                       SYY        1
                                       TBR        8
```
(544 + 480 = 1024, confirmed by the script; reflowed here for width, exact
values are in the script's own stdout, not retyped by hand into a table
that could introduce a transcription error.)

## What's built

1. **Decoder** (`hmcs40_decoder.sv`) — see coverage proof above. **VERIFIED.**
2. **CPU core** (`hmcs40.sv`):
   - Full 4-bit ALU incl. `daa`/`das` (decimal adjust), `rotl`/`rotr`
     (through carry), the AYY/SYY/AMC/SMC "5-bit-subtract-then-check-bit4"
     carry idiom (matches `hmcs40op.cpp`'s `BIT(~x,4)` pattern exactly —
     hand-verified against two worked examples each, see commit history of
     this file for the trace).
   - Register file: A, B, X, SPX, Y, SPY, S (status), C (carry).
   - **LFSR PC** — bit-exact transcription of `increment_pc()`
     (`hmcs40.cpp:632-645`), including both hardcoded wrap special-cases.
     **VERIFIED** via the Verilator CPU harness: an independently-rebuilt
     64-entry LFSR cycle (regenerated from `hmcs40d.cpp`'s own disassembler
     builder, not copied from the RTL) matches every observed same-page PC
     step over a ~200k-instruction run with **zero breaks**.
   - LPU's one-instruction delay slot, modelled as a 2-deep shift register
     (`lpu_pend`) so the page-upper-bits load lands exactly two fetches
     after the taken LPU, matching the `m_prev_op`-based mechanism in
     `hmcs40.cpp:665-667` bit-for-bit in effect (traced by hand against the
     C++ iteration-by-iteration, not just skimmed).
   - 4-level hardware call stack (push/pop shift, matches
     `hmcs40op.cpp:24-36`).
   - 160x4 data RAM with the two mirrored 16-entry windows
     (`data_160x4`, `hmcs40.cpp:353-358`), plus XAMR's "last file" HMCS44
     addressing (`hmcs40op.cpp:88-93`, unconditional `|0xF0` for family
     HMCS44/45/46/47).
   - `P` (pattern-generation) instruction: full two-destination write-back
     (A/B and/or R2/R3, `hmcs40op.cpp:668-690`) — **believed correct,
     never exercised in the Verilator run** (the real ALPHA-8201 program,
     over ~200k executed instructions in both test configurations, never
     dispatched a `P` opcode; ALPHA-8201 is a table-interpreter chip, `P`
     is an LCD-segment-pattern instruction with no obvious use in that
     role, so this is plausible but unconfirmed).
3. **Timers + interrupts**:
   - `ti0/ti1/tif0/tif1/ttf/seie/seif0/seif1/reie/reif0/reif1/setf/secf/
     retf/recf/lti/lta/lat/rtni` — all implemented per `hmcs40op.cpp`.
   - Prescaler + timer/counter with the timer-mode/counter-mode split
     (`cf` flag) and INT1-edge direct clocking in counter mode
     (`hmcs40.cpp:598-599`).
   - External interrupt latching on INT0/INT1 rising edge, masked by
     IF0/IF1, with the one-instruction `block_int` suppression after a
     taken CAL or LPU (`hmcs40.cpp:454/467/676`).
   - **KNOWN, DOCUMENTED APPROXIMATION**: if an INT1-edge counter-mode `tc`
     bump lands on the *exact same* `clk` edge as an FSM commit, the FSM
     commit wins and the INT1 bump for that cycle is dropped (see comment
     block at the top of `hmcs40.sv`). **Moot for ALPHA-8201**:
     `alpha8201.cpp`'s pinout table lists "31: INT1 n.c." (not connected)
     — `int1_in` is tied to `1'b0` by the wrapper, so this path never
     executes in the actual application. Kept only because the core is
     written as a general-purpose HD44801, not an ALPHA-8201-only stub.
   - **Machine-cycle accounting**: normal instructions consume one `cen`
     tick, `P` and interrupt-entry each consume two (mirroring
     `cycle()`'s call sites in `hmcs40.cpp` exactly: once per fetch, once
     more inside `op_p()`, once more inside `take_interrupt()`). This is a
     **real bug that WAS caught and fixed** during this task: an earlier
     revision gated the fetch-commit on `rom_ack` alone and never actually
     waited for `cen`, so the whole core free-ran at ROM-bridge speed
     (hundreds of thousands of instructions in 2M `clk` cycles instead of
     the intended ~4000). Caught by actually running the Verilator harness,
     not by inspection — see git-free history in this file's own
     commentary (`rom_data_ready` handshake) for the fix.
4. **ALPHA-8201 wrapper** (`alpha8201.sv`):
   - 1KB shared RAM (`shared_ram[0:1023]`), Z80-side access via
     `ext_addr/ext_din/ext_dout/ext_we` — **unconditional regardless of
     `bus_dir`**, matching `alpha8201.cpp:418-428`'s own comment ("going by
     exctsccr, m_bus has no effect here" — an empirical finding by MAME's
     author, ported as-is, not re-derived).
   - MCU-side address computed from D0/D1 (bits 9:8) + R2/R3 (bits 7:0),
     exactly `mcu_update_address()` (`alpha8201.cpp:357-361`).
   - MCU-side read gated by `bus_dir && ~D2` (`/RD` active low), write
     gated by `bus_dir && D2 && D3` (both `/RD` deasserted and `WR`
     asserted), level-triggered (re-evaluated every `clk`, not just on a
     write strobe) — matches `mcu_writeram()`'s "RAM WR is level-triggered"
     comment (`alpha8201.cpp:350-355`) literally, not as an approximation.
   - R2/R3/R4-R7 reads and all D-pin reads tied to 0 (unbound in MAME's
     `device_add_mconfig`, `alpha8201.cpp:320-330` only binds
     `read_r<0>`/`read_r<1>`/`write_r<0..3>`/`write_d`) — the CMOS
     wired-AND polarity in `hmcs40.cpp:392-395` then ANDs that 0 down
     regardless of the port's own latch, so e.g. `TD` always reads status
     0 on this device in this application. Bit-exact to MAME, not a
     simplification.
   - Byte-addressed ROM bridge (2 sequential reads, low then high byte,
     little-endian) to a `champbas_rom.sv`-pin-compatible
     `mcu_addr[12:0]`/`mcu_data[7:0]` port with 1-cycle registered read
     latency (matching `dpram_dc`'s model, independently re-derived here,
     not copied from the other harness's files).

## Believed vs. verified — summary

**Verified (ran it, observed the result):**
- Decoder: bit-exact on all 1024 opcodes (Verilator sweep, `make run_decode`).
- CPU resets cleanly: `dbg_pc` = `0x7FF` (= `PC_MASK`) immediately after
  reset release, matching `hmcs40.cpp:275`.
- PC advances continuously — not stalled — over multi-hundred-thousand
  clk-cycle runs at both `run_cycles=5,000,000` and `100,000,000`.
- LFSR sequencing is bit-exact: 0 breaks against an independently-rebuilt
  64-entry cycle, over ~200,000 executed instructions (`bus_dir` both 0
  and 1), after correcting a bug in the *test harness itself* (it was
  attributing the wrong opcode to each PC transition — off-by-one — and
  reporting a wall of false "breaks"; fixed and re-verified at 0 breaks).
- Zero illegal-opcode dispatches over the same runs — the real MCU ROM's
  executed path, at least in the region reached in ~200k instructions,
  never hits an unmapped encoding. (Absence of illegal opcodes is also
  indirect evidence the ROM byte-pairing / little-endian word assembly in
  the ROM bridge is correct — random/garbage fetched data would very
  likely have hit some of the 544 illegal encodings by chance.)
- With `bus_dir` held high (MCU granted the shared-RAM bus for the whole
  run — an explicit experiment, not a claim about real Z80-side timing),
  the MCU does access shared RAM: 3,017,216 reads, 3,584 writes, 259
  distinct addresses touched, starting at `0x001`/`0x002` and a block from
  `0x200` — which line up with `alpha8201.cpp`'s own documented memory map
  comment (`0x001`: "pointer of current entry", `0x200-0x2FF`: "bank 2,
  program/data memory"). Consistent with real interpreter behaviour, not
  proof of correctness against real hardware.
- With `bus_dir` held low (the reset/idle default), zero RAM accesses are
  observed — correct per the gating logic (`mcu_rd_en`/`mcu_wr_en` both
  require `bus_dir`), not a bug.

**Believed (read the code, did not independently confirm at runtime):**
- `P` instruction's write-back logic — never exercised by the real ROM in
  the runs performed.
- Exact real-hardware timing of when the Z80 actually asserts `mcu_start`
  / `bus_dir` relative to MCU boot — this testbench picks arbitrary,
  labelled timings (`mcu_start` at 1/4 of the run; `bus_dir` either
  permanently 0 or permanently 1) specifically because no Z80-side model
  exists in this harness. The observed "MCU sits in a 2-instruction
  polling loop (`0x795`<->`0x7AA`, a DY/BR pair) for a long stretch after
  reset" is consistent with a legitimate wait-for-handshake idiom, but this
  was not cross-checked against a MAME trace (none was available/staged).
- The `CEN_DIV` default (511, i.e. `clk`/512) assumes `clk` = `CLK_49M`
  (49.152 MHz, per `Arcade-ChampionBaseball.sv:110/275`), matched against
  the real ALPHA-8201 clock (`champbas.cpp:938`,
  `XTAL(18.432MHz)/6/8` = 384kHz OSC / 4 clocks-per-machine-cycle =
  96kHz) — arithmetic checked (49.152e6/96000 = 512), but never run against
  the real 49.152MHz clock generator, only against the Verilator
  testbench's own free-running `clk`.
- ALU flag edge cases for `AMC`/`SMC`/`AYY`/`SYY` were hand-verified
  against 1-2 worked numeric examples each during development (see the
  reasoning trail in this task's transcript), not exhaustively swept
  against a reference model.

## Open questions / not reproduced

- No MAME instruction trace was available to compare against, so nothing
  here is validated cycle-exact against a reference execution — only
  structurally (decoder), and behaviourally at the "reset/LFSR/RAM-access/
  illegal-opcode" granularity the task asked for.
- The real Z80-side protocol (exact sequence/timing of `mcu_start` and
  `bus_dir` pulses from the LS259 mainlatch, and what the shared-RAM
  content needs to look like for the MCU program to do something
  observably game-relevant) was not modelled — would need
  `champbas.cpp`'s Z80-side driver code read in detail, out of scope for
  validating the MCU core in isolation.
- HLT pin support exists in `hmcs40.sv` (`hlt_in`) but is tied to `1'b0` by
  `alpha8201.sv` (real hardware: pin 19 `!HLT` tied to Vcc, i.e. never
  halted) and was never exercised.

## LE-cost expectations

Not measured (no Quartus build — out of scope per the task's hard
constraints; Quartus/HW builds are the user's). Rough sizing basis:
- Data RAM: 256 x 4-bit register array (only 160 unique locations used) —
  1Kbit, small enough to infer as LEs/LUT-RAM rather than needing a real
  M9K; if Quartus instead maps it to registers, budget ~256 flip-flops.
- Shared RAM (ALPHA-8201 wrapper): 1KB x 8-bit — almost certainly worth
  mapping to a single M9K (8Kbit) rather than LEs; as coded it's a plain
  `reg [7:0] shared_ram[0:1023]` array and Quartus's RAM inference should
  pick it up automatically, but this was not confirmed by a synthesis run.
- Decoder: ~85-way priority-if chain over a 10-bit input — a few hundred
  LEs at most, comparable in shape to a mid-size instruction decoder.
- Overall: this is a *slow* 4-bit MCU core (one instruction per ~512 clk
  cycles at the intended `cen` rate) with a small register file and no
  pipelining, so LE cost should be modest relative to the T80/Z80 cores
  already in this project — but this is an estimate, not a measurement.

## What remains before it can be wired into ChampionBaseball_MAIN.sv

1. **Nothing in this deliverable touches the build** — `files.qip`/`.qsf`
   integration, and wiring `alpha8201.sv`'s ports to the real
   `champbas_rom.sv` (already has a compatible `mcu_addr`/`mcu_data` port
   at index 6 — not modified by this task, just targeted for pin
   compatibility), the LS259 mainlatch's Q6/Q7 outputs, and
   `champbas_map`'s `0x6000-0x63FF` window, is all still to be done by
   whoever integrates this.
2. **`CEN_DIV` needs to be set to the real `clk_sys` frequency** actually
   used at the integration site (currently defaults to 511 assuming
   `CLK_49M` = 49.152MHz per `Arcade-ChampionBaseball.sv`) — confirm this
   is still accurate at integration time, the video-debugging session may
   have changed the clock plan since this was written.
3. **No cycle-exact validation against a MAME trace exists.** If the
   integrated game's ALPHA-8201 protocol turns out to depend on
   instruction-level timing this port doesn't nail (e.g. the exact
   2-cycle cost of `P`/interrupt-entry, or the LPU delay-slot mechanics),
   that will show up as game-specific misbehaviour and need a targeted
   fix, not a rewrite — the ISA-level correctness (ALU, decode, LFSR
   PC, RAM addressing) is the part with real verification behind it now.
4. **The real Z80-side handshake sequence was never modelled or checked**
   — the wrapper's RAM-access wiring was proven to work when exercised
   (`bus_dir` held high), but not against real protocol timing.
5. `P`'s write-back path is unexercised — worth a targeted test (hand-craft
   a tiny ROM image with a `P` instruction) before trusting it on
   real hardware, if the target game's ALPHA-8201 variant/ROM turns out to
   use it.
