module driver #(
  parameter int FORMAT = fp8_pkg::FP8_FORMAT_E4M3,
  parameter int TOTAL_VECTORS = 65536
) (
  input  logic       clk,
  input  logic       rst_n,
  output logic [7:0] a_o,
  output logic [7:0] b_o,
  output logic       done_o
);
  int unsigned sent_count;
  logic [7:0] a_idx;
  logic [7:0] b_idx;
  logic started;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_o <= '0;
      b_o <= '0;
      done_o <= 1'b0;
      sent_count <= '0;
      a_idx <= '0;
      b_idx <= '0;
      started <= 1'b0;
    end else begin
      if (!started) begin
        started <= 1'b1;
        $display("[DRIVER %0d] start exhaustive stimulus (%0d vectors)", FORMAT, TOTAL_VECTORS);
      end

      if (!done_o) begin
        a_o <= a_idx;
        b_o <= b_idx;

        if (sent_count == (TOTAL_VECTORS - 1)) begin
          done_o <= 1'b1;
          $display("[DRIVER %0d] stimulus completed", FORMAT);
        end

        sent_count <= sent_count + 1;

        if (b_idx == 8'hFF) begin
          b_idx <= 8'h00;
          a_idx <= a_idx + 1'b1;
        end else begin
          b_idx <= b_idx + 1'b1;
        end
      end
    end
  end
endmodule
