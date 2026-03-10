#!/usr/bin/env python3
"""
Generate FP8 test vectors.
Uses PyTorch CUDA FP8 if available, otherwise uses pure Python reference model.
Produces two files:
  - vectors_e4m3.txt : E4M3 format (a, b, expected_result in hex per line)
  - vectors_e5m2.txt : E5M2 format (a, b, expected_result in hex per line)
"""

import sys
import struct

# Try to import PyTorch for native FP8 compute
try:
    import torch
    HAS_TORCH = True
except ImportError:
    HAS_TORCH = False
    print("[gen_fp8_vectors] PyTorch not available; using pure Python FP8 reference model")

class FP8E4M3:
    """Python reference model for E4M3 format."""
    EXP_BITS = 4
    FRAC_BITS = 3
    PREC_BITS = FRAC_BITS + 1
    BIAS = 7
    EMIN = 1 - BIAS  # -6
    EMAX = (1 << EXP_BITS) - 1 - BIAS  # 8
    EXP_FIELD_MAX = (1 << EXP_BITS) - 1  # 15
    
    @staticmethod
    def unpack(bits):
        """Unpack 8-bit value to (sign, exponent, fraction)."""
        sign = (bits >> 7) & 1
        exp = (bits >> FP8E4M3.FRAC_BITS) & ((1 << FP8E4M3.EXP_BITS) - 1)
        frac = bits & ((1 << FP8E4M3.FRAC_BITS) - 1)
        return sign, exp, frac
    
    @staticmethod
    def pack(sign, exp, frac):
        """Pack (sign, exponent, fraction) to 8-bit value."""
        return (sign << 7) | (exp << FP8E4M3.FRAC_BITS) | frac
    
    @staticmethod
    def to_float(bits):
        """Convert FP8E4M3 to Python float."""
        sign, exp, frac = FP8E4M3.unpack(bits)
        
        # NaN: exp=all1, frac=0
        if exp == FP8E4M3.EXP_FIELD_MAX and frac == 0:
            return float('nan')
        
        # Zero: exp=0, frac=0
        if exp == 0 and frac == 0:
            return -0.0 if sign else 0.0
        
        # Subnormal: exp=0, frac!=0
        if exp == 0:
            sig = frac / (1 << FP8E4M3.FRAC_BITS)
            value = sig * (2.0 ** (FP8E4M3.EMIN + 1))
        else:
            sig = 1.0 + frac / (1 << FP8E4M3.FRAC_BITS)
            value = sig * (2.0 ** (exp - FP8E4M3.BIAS))
        
        return -value if sign else value
    
    @staticmethod
    def from_float(value):
        """Convert Python float to FP8E4M3 (nearest)."""
        import math
        if math.isnan(value):
            return FP8E4M3.pack(0, FP8E4M3.EXP_FIELD_MAX, 0)
        if math.isinf(value):
            # E4M3 has no INF, saturate to max
            sign = 1 if value < 0 else 0
            return FP8E4M3.pack(sign, FP8E4M3.EXP_FIELD_MAX-1, (1 << FP8E4M3.FRAC_BITS) - 1)
        
        sign = 1 if value < 0 else 0
        value = abs(value)
        
        if value == 0.0:
            return FP8E4M3.pack(sign, 0, 0)
        
        # Simple rounding-toward-nearest implementation
        exp = max(FP8E4M3.EMIN, int(math.log2(value)))
        frac_val = value / (2.0 ** exp) - 1.0
        frac = int(round(frac_val * (1 << FP8E4M3.FRAC_BITS)))
        
        if frac >= (1 << FP8E4M3.FRAC_BITS):
            exp += 1
            frac = 0
        
        if exp >= FP8E4M3.EXP_FIELD_MAX:
            # Overflow to max finite
            return FP8E4M3.pack(sign, FP8E4M3.EXP_FIELD_MAX-1, (1 << FP8E4M3.FRAC_BITS) - 1)
        
        exp_field = exp + FP8E4M3.BIAS
        return FP8E4M3.pack(sign, exp_field, frac)

