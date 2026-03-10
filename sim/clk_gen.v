module clk_gen #(
  parameter int DELAY = 2
) (
  output logic clk
);
  initial clk = 1'b0;
  always #DELAY clk = ~clk;
endmodule
