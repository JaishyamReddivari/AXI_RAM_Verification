`timescale 1ns/1ps

module axi_tb;

  import uvm_pkg::*;
  import axi_ram_pkg::*;
  `include "uvm_macros.svh"
  `include "axi_protocol_sva.sv"

  // Parameters
  `ifdef CFG_WIDE_BUS
    parameter DATA_WIDTH = 64;
  `else
    parameter DATA_WIDTH = 32;
  `endif

  `ifdef CFG_SMALL_MEM
    parameter ADDR_WIDTH = 12;
  `else
    parameter ADDR_WIDTH = 16;
  `endif

  `ifdef CFG_NARROW_ID
    parameter ID_WIDTH = 4;
  `else
    parameter ID_WIDTH = 8;
  `endif

  `ifdef CFG_PIPELINE
    parameter PIPELINE_OUTPUT = 1;
  `else
    parameter PIPELINE_OUTPUT = 0;
  `endif

  parameter STRB_WIDTH = DATA_WIDTH / 8;

  // Clock & Reset
  logic clk = 0;
  logic rst_init = 1;
  wire  rst = rst_init | aif.rst_req;

  always #5 clk = ~clk; // 100 MHz

  initial begin
    rst_init = 1;
    repeat (20) @(posedge clk);
    rst_init = 0;
  end

  // Interface Instantiation
  axi_if #(
    .DATA_WIDTH (DATA_WIDTH),
    .ADDR_WIDTH (ADDR_WIDTH),
    .STRB_WIDTH (STRB_WIDTH),
    .ID_WIDTH   (ID_WIDTH)
  ) aif (
    .clk (clk),
    .rst (rst)
  );

  // DUT Instantiation
  axi_ram #(
    .DATA_WIDTH      (DATA_WIDTH),
    .ADDR_WIDTH      (ADDR_WIDTH),
    .STRB_WIDTH      (STRB_WIDTH),
    .ID_WIDTH        (ID_WIDTH),
    .PIPELINE_OUTPUT (PIPELINE_OUTPUT)
  ) dut (
    .clk               (clk),
    .rst               (rst),
    // AW
    .s_axi_awid        (aif.s_axi_awid),
    .s_axi_awaddr      (aif.s_axi_awaddr),
    .s_axi_awlen       (aif.s_axi_awlen),
    .s_axi_awsize      (aif.s_axi_awsize),
    .s_axi_awburst     (aif.s_axi_awburst),
    .s_axi_awlock      (aif.s_axi_awlock),
    .s_axi_awcache     (aif.s_axi_awcache),
    .s_axi_awprot      (aif.s_axi_awprot),
    .s_axi_awvalid     (aif.s_axi_awvalid),
    .s_axi_awready     (aif.s_axi_awready),
    // W
    .s_axi_wdata       (aif.s_axi_wdata),
    .s_axi_wstrb       (aif.s_axi_wstrb),
    .s_axi_wlast       (aif.s_axi_wlast),
    .s_axi_wvalid      (aif.s_axi_wvalid),
    .s_axi_wready      (aif.s_axi_wready),
    // B
    .s_axi_bid         (aif.s_axi_bid),
    .s_axi_bresp       (aif.s_axi_bresp),
    .s_axi_bvalid      (aif.s_axi_bvalid),
    .s_axi_bready      (aif.s_axi_bready),
    // AR
    .s_axi_arid        (aif.s_axi_arid),
    .s_axi_araddr      (aif.s_axi_araddr),
    .s_axi_arlen       (aif.s_axi_arlen),
    .s_axi_arsize      (aif.s_axi_arsize),
    .s_axi_arburst     (aif.s_axi_arburst),
    .s_axi_arlock      (aif.s_axi_arlock),
    .s_axi_arcache     (aif.s_axi_arcache),
    .s_axi_arprot      (aif.s_axi_arprot),
    .s_axi_arvalid     (aif.s_axi_arvalid),
    .s_axi_arready     (aif.s_axi_arready),
    // R
    .s_axi_rid         (aif.s_axi_rid),
    .s_axi_rdata       (aif.s_axi_rdata),
    .s_axi_rresp       (aif.s_axi_rresp),
    .s_axi_rlast       (aif.s_axi_rlast),
    .s_axi_rvalid      (aif.s_axi_rvalid),
    .s_axi_rready      (aif.s_axi_rready)
  );

  // Tie off unused signals
  assign aif.s_axi_awlock  = 1'b0;
  assign aif.s_axi_awcache = 4'b0;
  assign aif.s_axi_awprot  = 3'b0;
  assign aif.s_axi_arlock  = 1'b0;
  assign aif.s_axi_arcache = 4'b0;
  assign aif.s_axi_arprot  = 3'b0;

  // SVA Direct Instantiation
  axi_protocol_sva #(
    .DATA_WIDTH (DATA_WIDTH),
    .ADDR_WIDTH (ADDR_WIDTH),
    .STRB_WIDTH (STRB_WIDTH),
    .ID_WIDTH   (ID_WIDTH)
  ) sva_inst (
    .clk     (clk),
    .rst     (rst),
    .awid    (aif.s_axi_awid),
    .awaddr  (aif.s_axi_awaddr),
    .awlen   (aif.s_axi_awlen),
    .awsize  (aif.s_axi_awsize),
    .awburst (aif.s_axi_awburst),
    .awvalid (aif.s_axi_awvalid),
    .awready (aif.s_axi_awready),
    .wdata   (aif.s_axi_wdata),
    .wstrb   (aif.s_axi_wstrb),
    .wlast   (aif.s_axi_wlast),
    .wvalid  (aif.s_axi_wvalid),
    .wready  (aif.s_axi_wready),
    .bid     (aif.s_axi_bid),
    .bresp   (aif.s_axi_bresp),
    .bvalid  (aif.s_axi_bvalid),
    .bready  (aif.s_axi_bready),
    .arid    (aif.s_axi_arid),
    .araddr  (aif.s_axi_araddr),
    .arlen   (aif.s_axi_arlen),
    .arsize  (aif.s_axi_arsize),
    .arburst (aif.s_axi_arburst),
    .arvalid (aif.s_axi_arvalid),
    .arready (aif.s_axi_arready),
    .rid     (aif.s_axi_rid),
    .rdata   (aif.s_axi_rdata),
    .rresp   (aif.s_axi_rresp),
    .rlast   (aif.s_axi_rlast),
    .rvalid  (aif.s_axi_rvalid),
    .rready  (aif.s_axi_rready)
  );

  // UVM Config & Run
  initial begin
    uvm_config_db#(virtual axi_if)::set(null, "*", "vif", aif);
    run_test();
  end

  // Print active configuration
  initial begin
    $display("=== REGRESSION CONFIG ===");
    $display("  DATA_WIDTH      = %0d", DATA_WIDTH);
    $display("  ADDR_WIDTH      = %0d", ADDR_WIDTH);
    $display("  ID_WIDTH        = %0d", ID_WIDTH);
    $display("  STRB_WIDTH      = %0d", STRB_WIDTH);
    $display("  PIPELINE_OUTPUT = %0d", PIPELINE_OUTPUT);
    $display("=========================");
  end

endmodule