class FP8E5M2:
    """Python reference model for E5M2 format."""
    EXP_BITS = 5
    FRAC_BITS = 2
    PREC_BITS = FRAC_BITS + 1
    BIAS = 15
    EMIN = 1 - BIAS  # -14
    EMAX = (1 << EXP_BITS) - 2 - BIAS  # 15 (reserved 31 for INF/NaN)
    EXP_FIELD_MAX = (1 << EXP_BITS) - 1  # 31
    
    @staticmethod
    def unpack(bits):
        """Unpack 8-bit value to (sign, exponent, fraction)."""
        sign = (bits >> 7) & 1
        exp = (bits >> FP8E5M2.FRAC_BITS) & ((1 << FP8E5M2.EXP_BITS) - 1)
        frac = bits & ((1 << FP8E5M2.FRAC_BITS) - 1)
        return sign, exp, frac
    
    @staticmethod
    def pack(sign, exp, frac):
        """Pack (sign, exponent, fraction) to 8-bit value."""
        return (sign << 7) | (exp << FP8E5M2.FRAC_BITS) | frac
    
    @staticmethod
    def to_float(bits):
        """Convert FP8E5M2 to Python float."""
        sign, exp, frac = FP8E5M2.unpack(bits)
        
        # INF: exp=all1, frac=0
        if exp == FP8E5M2.EXP_FIELD_MAX and frac == 0:
            return float('-inf') if sign else float('inf')
        
        # NaN: exp=all1, frac!=0
        if exp == FP8E5M2.EXP_FIELD_MAX and frac != 0:
            return float('nan')
        
        # Zero: exp=0, frac=0
        if exp == 0 and frac == 0:
            return -0.0 if sign else 0.0
        
        # Subnormal: exp=0, frac!=0
        if exp == 0:
            sig = frac / (1 << FP8E5M2.FRAC_BITS)
            value = sig * (2.0 ** (FP8E5M2.EMIN + 1))
        else:
            sig = 1.0 + frac / (1 << FP8E5M2.FRAC_BITS)
            value = sig * (2.0 ** (exp - FP8E5M2.BIAS))
        
        return -value if sign else value
    
    @staticmethod
    def from_float(value):
        """Convert Python float to FP8E5M2 (nearest, IEEE-like)."""
        import math
        if math.isnan(value):
            return FP8E5M2.pack(0, FP8E5M2.EXP_FIELD_MAX, 1)  # Canonical NaN
        if math.isinf(value):
            sign = 1 if value < 0 else 0
            return FP8E5M2.pack(sign, FP8E5M2.EXP_FIELD_MAX, 0)
        
        sign = 1 if value < 0 else 0
        value = abs(value)
        
        if value == 0.0:
            return FP8E5M2.pack(sign, 0, 0)
        
        exp = max(FP8E5M2.EMIN, int(math.floor(math.log2(value))))
        frac_val = value / (2.0 ** exp) - 1.0
        frac = int(round(frac_val * (1 << FP8E5M2.FRAC_BITS)))
        
        if frac >= (1 << FP8E5M2.FRAC_BITS):
            exp += 1
            frac = 0
        
        if exp > FP8E5M2.EMAX:
            # Overflow to INF
            return FP8E5M2.pack(sign, FP8E5M2.EXP_FIELD_MAX, 0)
        
        exp_field = exp + FP8E5M2.BIAS
        return FP8E5M2.pack(sign, exp_field, frac)

def multiply_fp8(a_bits, b_bits, fmt_class):
    """Multiply two FP8 values using reference model."""
    # Convert to float, multiply, convert back
    a_val = fmt_class.to_float(a_bits)
    b_val = fmt_class.to_float(b_bits)
    result_val = a_val * b_val
    return fmt_class.from_float(result_val)

