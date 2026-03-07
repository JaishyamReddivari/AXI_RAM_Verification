module axi_protocol_sva #(
  parameter DATA_WIDTH = 32,
  parameter ADDR_WIDTH = 16,
  parameter STRB_WIDTH = DATA_WIDTH/8,
  parameter ID_WIDTH   = 8
)(
  input logic                  clk,
  input logic                  rst,
  // AW
  input logic [ID_WIDTH-1:0]   awid,
  input logic [ADDR_WIDTH-1:0] awaddr,
  input logic [7:0]            awlen,
  input logic [2:0]            awsize,
  input logic [1:0]            awburst,
  input logic                  awvalid,
  input logic                  awready,
  // W
  input logic [DATA_WIDTH-1:0] wdata,
  input logic [STRB_WIDTH-1:0] wstrb,
  input logic                  wlast,
  input logic                  wvalid,
  input logic                  wready,
  // B
  input logic [ID_WIDTH-1:0]   bid,
  input logic [1:0]            bresp,
  input logic                  bvalid,
  input logic                  bready,
  // AR
  input logic [ID_WIDTH-1:0]   arid,
  input logic [ADDR_WIDTH-1:0] araddr,
  input logic [7:0]            arlen,
  input logic [2:0]            arsize,
  input logic [1:0]            arburst,
  input logic                  arvalid,
  input logic                  arready,
  // R
  input logic [ID_WIDTH-1:0]   rid,
  input logic [DATA_WIDTH-1:0] rdata,
  input logic [1:0]            rresp,
  input logic                  rlast,
  input logic                  rvalid,
  input logic                  rready
);

  wire active = !rst;

  // ========================================================================
  // SVA-01: VALID-before-READY stability (AXI spec A3.2.1)
  //         Once xVALID asserts, it must stay high until xREADY
  // ========================================================================

  // AW channel
  property p_awvalid_stable;
    @(posedge clk) disable iff (rst)
    (awvalid && !awready) |=> awvalid;
  endproperty
  SVA_01_AWVALID_STABLE: assert property (p_awvalid_stable)
    else $error("SVA-01: AWVALID deasserted before AWREADY");

  // W channel
  property p_wvalid_stable;
    @(posedge clk) disable iff (rst)
    (wvalid && !wready) |=> wvalid;
  endproperty
  SVA_01_WVALID_STABLE: assert property (p_wvalid_stable)
    else $error("SVA-01: WVALID deasserted before WREADY");

  // AR channel
  property p_arvalid_stable;
    @(posedge clk) disable iff (rst)
    (arvalid && !arready) |=> arvalid;
  endproperty
  SVA_01_ARVALID_STABLE: assert property (p_arvalid_stable)
    else $error("SVA-01: ARVALID deasserted before ARREADY");

  // B channel (DUT is source — checking DUT output)
  property p_bvalid_stable;
    @(posedge clk) disable iff (rst)
    (bvalid && !bready) |=> bvalid;
  endproperty
  SVA_01_BVALID_STABLE: assert property (p_bvalid_stable)
    else $error("SVA-01: BVALID deasserted before BREADY");

  // R channel (DUT is source)
  property p_rvalid_stable;
    @(posedge clk) disable iff (rst)
    (rvalid && !rready) |=> rvalid;
  endproperty
  SVA_01_RVALID_STABLE: assert property (p_rvalid_stable)
    else $error("SVA-01: RVALID deasserted before RREADY");

  // ========================================================================
  // SVA-02: Data/payload stable while waiting
  //         When xVALID=1 and xREADY=0, payload must not change
  // ========================================================================

  // AW payload
  property p_aw_stable;
    @(posedge clk) disable iff (rst)
    (awvalid && !awready) |=> ($stable(awid) && $stable(awaddr) &&
                                $stable(awlen) && $stable(awsize) &&
                                $stable(awburst));
  endproperty
  SVA_02_AW_STABLE: assert property (p_aw_stable)
    else $error("SVA-02: AW payload changed while waiting for AWREADY");

  // W payload
  property p_w_stable;
    @(posedge clk) disable iff (rst)
    (wvalid && !wready) |=> ($stable(wdata) && $stable(wstrb) && $stable(wlast));
  endproperty
  SVA_02_W_STABLE: assert property (p_w_stable)
    else $error("SVA-02: W payload changed while waiting for WREADY");

  // AR payload
  property p_ar_stable;
    @(posedge clk) disable iff (rst)
    (arvalid && !arready) |=> ($stable(arid) && $stable(araddr) &&
                                $stable(arlen) && $stable(arsize) &&
                                $stable(arburst));
  endproperty
  SVA_02_AR_STABLE: assert property (p_ar_stable)
    else $error("SVA-02: AR payload changed while waiting for ARREADY");

  // B payload (DUT output)
  property p_b_stable;
    @(posedge clk) disable iff (rst)
    (bvalid && !bready) |=> ($stable(bid) && $stable(bresp));
  endproperty
  SVA_02_B_STABLE: assert property (p_b_stable)
    else $error("SVA-02: B payload changed while waiting for BREADY");

  // R payload (DUT output) — covers SVA-06(RID), SVA-12(RID stable), SVA-13(RLAST stable)
  property p_r_stable;
    @(posedge clk) disable iff (rst)
    (rvalid && !rready) |=> ($stable(rid) && $stable(rdata) &&
                              $stable(rresp) && $stable(rlast));
  endproperty
  SVA_02_R_STABLE: assert property (p_r_stable)
    else $error("SVA-02: R payload changed while waiting for RREADY");

  // ========================================================================
  // SVA-03/04: WLAST and RLAST beat counters
  // ========================================================================

  // --- WLAST: must assert on exactly beat (AWLEN+1) ---
  int unsigned w_beat_cnt;
  logic [7:0] aw_len_q[$];  // queue of expected lengths

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      w_beat_cnt <= 0;
      aw_len_q = {};
    end else begin
      // Capture AW length on AW handshake
      if (awvalid && awready)
        aw_len_q.push_back(awlen);

      // Count W beats
      if (wvalid && wready) begin
        if (wlast) begin
          // WLAST should fire when count matches expected len
          SVA_03_WLAST: assert (aw_len_q.size() > 0 && w_beat_cnt == aw_len_q[0])
            else $error("SVA-03: WLAST at wrong beat: cnt=%0d expected=%0d",
                        w_beat_cnt, (aw_len_q.size() > 0) ? aw_len_q[0] : -1);
          if (aw_len_q.size() > 0)
            void'(aw_len_q.pop_front());
          w_beat_cnt <= 0;
        end else begin
          w_beat_cnt <= w_beat_cnt + 1;
        end
      end
    end
  end

  // --- RLAST: must assert on exactly beat (ARLEN+1) ---
  int unsigned r_beat_cnt;
  logic [7:0] ar_len_q[$];

  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      r_beat_cnt <= 0;
      ar_len_q = {};
    end else begin
      if (arvalid && arready)
        ar_len_q.push_back(arlen);

      if (rvalid && rready) begin
        if (rlast) begin
          SVA_04_RLAST: assert (ar_len_q.size() > 0 && r_beat_cnt == ar_len_q[0])
            else $error("SVA-04: RLAST at wrong beat: cnt=%0d expected=%0d",
                        r_beat_cnt, (ar_len_q.size() > 0) ? ar_len_q[0] : -1);
          if (ar_len_q.size() > 0)
            void'(ar_len_q.pop_front());
          r_beat_cnt <= 0;
        end else begin
          r_beat_cnt <= r_beat_cnt + 1;
        end
      end
    end
  end

  // ========================================================================
  // SVA-05: BID matches AWID
  // ========================================================================
  logic [ID_WIDTH-1:0] awid_q[$];

  always_ff @(posedge clk or posedge rst) begin
    if (rst)
      awid_q = {};
    else begin
      if (awvalid && awready)
        awid_q.push_back(awid);
      if (bvalid && bready) begin
        SVA_05_BID: assert (awid_q.size() > 0 && bid == awid_q[0])
          else $error("SVA-05: BID=0x%0h != expected AWID=0x%0h",
                      bid, (awid_q.size() > 0) ? awid_q[0] : '0);
        if (awid_q.size() > 0)
          void'(awid_q.pop_front());
      end
    end
  end

  // ========================================================================
  // SVA-06: RID matches ARID (checked per burst, all beats same RID)
  // ========================================================================
  logic [ID_WIDTH-1:0] arid_q[$];

  always_ff @(posedge clk or posedge rst) begin
    if (rst)
      arid_q = {};
    else begin
      if (arvalid && arready)
        arid_q.push_back(arid);
      if (rvalid && rready) begin
        SVA_06_RID: assert (arid_q.size() > 0 && rid == arid_q[0])
          else $error("SVA-06: RID=0x%0h != expected ARID=0x%0h",
                      rid, (arid_q.size() > 0) ? arid_q[0] : '0);
        if (rlast && arid_q.size() > 0)
          void'(arid_q.pop_front());
      end
    end
  end

  // ========================================================================
  // SVA-07: No BVALID before WLAST accepted
  // ========================================================================
  logic wlast_done;

  always_ff @(posedge clk or posedge rst) begin
    if (rst)
      wlast_done <= 0;
    else begin
      if (wvalid && wready && wlast)
        wlast_done <= 1;
      if (bvalid && bready)
        wlast_done <= 0;
    end
  end

  property p_no_b_before_wlast;
    @(posedge clk) disable iff (rst)
    ($rose(bvalid)) |-> wlast_done;
  endproperty
  SVA_07_NO_B_BEFORE_WLAST: assert property (p_no_b_before_wlast)
    else $error("SVA-07: BVALID asserted before WLAST was accepted");

  // ========================================================================
  // SVA-08: Reset clears all DUT outputs
  // ========================================================================
  property p_reset_clears;
    @(posedge clk)
    $fell(rst) |-> (!bvalid && !rvalid);
  endproperty
  SVA_08_RESET_CLEARS: assert property (p_reset_clears)
    else $error("SVA-08: DUT outputs not deasserted after reset");

  // ========================================================================
  // SVA-09/10: Response codes must be OKAY (2'b00)
  // ========================================================================
  property p_bresp_okay;
    @(posedge clk) disable iff (rst)
    (bvalid && bready) |-> (bresp == 2'b00);
  endproperty
  SVA_09_BRESP_OKAY: assert property (p_bresp_okay)
    else $error("SVA-09: BRESP=0x%0h, expected OKAY (0)", bresp);

  property p_rresp_okay;
    @(posedge clk) disable iff (rst)
    (rvalid && rready) |-> (rresp == 2'b00);
  endproperty
  SVA_10_RRESP_OKAY: assert property (p_rresp_okay)
    else $error("SVA-10: RRESP=0x%0h, expected OKAY (0)", rresp);

  // ========================================================================
  // SVA-14: No RVALID before AR handshake completes
  // ========================================================================
  int unsigned ar_pending;

  always_ff @(posedge clk or posedge rst) begin
    if (rst)
      ar_pending <= 0;
    else begin
      case ({(arvalid && arready), (rvalid && rready && rlast)})
        2'b10: ar_pending <= ar_pending + 1;
        2'b01: ar_pending <= ar_pending - 1;
        default: ;  // 2'b11 cancels out, 2'b00 no change
      endcase
    end
  end

  property p_no_rvalid_without_ar;
    @(posedge clk) disable iff (rst)
    $rose(rvalid) |-> (ar_pending > 0);
  endproperty
  SVA_14_NO_RVALID_WITHOUT_AR: assert property (p_no_rvalid_without_ar)
    else $error("SVA-14: RVALID asserted with no pending AR transaction");

endmodule
