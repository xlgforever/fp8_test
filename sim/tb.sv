`timescale 1ns/1ps

module tb;
  logic clk;
  logic rst_n;

  logic [7:0] a_e4;
  logic [7:0] b_e4;
  logic [7:0] y_e4;
  logic drv_done_e4;
  logic mon_done_e4;
  logic [31:0] mismatch_e4;

  logic [7:0] a_e5;
  logic [7:0] b_e5;
  logic [7:0] y_e5;
  logic drv_done_e5;
  logic mon_done_e5;
  logic [31:0] mismatch_e5;

  clk_gen #(
    .DELAY(2)
  ) u_clk_gen (
    .clk(clk)
  );

  rst_gen u_rst_gen (
    .clk(clk),
    .rst_n(rst_n)
  );

  dump u_dump();

  driver #(
    .FORMAT(fp8_pkg::FP8_FORMAT_E4M3),
    .TOTAL_VECTORS(65536)
  ) u_driver_e4 (
    .clk(clk),
    .rst_n(rst_n),
    .a_o(a_e4),
    .b_o(b_e4),
    .done_o(drv_done_e4)
  );

  fp8_mul #(
    .FORMAT(fp8_pkg::FP8_FORMAT_E4M3)
  ) u_dut_e4 (
    .clk(clk),
    .rst_n(rst_n),
    .a_i(a_e4),
    .b_i(b_e4),
    .y_o(y_e4)
  );

  monitor #(
    .FORMAT(fp8_pkg::FP8_FORMAT_E4M3),
    .LATENCY(4),
    .TOTAL_VECTORS(65536)
  ) u_monitor_e4 (
    .clk(clk),
    .rst_n(rst_n),
    .a_i(a_e4),
    .b_i(b_e4),
    .y_i(y_e4),
    .done_i(drv_done_e4),
    .done_o(mon_done_e4),
    .mismatch_o(mismatch_e4)
  );

  driver #(
    .FORMAT(fp8_pkg::FP8_FORMAT_E5M2),
    .TOTAL_VECTORS(65536)
  ) u_driver_e5 (
    .clk(clk),
    .rst_n(rst_n),
    .a_o(a_e5),
    .b_o(b_e5),
    .done_o(drv_done_e5)
  );

  fp8_mul #(
    .FORMAT(fp8_pkg::FP8_FORMAT_E5M2)
  ) u_dut_e5 (
    .clk(clk),
    .rst_n(rst_n),
    .a_i(a_e5),
    .b_i(b_e5),
    .y_o(y_e5)
  );

  monitor #(
    .FORMAT(fp8_pkg::FP8_FORMAT_E5M2),
    .LATENCY(4),
    .TOTAL_VECTORS(65536)
  ) u_monitor_e5 (
    .clk(clk),
    .rst_n(rst_n),
    .a_i(a_e5),
    .b_i(b_e5),
    .y_i(y_e5),
    .done_i(drv_done_e5),
    .done_o(mon_done_e5),
    .mismatch_o(mismatch_e5)
  );

  always_ff @(posedge clk) begin
    if (rst_n && mon_done_e4 && mon_done_e5) begin
      $display("[TB] e4 mismatch=%0d, e5 mismatch=%0d", mismatch_e4, mismatch_e5);
      if ((mismatch_e4 + mismatch_e5) == 0) begin
        $display("[TB] PASS");
      end else begin
        $error("[TB] FAIL");
      end
      $finish;
    end
  end

  initial begin
    #6000000;
    $error("[TB] timeout");
    $finish;
  end
endmodule