def generate_vectors_python(fmt_type):
    """Generate exhaustive FP8 test vectors using pure Python models."""
    fmt_class = FP8E4M3 if fmt_type == "e4m3" else FP8E5M2
    vectors = []
    
    for a_val in range(256):
        for b_val in range(256):
            result = multiply_fp8(a_val, b_val, fmt_class)
            vectors.append((a_val, b_val, result))
    
    return vectors

def generate_vectors_torch(fmt_type):
    """Generate test vectors using PyTorch CUDA FP8 if available."""
    if not HAS_TORCH or not torch.cuda.is_available():
        return None
    
    vectors = []
    torch_fmt = torch.float8_e4m3fn if fmt_type == "e4m3" else torch.float8_e5m2
    
    try:
        for a_val in range(256):
            for b_val in range(256):
                # Create FP8 from bit pattern
                a_fp8 = torch.tensor([a_val], dtype=torch.uint8, device="cuda").bitcast(torch_fmt)
                b_fp8 = torch.tensor([b_val], dtype=torch.uint8, device="cuda").bitcast(torch_fmt)
                
                # Convert to float, multiply, convert back
                a_f32 = a_fp8.to(torch.float32)
                b_f32 = b_fp8.to(torch.float32)
                result_f32 = a_f32 * b_f32
                result_fp8 = result_f32.to(torch_fmt)
                
                # Extract as uint8
                result_bits = result_fp8.bitcast(torch.uint8).item()
                vectors.append((a_val, b_val, result_bits))
        
        return vectors
    except Exception as e:
        print(f"[gen_fp8_vectors] PyTorch FP8 generation failed: {e}")
        return None

def main():
    print("[gen_fp8_vectors] Generating FP8 test vectors...")
    
    # Try PyTorch first if available
    if HAS_TORCH:
        print("[gen_fp8_vectors] Attempting PyTorch CUDA FP8 generation...")
        vectors_e4m3 = generate_vectors_torch("e4m3")
        vectors_e5m2 = generate_vectors_torch("e5m2")
    else:
        vectors_e4m3 = None
        vectors_e5m2 = None
    
    # Fall back to pure Python
    if vectors_e4m3 is None:
        print("[gen_fp8_vectors] Using pure Python FP8E4M3 reference model...")
        vectors_e4m3 = generate_vectors_python("e4m3")
    
    if vectors_e5m2 is None:
        print("[gen_fp8_vectors] Using pure Python FP8E5M2 reference model...")
        vectors_e5m2 = generate_vectors_python("e5m2")
    
    # Write to files
    try:
        with open("../sim/vectors_e4m3.txt", "w") as f:
            for a, b, result in vectors_e4m3:
                # Ensure result is 8-bit unsigned (0-255)
                result_byte = result & 0xFF
                f.write(f"{a:02x} {b:02x} {result_byte:02x}\n")
        print(f"[gen_fp8_vectors] Wrote {len(vectors_e4m3)} E4M3 vectors to sim/vectors_e4m3.txt")
    except Exception as e:
        print(f"[gen_fp8_vectors] Error writing E4M3 vectors: {e}")
        return 1
    
    try:
        with open("../sim/vectors_e5m2.txt", "w") as f:
            for a, b, result in vectors_e5m2:
                # Ensure result is 8-bit unsigned (0-255)
                result_byte = result & 0xFF
                f.write(f"{a:02x} {b:02x} {result_byte:02x}\n")
        print(f"[gen_fp8_vectors] Wrote {len(vectors_e5m2)} E5M2 vectors to sim/vectors_e5m2.txt")
    except Exception as e:
        print(f"[gen_fp8_vectors] Error writing E5M2 vectors: {e}")
        return 1
    
    print("[gen_fp8_vectors] Done.")
    return 0

if __name__ == "__main__":
    sys.exit(main())
