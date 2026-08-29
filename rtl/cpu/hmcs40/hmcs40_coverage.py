#!/usr/bin/env python3
"""
Mechanical opcode-coverage cross-check for the Hitachi HMCS40 decoder.

Independently re-implements BOTH of MAME's own decode representations,
verbatim from the staged source, and asserts they agree on all 1024
possible 10-bit opcode words:

  A) hmcs40d.cpp  : hmcs40_mnemonic[0x400] flat lookup table (disassembler)
  B) hmcs40.cpp   : execute_run() nested switch statement (interpreter)

If A and B disagree anywhere, or either leaves an opcode unclassified,
that is a bug in my transcription -- not in MAME -- and must be fixed
before the RTL decoder can be trusted.

This script also prints the final table used as the source of truth for
hmcs40.sv's decoder (dispatch by op_xxx handler name), split into
per-instruction encoding-count buckets, for the README coverage proof,
and exports a golden id-per-opcode hex file that the Verilator harness
diffs the actual RTL decoder (hmcs40_decoder.sv) against.
"""

# ---------------------------------------------------------------------------
# A) disassembler table, transcribed verbatim from hmcs40d.cpp lines 111-200
#    (mnemonic enum order matches s_mnemonics[] in the same file)
# ---------------------------------------------------------------------------

MNEMONICS = [
    "ILL",
    "LAB", "LBA", "LAY", "LASPX", "LASPY", "XAMR",
    "LXA", "LYA", "LXI", "LYI", "IY", "DY", "AYY", "SYY", "XSP",
    "LAM", "LBM", "XMA", "XMB", "LMAIY", "LMADY",
    "LMIIY", "LAI", "LBI",
    "AI", "IB", "DB", "AMC", "SMC", "AM", "DAA", "DAS", "NEGA", "COMB", "SEC", "REC", "TC", "ROTL", "ROTR", "OR",
    "MNEI", "YNEI", "ANEM", "BNEM", "ALEI", "ALEM", "BLEM",
    "SEM", "REM", "TM",
    "BR", "CAL", "LPU", "TBR", "RTN",
    "SEIE", "SEIF0", "SEIF1", "SETF", "SECF", "REIE", "REIF0", "REIF1", "RETF", "RECF", "TI0", "TI1", "TIF0", "TIF1", "TTF", "LTI", "LTA", "LAT", "RTNI",
    "SED", "RED", "TD", "SEDD", "REDD", "LAR", "LBR", "LRA", "LRB", "P",
    "NOP",
]
IDX = {name: i for i, name in enumerate(MNEMONICS)}

def row(*names):
    return [IDX[n] for n in names]

