module rst_gen (
  input  logic clk,
  output logic rst_n
);
  initial begin
    rst_n = 1'b0;
    repeat (8) @(posedge clk);
    rst_n = 1'b1;
  end
endmodule
