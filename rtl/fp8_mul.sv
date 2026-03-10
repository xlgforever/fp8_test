module fp8_mul #(
  parameter int FORMAT = fp8_pkg::FP8_FORMAT_E4M3
) (
  input  logic       clk,
  input  logic       rst_n,
  input  logic [7:0] a_i,
  input  logic [7:0] b_i,
  output logic [7:0] y_o
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
                                : (EXP_FIELD_MAX_MINUS_1 - EXP_BIAS);
  localparam int EXP_CALC_BITS = EXP_BITS + 4;

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
    input logic [PROD_BITS-1:0] value
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

  // Stage 0: input register.
  logic [7:0] s0_a;
  logic [7:0] s0_b;

  // Stage 1: decode and special-case classify.
  logic s1_sign;
  logic s1_special;
  logic [7:0] s1_special_y;
  logic [PREC_BITS-1:0] s1_sig_a;
  logic [PREC_BITS-1:0] s1_sig_b;
  logic signed [EXP_CALC_BITS-1:0] s1_exp_a;
  logic signed [EXP_CALC_BITS-1:0] s1_exp_b;

  // Stage 2: significand multiply and exponent add.
  logic s2_sign;
  logic s2_special;
  logic [7:0] s2_special_y;
  logic [PROD_BITS-1:0] s2_prod;
  logic signed [EXP_CALC_BITS-1:0] s2_exp_sum;

  // Stage 3: normalize and build GRS bundle.
  logic s3_sign;
  logic s3_special;
  logic [7:0] s3_special_y;
  logic s3_overflow;
  logic s3_subnormal;
  logic signed [EXP_CALC_BITS-1:0] s3_e_norm;
  logic [NORM_BITS-1:0] s3_norm_pack;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s0_a <= '0;
      s0_b <= '0;
    end else begin
      s0_a <= a_i;
      s0_b <= b_i;
    end
  end

  logic d1_sign;
  logic d1_special;
  logic [7:0] d1_special_y;
  logic [PREC_BITS-1:0] d1_sig_a;
  logic [PREC_BITS-1:0] d1_sig_b;
  logic signed [EXP_CALC_BITS-1:0] d1_exp_a;
  logic signed [EXP_CALC_BITS-1:0] d1_exp_b;

  always_comb begin
    logic a_sign;
    logic b_sign;
    logic [EXP_BITS-1:0] a_exp;
    logic [EXP_BITS-1:0] b_exp;
    logic [FRAC_BITS-1:0] a_frac;
    logic [FRAC_BITS-1:0] b_frac;
    logic a_zero;
    logic b_zero;
    logic a_sub;
    logic b_sub;
    logic a_nan;
    logic b_nan;
    logic a_inf;
    logic b_inf;

    a_sign = s0_a[7];
    b_sign = s0_b[7];
    a_exp = s0_a[FRAC_BITS +: EXP_BITS];
    b_exp = s0_b[FRAC_BITS +: EXP_BITS];
    a_frac = s0_a[FRAC_BITS-1:0];
    b_frac = s0_b[FRAC_BITS-1:0];

    a_zero = (a_exp == '0) && (a_frac == '0);
    b_zero = (b_exp == '0) && (b_frac == '0);
    a_sub = (a_exp == '0) && (a_frac != '0);
    b_sub = (b_exp == '0) && (b_frac != '0);

    if (IS_E4M3) begin
      a_nan = (a_exp == EXP_FIELD_MAX[EXP_BITS-1:0]) && (a_frac == '0);
      b_nan = (b_exp == EXP_FIELD_MAX[EXP_BITS-1:0]) && (b_frac == '0);
      a_inf = 1'b0;
      b_inf = 1'b0;
    end else begin
      a_inf = (a_exp == EXP_FIELD_MAX[EXP_BITS-1:0]) && (a_frac == '0);
      b_inf = (b_exp == EXP_FIELD_MAX[EXP_BITS-1:0]) && (b_frac == '0);
      a_nan = (a_exp == EXP_FIELD_MAX[EXP_BITS-1:0]) && (a_frac != '0);
      b_nan = (b_exp == EXP_FIELD_MAX[EXP_BITS-1:0]) && (b_frac != '0);
    end

    d1_sign = a_sign ^ b_sign;
    d1_special = 1'b0;
    d1_special_y = '0;

    if (a_nan || b_nan) begin
      d1_special = 1'b1;
      d1_special_y = make_qnan();
    end else if (!IS_E4M3 && ((a_inf && b_zero) || (a_zero && b_inf))) begin
      d1_special = 1'b1;
      d1_special_y = make_qnan();
    end else if (!IS_E4M3 && (a_inf || b_inf)) begin
      d1_special = 1'b1;
      d1_special_y = make_inf(d1_sign);
    end else if (a_zero || b_zero) begin
      d1_special = 1'b1;
      d1_special_y = make_zero(d1_sign);
    end

    d1_sig_a = a_sub ? {1'b0, a_frac} : {1'b1, a_frac};
    d1_sig_b = b_sub ? {1'b0, b_frac} : {1'b1, b_frac};

    if (a_sub) begin
      d1_exp_a = EMIN;
    end else begin
      d1_exp_a = $signed({1'b0, a_exp}) - EXP_BIAS;
    end

    if (b_sub) begin
      d1_exp_b = EMIN;
    end else begin
      d1_exp_b = $signed({1'b0, b_exp}) - EXP_BIAS;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s1_sign <= '0;
      s1_special <= '0;
      s1_special_y <= '0;
      s1_sig_a <= '0;
      s1_sig_b <= '0;
      s1_exp_a <= '0;
      s1_exp_b <= '0;
    end else begin
      s1_sign <= d1_sign;
      s1_special <= d1_special;
      s1_special_y <= d1_special_y;
      s1_sig_a <= d1_sig_a;
      s1_sig_b <= d1_sig_b;
      s1_exp_a <= d1_exp_a;
      s1_exp_b <= d1_exp_b;
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s2_sign <= '0;
      s2_special <= '0;
      s2_special_y <= '0;
      s2_prod <= '0;
      s2_exp_sum <= '0;
    end else begin
      s2_sign <= s1_sign;
      s2_special <= s1_special;
      s2_special_y <= s1_special_y;
      s2_prod <= s1_sig_a * s1_sig_b;
      s2_exp_sum <= s1_exp_a + s1_exp_b;
    end
  end

  logic d3_sign;
  logic d3_special;
  logic [7:0] d3_special_y;
  logic d3_overflow;
  logic d3_subnormal;
  logic signed [EXP_CALC_BITS-1:0] d3_e_norm;
  logic [NORM_BITS-1:0] d3_norm_pack;

  always_comb begin
    int lead_idx;
    int shift_to_grs;
    int e_norm_int;
    logic [NORM_BITS-1:0] norm_ext;
    logic sticky_from_norm;

    d3_sign = s2_sign;
    d3_special = s2_special;
    d3_special_y = s2_special_y;
    d3_overflow = 1'b0;
    d3_subnormal = 1'b0;
    d3_e_norm = '0;
    d3_norm_pack = '0;

    if (!s2_special) begin
      lead_idx = find_lead_one(s2_prod);
      e_norm_int = $signed(s2_exp_sum) + lead_idx - (2 * FRAC_BITS);

      shift_to_grs = lead_idx - (FRAC_BITS + 3);
      if (shift_to_grs >= 0) begin
        norm_ext = s2_prod >> shift_to_grs;
        if (shift_to_grs == 0) begin
          sticky_from_norm = 1'b0;
        end else begin
          logic [PROD_BITS-1:0] mask_val;
          mask_val = (1 << shift_to_grs) - 1;
          sticky_from_norm = |(s2_prod & mask_val);
        end
      end else begin
        norm_ext = s2_prod << (-shift_to_grs);
        sticky_from_norm = 1'b0;
      end

      d3_norm_pack = norm_ext;
      d3_norm_pack[0] = norm_ext[0] | sticky_from_norm;
      d3_e_norm = e_norm_int;
      d3_overflow = (e_norm_int > EMAX);
      d3_subnormal = (e_norm_int < EMIN);
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      s3_sign <= '0;
      s3_special <= '0;
      s3_special_y <= '0;
      s3_overflow <= '0;
      s3_subnormal <= '0;
      s3_e_norm <= '0;
      s3_norm_pack <= '0;
    end else begin
      s3_sign <= d3_sign;
      s3_special <= d3_special;
      s3_special_y <= d3_special_y;
      s3_overflow <= d3_overflow;
      s3_subnormal <= d3_subnormal;
      s3_e_norm <= d3_e_norm;
      s3_norm_pack <= d3_norm_pack;
    end
  end

  logic [7:0] d4_y;

  always_comb begin
    logic [PREC_BITS-1:0] main_pre;
    logic [PREC_BITS:0] main_rounded;
    logic [PREC_BITS-1:0] main_final;
    logic guard_bit;
    logic round_bit;
    logic sticky_bit;
    logic inc_bit;
    int e_post;
    int exp_field_int;
    logic [EXP_BITS-1:0] exp_field;
    logic [FRAC_BITS-1:0] frac_field;

    logic [NORM_BITS-1:0] sub_shifted;
    logic [PREC_BITS-1:0] sub_main_pre;
    logic [PREC_BITS:0] sub_main_rounded;
    logic sub_lost_bits;
    int den_shift;

    d4_y = '0;

    if (s3_special) begin
      d4_y = s3_special_y;
    end else if (s3_overflow) begin
      if (IS_E4M3) begin
        d4_y = make_max_finite(s3_sign);
      end else begin
        d4_y = make_inf(s3_sign);
      end
    end else if (!s3_subnormal) begin
      main_pre = s3_norm_pack[NORM_BITS-1:3];
      guard_bit = s3_norm_pack[2];
      round_bit = s3_norm_pack[1];
      sticky_bit = s3_norm_pack[0];
      inc_bit = rne_inc(guard_bit, round_bit, sticky_bit, main_pre[0]);

      main_rounded = {1'b0, main_pre} + inc_bit;
      e_post = $signed(s3_e_norm);

      if (main_rounded[PREC_BITS]) begin
        main_final = main_rounded[PREC_BITS:1];
        e_post = e_post + 1;
      end else begin
        main_final = main_rounded[PREC_BITS-1:0];
      end

      if (e_post > EMAX) begin
        if (IS_E4M3) begin
          d4_y = make_max_finite(s3_sign);
        end else begin
          d4_y = make_inf(s3_sign);
        end
      end else begin
        exp_field_int = e_post + EXP_BIAS;
        exp_field = exp_field_int[EXP_BITS-1:0];
        frac_field = main_final[FRAC_BITS-1:0];

        if (IS_E4M3 && (exp_field == EXP_FIELD_MAX[EXP_BITS-1:0]) && (frac_field == '0)) begin
          exp_field = EXP_FIELD_MAX_MINUS_1[EXP_BITS-1:0];
          frac_field = {FRAC_BITS{1'b1}};
        end

        d4_y = pack_fp8(s3_sign, exp_field, frac_field);
      end
    end else begin
      den_shift = EMIN - $signed(s3_e_norm);
      if (den_shift >= NORM_BITS) begin
        sub_shifted = '0;
        sub_lost_bits = |s3_norm_pack;
      end else begin
        sub_shifted = s3_norm_pack >> den_shift;
        if (den_shift == 0) begin
          sub_lost_bits = 1'b0;
        end else begin
          logic [NORM_BITS-1:0] mask_val;
          mask_val = (1 << den_shift) - 1;
          sub_lost_bits = |(s3_norm_pack & mask_val);
        end
      end

      sub_main_pre = sub_shifted[NORM_BITS-1:3];
      guard_bit = sub_shifted[2];
      round_bit = sub_shifted[1];
      sticky_bit = sub_shifted[0] | sub_lost_bits;
      inc_bit = rne_inc(guard_bit, round_bit, sticky_bit, sub_main_pre[0]);
      sub_main_rounded = {1'b0, sub_main_pre} + inc_bit;

      if (sub_main_rounded[PREC_BITS]) begin
        d4_y = pack_fp8(s3_sign, {{(EXP_BITS-1){1'b0}}, 1'b1}, '0);
      end else begin
        frac_field = sub_main_rounded[FRAC_BITS-1:0];
        if (frac_field == '0) begin
          d4_y = make_zero(s3_sign);
        end else begin
          d4_y = pack_fp8(s3_sign, '0, frac_field);
        end
      end
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      y_o <= '0;
    end else begin
      y_o <= d4_y;
    end
  end

endmodule