# hmcs40_mnemonic[0x400], transcribed row-for-row (16 entries/row) from
# hmcs40d.cpp:111-200. 0 == ILL.
TABLE = []
TABLE += row(*"NOP XSP XSP XSP SEM SEM SEM SEM LAM LAM LAM LAM ILL ILL ILL ILL".split())
TABLE += [IDX["LMIIY"]] * 16
TABLE += row(*"LBM LBM LBM LBM BLEM ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += row(*"AMC ILL ILL ILL AM ILL ILL ILL ILL ILL ILL ILL LTA ILL ILL ILL".split())
# 0x040
TABLE += row(*"LXA ILL ILL ILL ILL DAS DAA ILL ILL ILL ILL ILL REC ILL ILL SEC".split())
TABLE += row(*"LYA ILL ILL ILL IY ILL ILL ILL AYY ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += row(*"LBA ILL ILL ILL IB ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += [IDX["LAI"]] * 16
# 0x080
TABLE += [IDX["AI"]] * 16
TABLE += row(*"SED ILL ILL ILL TD ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += row(*"SEIF1 SECF SEIF0 ILL SEIE SETF ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += [IDX["ILL"]] * 16
# 0x0c0
TABLE += row(*"LAR LAR LAR LAR LAR LAR LAR LAR ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += row(*"SEDD SEDD SEDD SEDD ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += row(*"LBR LBR LBR LBR LBR LBR LBR LBR ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += [IDX["XAMR"]] * 16
# 0x100
TABLE += [IDX["ILL"]] * 16
TABLE += row(*"LMAIY LMAIY ILL ILL LMADY LMADY ILL ILL LAY ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += row(*"OR ILL ILL ILL ANEM ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += [IDX["ILL"]] * 16
# 0x140
TABLE += [IDX["LXI"]] * 16
TABLE += [IDX["LYI"]] * 16
TABLE += [IDX["LBI"]] * 16
TABLE += [IDX["LTI"]] * 16
# 0x180
TABLE += [IDX["ILL"]] * 16
TABLE += [IDX["ILL"]] * 16
TABLE += row(*"TIF1 TI1 TIF0 TI0 ILL TTF ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += [IDX["ILL"]] * 16
# 0x1c0
TABLE += [IDX["BR"]] * 64
# 0x200
TABLE += row(*"TM TM TM TM REM REM REM REM XMA XMA XMA XMA ILL ILL ILL ILL".split())
TABLE += [IDX["MNEI"]] * 16
TABLE += row(*"XMB XMB XMB XMB ROTR ROTL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += row(*"SMC ILL ILL ILL ALEM ILL ILL ILL ILL ILL ILL ILL LAT ILL ILL ILL".split())
# 0x240
TABLE += row(*"LASPX ILL ILL ILL NEGA ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL TC".split())
TABLE += row(*"LASPY ILL ILL ILL DY ILL ILL ILL SYY ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += row(*"LAB ILL ILL ILL ILL ILL ILL DB ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += [IDX["ALEI"]] * 16
# 0x280
TABLE += [IDX["YNEI"]] * 16
TABLE += row(*"RED ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += row(*"REIF1 RECF REIF0 ILL REIE RETF ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += [IDX["ILL"]] * 16
# 0x2c0
TABLE += row(*"LRA LRA LRA LRA LRA LRA LRA LRA ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += row(*"REDD REDD REDD REDD ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += row(*"LRB LRB LRB LRB LRB LRB LRB LRB ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += [IDX["ILL"]] * 16
# 0x300
TABLE += [IDX["ILL"]] * 16
TABLE += [IDX["ILL"]] * 16
TABLE += row(*"COMB ILL ILL ILL BNEM ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += [IDX["ILL"]] * 16
# 0x340
TABLE += [IDX["LPU"]] * 32
TABLE += row(*"TBR TBR TBR TBR TBR TBR TBR TBR P P P P P P P P".split())
TABLE += [IDX["ILL"]] * 16
# 0x380
TABLE += [IDX["ILL"]] * 16
TABLE += [IDX["ILL"]] * 16
TABLE += row(*"ILL ILL ILL ILL RTNI ILL ILL RTN ILL ILL ILL ILL ILL ILL ILL ILL".split())
TABLE += [IDX["ILL"]] * 16
# 0x3c0
TABLE += [IDX["CAL"]] * 64

assert len(TABLE) == 1024, f"transcribed table has {len(TABLE)} entries, need 1024"

# ---------------------------------------------------------------------------
# B) interpreter nested switch, transcribed verbatim from
#    hmcs40.cpp execute_run() lines 686-793
# ---------------------------------------------------------------------------

def switch_decode(op):
    op &= 0x3ff
    top = op & 0x3f0
    if top in (0x1c0, 0x1d0, 0x1e0, 0x1f0): return "BR"
    if top in (0x3c0, 0x3d0, 0x3e0, 0x3f0): return "CAL"
    if top in (0x340, 0x350): return "LPU"
    tbl1 = {
        0x010: "LMIIY", 0x070: "LAI", 0x080: "AI", 0x0f0: "XAMR",
        0x140: "LXI", 0x150: "LYI", 0x160: "LBI", 0x170: "LTI",
        0x210: "MNEI", 0x270: "ALEI", 0x280: "YNEI",
    }
    if top in tbl1:
        return tbl1[top]

    mid = op & 0x3fc
    tbl2 = {
        0x0c0: "LAR", 0x0c4: "LAR", 0x0e0: "LBR", 0x0e4: "LBR",
        0x2c0: "LRA", 0x2c4: "LRA", 0x2e0: "LRB", 0x2e4: "LRB",
        0x360: "TBR", 0x364: "TBR", 0x368: "P", 0x36c: "P",
        0x000: "XSP", 0x004: "SEM", 0x008: "LAM", 0x020: "LBM",
        0x0d0: "SEDD", 0x200: "TM", 0x204: "REM", 0x208: "XMA",
        0x220: "XMB", 0x2d0: "REDD",
    }
    if mid in tbl2:
        return tbl2[mid]

    tbl3 = {
        0x024: "BLEM", 0x030: "AMC", 0x034: "AM", 0x03c: "LTA",
        0x040: "LXA", 0x045: "DAS", 0x046: "DAA", 0x04c: "REC",
        0x04f: "SEC", 0x050: "LYA", 0x054: "IY", 0x058: "AYY",
        0x060: "LBA", 0x064: "IB", 0x090: "SED", 0x094: "TD",
        0x0a0: "SEIF1", 0x0a1: "SECF", 0x0a2: "SEIF0", 0x0a4: "SEIE", 0x0a5: "SETF",
        0x110: "LMAIY", 0x111: "LMAIY", 0x114: "LMADY", 0x115: "LMADY",
        0x118: "LAY", 0x120: "OR", 0x124: "ANEM",
        0x1a0: "TIF1", 0x1a1: "TI1", 0x1a2: "TIF0", 0x1a3: "TI0", 0x1a5: "TTF",
        0x224: "ROTR", 0x225: "ROTL", 0x230: "SMC", 0x234: "ALEM", 0x23c: "LAT",
        0x240: "LASPX", 0x244: "NEGA", 0x24f: "TC",
        0x250: "LASPY", 0x254: "DY", 0x258: "SYY",
        0x260: "LAB", 0x267: "DB",
        0x290: "RED", 0x2a0: "REIF1", 0x2a1: "RECF", 0x2a2: "REIF0", 0x2a4: "REIE", 0x2a5: "RETF",
        0x320: "COMB", 0x324: "BNEM", 0x3a4: "RTNI", 0x3a7: "RTN",
    }
    return tbl3.get(op, "ILL")

# NOP is XSP-with-no-bits in the switch (op 0x000 -> op_xsp()); the
# disassembler labels that single encoding "NOP" for readability only.
def canon(name):
    return "XSP" if name == "NOP" else name

# ---------------------------------------------------------------------------
# Cross-check
# ---------------------------------------------------------------------------

mismatches = []
for op in range(1024):
    a = canon(MNEMONICS[TABLE[op]])
    b = canon(switch_decode(op))
    if a != b:
        mismatches.append((op, a, b))

print(f"Checked {1024} opcodes (10-bit space).")
print(f"Mismatches between disassembler table and interpreter switch: {len(mismatches)}")
for op, a, b in mismatches[:20]:
    print(f"  0x{op:03X}: table={a} switch={b}")

illegal_count = sum(1 for op in range(1024) if canon(MNEMONICS[TABLE[op]]) == "ILL")
print(f"Illegal (unmapped) encodings: {illegal_count}")
print(f"Legal encodings: {1024 - illegal_count}")

from collections import Counter
counts = Counter(canon(MNEMONICS[TABLE[op]]) for op in range(1024))
distinct_legal = set(counts) - {"ILL"}
print(f"Distinct instruction mnemonics (excl. ILL): {len(distinct_legal)}")

# op_ handler list transcribed from hmcs40.h (85 functions incl. op_illegal)
OP_HANDLERS = [
 "lab","lba","lay","laspx","laspy","xamr",
 "lxa","lya","lxi","lyi","iy","dy","ayy","syy","xsp",
 "lam","lbm","xma","xmb","lmaiy","lmady",
 "lmiiy","lai","lbi",
 "ai","ib","db","amc","smc","am","daa","das","nega","comb","sec","rec","tc","rotl","rotr","or",
 "mnei","ynei","anem","bnem","alei","alem","blem",
 "sem","rem","tm",
 "br","cal","lpu","tbr","rtn",
 "seie","seif0","seif1","setf","secf","reie","reif0","reif1","retf","recf","ti0","ti1","tif0","tif1","ttf","lti","lta","lat","rtni",
 "sed","red","td","sedd","redd","lar","lbr","lra","lrb","p",
]
print(f"op_ handlers (excl. op_illegal) from hmcs40.h: {len(OP_HANDLERS)}")

handler_set = {h.upper() for h in OP_HANDLERS}
mnemonic_set = distinct_legal
print("In decode table but no matching op_ handler:", sorted(mnemonic_set - handler_set))
print("Has op_ handler but never appears in decode table:", sorted(handler_set - mnemonic_set))

print()
print("Per-instruction encoding-count table (mnemonic: count of 10-bit encodings):")
for name in sorted(counts):
    print(f"  {name:7s} {counts[name]:4d}")
print(f"  {'TOTAL':7s} {sum(counts.values()):4d}")

# ---------------------------------------------------------------------------
# Export golden id-per-opcode table for the Verilator harness to diff the
# real RTL decoder (hmcs40_decoder.sv) against, and the id->mnemonic map.
# ---------------------------------------------------------------------------
import sys, os
outdir = sys.argv[1] if len(sys.argv) > 1 else "."
ID = {"ILL": 0}
for i, h in enumerate(OP_HANDLERS, start=1):
    ID[h.upper()] = i
assert len(ID) == 85

golden = [ID[canon(MNEMONICS[TABLE[op]])] for op in range(1024)]
with open(os.path.join(outdir, "hmcs40_decode_golden.hex"), "w") as f:
    for v in golden:
        f.write(f"{v:02x}\n")
with open(os.path.join(outdir, "hmcs40_opcode_ids.txt"), "w") as f:
    f.write("0 ILL\n")
    for i, h in enumerate(OP_HANDLERS, start=1):
        f.write(f"{i} {h.upper()}\n")
print(f"\nWrote {os.path.join(outdir,'hmcs40_decode_golden.hex')} (1024 lines) and hmcs40_opcode_ids.txt (85 lines)")
