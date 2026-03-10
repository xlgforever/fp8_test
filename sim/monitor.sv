module monitor #(
  parameter int FORMAT = fp8_pkg::FP8_FORMAT_E4M3,
  parameter string VECTOR_FILE = "",
  parameter int LATENCY = 4,
  parameter int TOTAL_VECTORS = 65536
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic [7:0] a_i,
  input  logic [7:0] b_i,
  input  logic [7:0] y_i,
  input  logic       done_i,
  output logic       done_o,
  output logic [31:0] mismatch_o
);
  localparam bit IS_E4M3 = (FORMAT == fp8_pkg::FP8_FORMAT_E4M3);
  localparam int EXP_BITS = IS_E4M3 ? 4 : 5;
  localparam int FRAC_BITS = 7 - EXP_BITS;
  localparam int PREC_BITS = FRAC_BITS + 1;
  localparam int PROD_BITS = 2 * PREC_BITS;
  localparam int NORM_BITS = PREC_BITS + 3;
  localparam int EXP_FIELD_MAX = (1 << EXP_BITS) - 1;
  localparam int EXP_FIELD_MAX_MINUS_1 = EXP_FIELD_MAX - 1;
  localparam int EXP_BIAS = (1 << (EXP_BITS - 1)) - 1;
  localparam int EMIN = 1 - EXP_BIAS;
  localparam int EMAX = IS_E4M3 ? (EXP_FIELD_MAX - EXP_BIAS)
                                : ((EXP_FIELD_MAX - 1) - EXP_BIAS);

  logic [7:0] exp_pipe [0:LATENCY];
  logic [LATENCY:0] valid_pipe;
  logic input_active;
  logic started;
  logic [31:0] compared_count;
  logic [31:0] pushed_count;

  function automatic logic [7:0] pack_fp8(
    input logic sign,
    input logic [EXP_BITS-1:0] exp_field,
    input logic [FRAC_BITS-1:0] frac_field
  );
    begin
      pack_fp8 = {sign, exp_field, frac_field};
    end
  endfunction

  function automatic logic [7:0] make_qnan();
    logic [FRAC_BITS-1:0] qnan_frac;
    begin
      if (IS_E4M3) begin
        qnan_frac = '0;
      end else begin
        qnan_frac = '0;
        qnan_frac[FRAC_BITS-1] = 1'b1;
      end
      make_qnan = pack_fp8(1'b0, EXP_FIELD_MAX[EXP_BITS-1:0], qnan_frac);
    end
  endfunction

  function automatic logic [7:0] make_inf(input logic sign);
    begin
      make_inf = pack_fp8(sign, EXP_FIELD_MAX[EXP_BITS-1:0], '0);
    end
  endfunction

  function automatic logic [7:0] make_zero(input logic sign);
    begin
      make_zero = pack_fp8(sign, '0, '0);
    end
  endfunction

  function automatic logic [7:0] make_max_finite(input logic sign);
    logic [EXP_BITS-1:0] exp_field;
    begin
      if (IS_E4M3) begin
        exp_field = EXP_FIELD_MAX[EXP_BITS-1:0];
      end else begin
        exp_field = EXP_FIELD_MAX_MINUS_1[EXP_BITS-1:0];
      end
      make_max_finite = pack_fp8(sign, exp_field, {FRAC_BITS{1'b1}});
    end
  endfunction

  function automatic bit rne_inc(
    input bit guard,
    input bit round,
    input bit sticky,
    input bit lsb
  );
    begin
      rne_inc = guard && (round || sticky || lsb);
    end
  endfunction

  function automatic int find_lead_one(
    input int unsigned value
  );
    int idx;
    bit found;
    begin
      idx = 0;
      found = 1'b0;
      for (int i = PROD_BITS - 1; i >= 0; i--) begin
        if (!found && value[i]) begin
          idx = i;
          found = 1'b1;
        end
      end
      find_lead_one = idx;
    end
  endfunction

  function automatic logic [7:0] ref_mul(
    input logic [7:0] a,
    input logic [7:0] b
  );
    logic sign_a;
    logic sign_b;
    logic sign_y;
    int exp_a;
    int exp_b;
    int frac_a;
    int frac_b;
    bit a_zero;
    bit b_zero;
    bit a_sub;
    bit b_sub;
    bit a_nan;
    bit b_nan;
    bit a_inf;
    bit b_inf;

    int sig_a;
    int sig_b;
    int e_a;
    int e_b;
    int e_sum;
    int prod;
    int lead_idx;
    int shift_to_grs;
    int e_norm;
    int norm_ext;
    int norm_pack;
    bit sticky_from_norm;

    int main_pre;
    int main_rounded;
    int main_final;
    int e_post;
    int exp_field;
    int frac_field;

    int den_shift;
    int sub_shifted;
    int sub_main_pre;
    int sub_main_rounded;
    bit lost_bits;

    bit guard_bit;
    bit round_bit;
    bit sticky_bit;
    bit inc_bit;

    begin
      sign_a = a[7];
      sign_b = b[7];
      sign_y = sign_a ^ sign_b;

      exp_a = (a >> FRAC_BITS) & EXP_FIELD_MAX;
      exp_b = (b >> FRAC_BITS) & EXP_FIELD_MAX;
      frac_a = a & ((1 << FRAC_BITS) - 1);
      frac_b = b & ((1 << FRAC_BITS) - 1);

      a_zero = (exp_a == 0) && (frac_a == 0);
      b_zero = (exp_b == 0) && (frac_b == 0);
      a_sub = (exp_a == 0) && (frac_a != 0);
      b_sub = (exp_b == 0) && (frac_b != 0);

      if (IS_E4M3) begin
        a_nan = (exp_a == EXP_FIELD_MAX) && (frac_a == 0);
        b_nan = (exp_b == EXP_FIELD_MAX) && (frac_b == 0);
        a_inf = 1'b0;
        b_inf = 1'b0;
      end else begin
        a_inf = (exp_a == EXP_FIELD_MAX) && (frac_a == 0);
        b_inf = (exp_b == EXP_FIELD_MAX) && (frac_b == 0);
        a_nan = (exp_a == EXP_FIELD_MAX) && (frac_a != 0);
        b_nan = (exp_b == EXP_FIELD_MAX) && (frac_b != 0);
      end

      if (a_nan || b_nan) begin
        ref_mul = make_qnan();
      end else if (!IS_E4M3 && ((a_inf && b_zero) || (a_zero && b_inf))) begin
        ref_mul = make_qnan();
      end else if (!IS_E4M3 && (a_inf || b_inf)) begin
        ref_mul = make_inf(sign_y);
      end else if (a_zero || b_zero) begin
        ref_mul = make_zero(sign_y);
      end else begin
        sig_a = a_sub ? frac_a : ((1 << FRAC_BITS) | frac_a);
        sig_b = b_sub ? frac_b : ((1 << FRAC_BITS) | frac_b);
        e_a = a_sub ? EMIN : (exp_a - EXP_BIAS);
        e_b = b_sub ? EMIN : (exp_b - EXP_BIAS);
        e_sum = e_a + e_b;

        prod = sig_a * sig_b;
        lead_idx = find_lead_one(prod);
        e_norm = e_sum + lead_idx - (2 * FRAC_BITS);

        shift_to_grs = lead_idx - (FRAC_BITS + 3);
        if (shift_to_grs >= 0) begin
          norm_ext = prod >> shift_to_grs;
          if (shift_to_grs == 0) begin
            sticky_from_norm = 1'b0;
          end else begin
            sticky_from_norm = (prod & ((1 << shift_to_grs) - 1)) != 0;
          end
        end else begin
          norm_ext = prod << (-shift_to_grs);
          sticky_from_norm = 1'b0;
        end

        norm_pack = norm_ext & ((1 << NORM_BITS) - 1);
        if (sticky_from_norm) begin
          norm_pack = norm_pack | 1;
        end

        if (e_norm > EMAX) begin
          if (IS_E4M3) begin
            ref_mul = make_max_finite(sign_y);
          end else begin
            ref_mul = make_inf(sign_y);
          end
        end else if (e_norm >= EMIN) begin
          main_pre = norm_pack >> 3;
          guard_bit = ((norm_pack >> 2) & 1) != 0;
          round_bit = ((norm_pack >> 1) & 1) != 0;
          sticky_bit = (norm_pack & 1) != 0;
          inc_bit = rne_inc(guard_bit, round_bit, sticky_bit, (main_pre & 1) != 0);

          main_rounded = main_pre + (inc_bit ? 1 : 0);
          e_post = e_norm;

          if (main_rounded >= (1 << PREC_BITS)) begin
            main_final = main_rounded >> 1;
            e_post = e_post + 1;
          end else begin
            main_final = main_rounded;
          end

          if (e_post > EMAX) begin
            if (IS_E4M3) begin
              ref_mul = make_max_finite(sign_y);
            end else begin
              ref_mul = make_inf(sign_y);
            end
          end else begin
            exp_field = e_post + EXP_BIAS;
            frac_field = main_final & ((1 << FRAC_BITS) - 1);

            if (IS_E4M3 && (exp_field == EXP_FIELD_MAX) && (frac_field == 0)) begin
              exp_field = EXP_FIELD_MAX - 1;
              frac_field = (1 << FRAC_BITS) - 1;
            end

            ref_mul = pack_fp8(sign_y, exp_field[EXP_BITS-1:0], frac_field[FRAC_BITS-1:0]);
          end
        end else begin
          den_shift = EMIN - e_norm;
          if (den_shift >= NORM_BITS) begin
            sub_shifted = 0;
            lost_bits = (norm_pack != 0);
          end else begin
            sub_shifted = norm_pack >> den_shift;
            if (den_shift == 0) begin
              lost_bits = 1'b0;
            end else begin
              lost_bits = (norm_pack & ((1 << den_shift) - 1)) != 0;
            end
          end

          sub_main_pre = sub_shifted >> 3;
          guard_bit = ((sub_shifted >> 2) & 1) != 0;
          round_bit = ((sub_shifted >> 1) & 1) != 0;
          sticky_bit = ((sub_shifted & 1) != 0) || lost_bits;
          inc_bit = rne_inc(guard_bit, round_bit, sticky_bit, (sub_main_pre & 1) != 0);
          sub_main_rounded = sub_main_pre + (inc_bit ? 1 : 0);

          if (sub_main_rounded >= (1 << PREC_BITS)) begin
            ref_mul = pack_fp8(sign_y, {{(EXP_BITS-1){1'b0}}, 1'b1}, '0);
          end else begin
            frac_field = sub_main_rounded & ((1 << FRAC_BITS) - 1);
            if (frac_field == 0) begin
              ref_mul = make_zero(sign_y);
            end else begin
              ref_mul = pack_fp8(sign_y, '0, frac_field[FRAC_BITS-1:0]);
            end
          end
        end
      end
    end
  endfunction

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      done_o <= 1'b0;
      mismatch_o <= '0;
      valid_pipe <= '0;
      input_active <= 1'b1;
      started <= 1'b0;
      compared_count <= '0;
      pushed_count <= '0;
      for (int i = 0; i <= LATENCY; i++) begin
        exp_pipe[i] <= '0;
      end
    end else begin
      if (!started) begin
        started <= 1'b1;
        $display("[MONITOR %0d] start check, latency=%0d", FORMAT, LATENCY);
      end

`ifdef COMP
      if (valid_pipe[LATENCY]) begin
        if (y_i !== exp_pipe[LATENCY]) begin
          mismatch_o <= mismatch_o + 1;
          $display("[MONITOR %0d] mismatch: a=%h b=%h exp=%h got=%h", FORMAT, a_i, b_i, exp_pipe[LATENCY], y_i);
        end
      end
`endif

      if (valid_pipe[LATENCY]) begin
        compared_count <= compared_count + 1;
      end

      for (int i = LATENCY; i > 0; i--) begin
        exp_pipe[i] <= exp_pipe[i-1];
        valid_pipe[i] <= valid_pipe[i-1];
      end

      if (input_active) begin
        exp_pipe[0] <= ref_mul(a_i, b_i);
        valid_pipe[0] <= 1'b1;
        pushed_count <= pushed_count + 1;
        if (done_i) begin
          input_active <= 1'b0;
        end
      end else begin
        exp_pipe[0] <= '0;
        valid_pipe[0] <= 1'b0;
      end

      if (!done_o && !input_active && (valid_pipe == '0)) begin
        done_o <= 1'b1;
        $display("[MONITOR %0d] done. compared=%0d pushed=%0d mismatch=%0d", FORMAT, compared_count, pushed_count, mismatch_o);
      end
    end
  end
endmodule
