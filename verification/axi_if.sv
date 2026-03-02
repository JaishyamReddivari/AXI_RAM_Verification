interface axi_if #(
  parameter DATA_WIDTH = 32,
  parameter ADDR_WIDTH = 16,
  parameter STRB_WIDTH = DATA_WIDTH/8,
  parameter ID_WIDTH   = 8
)(
  input logic clk,
  input logic rst
);
  
  logic rst_req = 0;

  // Write Address Channel
  logic [ID_WIDTH-1:0]   s_axi_awid;
  logic [ADDR_WIDTH-1:0] s_axi_awaddr;
  logic [7:0]            s_axi_awlen;
  logic [2:0]            s_axi_awsize;
  logic [1:0]            s_axi_awburst;
  logic                  s_axi_awlock;
  logic [3:0]            s_axi_awcache;
  logic [2:0]            s_axi_awprot;
  logic                  s_axi_awvalid;
  logic                  s_axi_awready;

  // Write Data Channel
  logic [DATA_WIDTH-1:0] s_axi_wdata;
  logic [STRB_WIDTH-1:0] s_axi_wstrb;
  logic                  s_axi_wlast;
  logic                  s_axi_wvalid;
  logic                  s_axi_wready;

  // Write Response Channel
  logic [ID_WIDTH-1:0]   s_axi_bid;
  logic [1:0]            s_axi_bresp;
  logic                  s_axi_bvalid;
  logic                  s_axi_bready;

  // Read Address Channel
  logic [ID_WIDTH-1:0]   s_axi_arid;
  logic [ADDR_WIDTH-1:0] s_axi_araddr;
  logic [7:0]            s_axi_arlen;
  logic [2:0]            s_axi_arsize;
  logic [1:0]            s_axi_arburst;
  logic                  s_axi_arlock;
  logic [3:0]            s_axi_arcache;
  logic [2:0]            s_axi_arprot;
  logic                  s_axi_arvalid;
  logic                  s_axi_arready;

  // Read Data Channel
  logic [ID_WIDTH-1:0]   s_axi_rid;
  logic [DATA_WIDTH-1:0] s_axi_rdata;
  logic [1:0]            s_axi_rresp;
  logic                  s_axi_rlast;
  logic                  s_axi_rvalid;
  logic                  s_axi_rready;

endinterface
