module driver #(
  parameter int FORMAT = fp8_pkg::FP8_FORMAT_E4M3,
  parameter string VECTOR_FILE = "",
  parameter int TOTAL_VECTORS = 65536
) (
  input  logic       clk,
  input  logic       rst_n,
  output logic [7:0] a_o,
  output logic [7:0] b_o,
  output logic       done_o
);
  logic [7:0] vectors [65536*2]; // Flat array: vectors[i*2]=a, vectors[i*2+1]=b
  logic vectors_loaded;
  logic use_file;
  int unsigned i;
  integer fp, file_status;
  logic [7:0] a_read, b_read;

  // Pre-load vectors during initialization
  initial begin
    vectors_loaded = 1'b0;
    use_file = 1'b0;
    
    if (VECTOR_FILE != "") begin
      use_file = 1'b1;
      $display("[DRIVER %0d] loading vectors from %s...", FORMAT, VECTOR_FILE);
      fp = $fopen(VECTOR_FILE, "r");
      if (fp == 0) begin
        $error("[DRIVER %0d] cannot open VECTOR_FILE=%s", FORMAT, VECTOR_FILE);
      end
      
      for (i = 0; i < TOTAL_VECTORS; i++) begin
        file_status = $fscanf(fp, "%h %h", a_read, b_read);
        if (file_status != 2) begin
          $error("[DRIVER %0d] failed to read vector at index %0d", FORMAT, i);
          break;
        end
        vectors[i*2] = a_read;
        vectors[i*2+1] = b_read;
      end
      $fclose(fp);
      $display("[DRIVER %0d] loaded %0d vectors from file", FORMAT, i);
    end
    vectors_loaded = 1'b1;
  end

  // Generate stimulus in always_ff
  int unsigned vector_count;
  
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      a_o <= '0;
      b_o <= '0;
      done_o <= 1'b0;
      vector_count <= '0;
    end else if (vectors_loaded) begin
      // Print stimulus start on first cycle after reset
      if (vector_count == 0 && !done_o) begin
        if (use_file) begin
          $display("[DRIVER %0d] starting file-based stimulus (%0d vectors)", FORMAT, TOTAL_VECTORS);
        end else begin
          $display("[DRIVER %0d] starting exhaustive stimulus (%0d vectors)", FORMAT, TOTAL_VECTORS);
        end
      end

      // Output current vector
      if (!done_o) begin
        if (use_file) begin
          a_o <= vectors[vector_count * 2];
          b_o <= vectors[vector_count * 2 + 1];
        end else begin
          // Exhaustive all-pairs: a varies slowest
          a_o <= (vector_count / 256) & 8'hFF;
          b_o <= vector_count & 8'hFF;
        end

        // Increment counter or finish
        if (vector_count == (TOTAL_VECTORS - 1)) begin
          done_o <= 1'b1;
          $display("[DRIVER %0d] stimulus completed (%0d vectors)", FORMAT, vector_count + 1);
        end else begin
          vector_count <= vector_count + 1;
        end
      end
    end
  end
endmodule
