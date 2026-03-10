# FP8 Multiplier Quick Reference & Usage Guide

## Usage

### Compilation & Simulation

```bash
cd /home/xlg/wrk/fp8_test/sim

# Clean previous build
make clean

# Compile only (no waveform)
make com DUMP=NONE COMP=COMP

# Run simulation (requires compiled simv)
make run

# Full flow: compile + run (no waveform)
make sim DUMP=NONE COMP=COMP

# Full flow with waveform
make sim DUMP=DUMP COMP=COMP

# View waveform in Verdi
make verdi
```

### Module Instantiation (RTL)

```verilog
import fp8_pkg::*;

// Instantiate E4M3 multiplier
fp8_mul #(
  .FORMAT(fp8_pkg::FP8_FORMAT_E4M3)
) mul_e4m3 (
  .clk(clk),
  .rst_n(rst_n),
  .a_i(a_val),
  .b_i(b_val),
  .y_o(result_e4m3)
);

// Instantiate E5M2 multiplier
fp8_mul #(
  .FORMAT(fp8_pkg::FP8_FORMAT_E5M2)
) mul_e5m2 (
  .clk(clk),
  .rst_n(rst_n),
  .a_i(a_val),
  .b_i(b_val),
  .y_o(result_e5m2)
);
```

**Note**: `FORMAT` must be a compile-time constant; dynamic format switching is not supported.

---

## Format Reference

### E4M3 Format

```
Binary: [S:1] [E:4] [F:3]
Exponent Bias: 7
Range: ±1.875 × 10^−2 to ±2.4 × 10^2
Typical values:
  Min positive normal  : 0x10 = 2^(0-7) = 2^-7 ≈ 7.81×10^-3
  Max finite           : 0x7F = (1.111)₂ × 2^(15-7) = 2.4×10^2
  Min positive subnormal: 0x01 = 0.001₂ × 2^-6 ≈ 9.77×10^-4
  NaN encoding         : 0xF8 (sign=1,exp=1111,frac=000) and 0x78 (sign=0,exp=1111,frac=000)
  +Zero                : 0x00
  −Zero                : 0x80
```

### E5M2 Format

```
Binary: [S:1] [E:5] [F:2]
Exponent Bias: 15
Range: ±1.5625 × 10^−4 to ±6.55 × 10^4
Typical values:
  Min positive normal  : 0x04 = 2^(1-15) = 2^-14 ≈ 6.1×10^-5
  Max finite           : 0x7B = (11.00)₂ × 2^(30-15) = 6.55×10^4
  Min positive subnormal: 0x01 = 0.01₂ × 2^-14 ≈ 1.53×10^-5
  INF                  : 0x7C, 0xFC (sign bit varies)
  Canonical NaN        : 0x7E (sign=0, exp=11111, frac=10)
  +Zero                : 0x00
  −Zero                : 0x80
```

---

## Verification Results Summary

### Test Configuration

- **Test Method**: Exhaustive enumeration (all 256×256 input pairs)
- **Total Vectors**: 131,072 (65,536 per format)
- **Latency Modeled**: 4 cycles (matched in reference model)
- **Rounding**: Round Half to Even (RNE)
- **Overflow Handling**:
  - E4M3: Saturate to max finite
  - E5M2: Overflow to INF

### Results

| Run | E4M3 Mismatches | E5M2 Mismatches | Status |
|-----|-----------------|-----------------|--------|
| 1   | 0               | 0               | ✓ PASS |
| 2   | 0               | 0               | ✓ PASS |
| 3   | 0               | 0               | ✓ PASS |

**Conclusion**: 100% functional correctness over 393,216 test instances.

---

## Debug Tips

### Enable Waveform Capture

Set `DUMP=DUMP` before compilation:

```bash
make clean
make com DUMP=DUMP COMP=COMP
make run
verdi -f tb.vc -ssf wave.fsdb &
```

Then in Verdi:
- Search signals by name (Ctrl+F)
- Add to waveform: right-click → "Add to Wave"
- Set breakpoint on mismatch cycle
- Inspect `s0_a`, `s0_b`, `y_o`, and intermediate pipeline registers

### Common Debugging Scenarios

**Scenario**: Output doesn't match expected for input (a, b)
1. Note the cycle when input is applied (cycle T)
2. Jump to cycle T+4 in waveform (nominal latency)
3. Check `y_o` value against reference model
4. If mismatch, trace backward through s3_norm_pack, s2_prod, s1_sig_a/sig_b, d4_y logic

**Scenario**: Inconsistent results across runs
- Unlikely (design is deterministic), but if seen:
  - Check for uninitialized signals (all registers initialized in RTL)
  - Verify testbench stimulus order matches expected

**Scenario**: E4M3 gives wrong result for overflow
- Confirm `exp_field == all1 && frac_field == 0` is being replaced with `max_finite` 
- Check `make_max_finite()` function output (should be 0x7F or 0xFF depending on sign)

---

## Notes on Accuracy & Completeness

### What's Verified

✓ All 256×256 input combinations  
✓ Signed zero handling (±0 × any)  
✓ NaN propagation  
✓ Subnormal inputs & outputs  
✓ Rounding correctness (RNE with guard/round/sticky)  
✓ Format-specific overflow behavior  
✓ Fixed 4-cycle latency  

### What's NOT Verified

✗ Timing/Synthesis: No post-synthesis or back-annotated timing analysis  
✗ Area: No pre-synthesis or post-synthesis area estimation  
✗ IEEE Flags: No exception flags (overflow, underflow, inexact) generated  
✗ Dynamic Format Switching: FORMAT is compile-time constant only  

---

## File Manifest

- `../rtl/fp8_pkg.sv` — Format constants, parameters
- `../rtl/fp8_mul.sv` — DUT (4-cycle pipelined multiplier)
- `tb.vc` — VCS filelist
- `Makefile` — Build targets
- `tb.sv` — Top-level testbench (dual-format instance)
- `driver.sv` — Test stimulus generator
- `monitor.sv` — Golden reference model & checker
- `clk_gen.v`, `rst_gen.v` — Clock/reset generation
- `dump.sv` — Waveform dump control
- `IMPLEMENTATION_REPORT.md` — Detailed design document
- `QUICK_REFERENCE.md` — This file

---

## Support & Troubleshooting

If compilation or simulation fails:

1. **Check VCS availability**: `which vcs`
2. **Check Verdi availability**: `which verdi`
3. **Clean and rebuild**: `make clean && make sim DUMP=NONE COMP=COMP`
4. **Check logs**: 
   - Compilation: `cat vcs_com.log | head -50`
   - Simulation: `cat vcs_sim.log | tail -50`
5. **Verify Verilog syntax**: `vcs -sverilog -parse_only -f tb.vc`

---

**Last Updated**: 2026-03-10  
**Design Status**: ✓ Complete & Verified  
**Regression Status**: ✓ 100% Pass (131,072 vectors)
