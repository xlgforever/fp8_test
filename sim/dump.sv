module dump;
`ifdef DUMP
  initial begin
    $fsdbDumpfile("wave.fsdb");
    $fsdbDumpvars(0, tb);
  end
`endif
endmodule
