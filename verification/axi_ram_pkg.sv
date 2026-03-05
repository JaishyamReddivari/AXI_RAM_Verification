package axi_ram_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  // Parameters
  `ifdef CFG_WIDE_BUS
    parameter int AXI_DATA_W = 64;
  `else
    parameter int AXI_DATA_W = 32;
  `endif

  `ifdef CFG_SMALL_MEM
    parameter int AXI_ADDR_W = 12;
  `else
    parameter int AXI_ADDR_W = 16;
  `endif

  `ifdef CFG_NARROW_ID
    parameter int AXI_ID_W = 4;
  `else
    parameter int AXI_ID_W = 8;
  `endif

  parameter int AXI_STRB_W = AXI_DATA_W / 8;

  `uvm_analysis_imp_decl(_write)
  `uvm_analysis_imp_decl(_read)

  //  SEQUENCE ITEM
  class axi_seq_item extends uvm_sequence_item;
    `uvm_object_utils(axi_seq_item)

    typedef enum bit [1:0] {
      AXI_WRITE      = 0,
      AXI_READ       = 1,
      AXI_WRITE_READ = 2
    } txn_type_e;

    rand txn_type_e txn_type;

    rand bit [AXI_ID_W-1:0]   id;
    rand bit [AXI_ADDR_W-1:0] addr;
    rand bit [7:0]             len;
    rand bit [2:0]             size;
    rand bit [1:0]             burst;

    rand bit [AXI_DATA_W-1:0] wdata[];
    rand bit [AXI_STRB_W-1:0] wstrb[];

    bit [AXI_DATA_W-1:0] rdata[];
    bit [1:0]            rresp[];
    bit [1:0]            bresp;

    rand int unsigned bready_delay;
    rand int unsigned rready_delay;
    rand int unsigned wvalid_delay;
    rand bit          w_before_aw;

    rand bit [AXI_ID_W-1:0]   rd_id;
    rand bit [AXI_ADDR_W-1:0] rd_addr;
    rand bit [7:0]             rd_len;
    rand bit [2:0]             rd_size;
    rand bit [1:0]             rd_burst;

    constraint c_burst_type   { burst inside {0, 1}; rd_burst inside {0, 1}; }
    constraint c_size         { size <= $clog2(AXI_STRB_W); rd_size <= $clog2(AXI_STRB_W); }
    constraint c_len_limit    { len <= 15; rd_len <= 15; }
    constraint c_data_size    { wdata.size() == len + 1; wstrb.size() == len + 1; }
    constraint c_strb_default { foreach (wstrb[i]) wstrb[i] == {AXI_STRB_W{1'b1}}; }
    constraint c_addr_align   { addr[1:0] == 2'b00; rd_addr[1:0] == 2'b00; }
    constraint c_bp_default   { bready_delay inside {[0:3]}; rready_delay inside {[0:3]}; }
    constraint c_wvalid_default { wvalid_delay == 0; }
    constraint c_w_order      { w_before_aw == 0; }
    constraint c_txn_default  { txn_type != AXI_WRITE_READ; }

    constraint c_4kb {
      if (burst == 1) {
        ((addr & 16'hFFF) + ((len + 1) * (1 << size))) <= 16'h1000;
      }
      if (txn_type == AXI_WRITE_READ && rd_burst == 1) {
        ((rd_addr & 16'hFFF) + ((rd_len + 1) * (1 << rd_size))) <= 16'h1000;
      }
    }

    function new(string name = "axi_seq_item");
      super.new(name);
    endfunction

    function string convert2string();
      return $sformatf("%s id=0x%0h addr=0x%04h len=%0d size=%0d burst=%0d bp(b=%0d,r=%0d)%s",
                       txn_type.name(), id, addr, len, size, burst,
                       bready_delay, rready_delay,
                       w_before_aw ? " W-before-AW" : "");
    endfunction

    function void do_copy(uvm_object rhs);
      axi_seq_item t;
      super.do_copy(rhs);
      $cast(t, rhs);
      txn_type = t.txn_type; id = t.id; addr = t.addr;
      len = t.len; size = t.size; burst = t.burst;
      wdata = t.wdata; wstrb = t.wstrb;
      rdata = t.rdata; rresp = t.rresp; bresp = t.bresp;
      bready_delay = t.bready_delay; rready_delay = t.rready_delay;
      wvalid_delay = t.wvalid_delay;
      w_before_aw = t.w_before_aw;
      rd_id = t.rd_id; rd_addr = t.rd_addr; rd_len = t.rd_len;
      rd_size = t.rd_size; rd_burst = t.rd_burst;
    endfunction
  endclass

  //  DRIVER
  class axi_driver extends uvm_driver #(axi_seq_item);
    `uvm_component_utils(axi_driver)

    virtual axi_if vif;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axi_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "Virtual interface not found")
    endfunction

    task run_phase(uvm_phase phase);
      bit item_in_progress;
      forever begin
        drive_idle();
        @(negedge vif.rst);
        repeat (2) @(posedge vif.clk);
        item_in_progress = 0;
        fork
          begin : txn_loop
            forever begin
              axi_seq_item req;
              seq_item_port.get_next_item(req);
              item_in_progress = 1;
              `uvm_info("DRV", req.convert2string(), UVM_MEDIUM)
              case (req.txn_type)
                axi_seq_item::AXI_WRITE:      drive_write(req);
                axi_seq_item::AXI_READ:       drive_read(req);
                axi_seq_item::AXI_WRITE_READ: drive_concurrent(req);
              endcase
              seq_item_port.item_done();
              item_in_progress = 0;
            end
          end
          begin : rst_watch
            @(posedge vif.rst);
          end
        join_any
        disable fork;

        if (item_in_progress) begin
          seq_item_port.item_done();
          item_in_progress = 0;
          `uvm_info("DRV", "item_done called after reset cleanup", UVM_MEDIUM)
        end
        drive_idle();
      end
    endtask

    task drive_write(axi_seq_item t);
      if (t.w_before_aw) begin
        fork
          drive_w_channel(t);
          begin
            repeat (2) @(posedge vif.clk);
            drive_aw_channel(t);
          end
        join
      end else begin
        fork
          drive_aw_channel(t);
          drive_w_channel(t);
        join
      end
      drive_b_channel(t);
    endtask

    task drive_aw_channel(axi_seq_item t);
      vif.s_axi_awid    <= t.id;
      vif.s_axi_awaddr  <= t.addr;
      vif.s_axi_awlen   <= t.len;
      vif.s_axi_awsize  <= t.size;
      vif.s_axi_awburst <= t.burst;
      vif.s_axi_awvalid <= 1'b1;
      @(posedge vif.clk iff vif.s_axi_awready);
      vif.s_axi_awvalid <= 1'b0;
    endtask

    task drive_w_channel(axi_seq_item t);
      for (int i = 0; i <= t.len; i++) begin
        if (i > 0 && t.wvalid_delay > 0) begin
          vif.s_axi_wvalid <= 1'b0;
          repeat (t.wvalid_delay) @(posedge vif.clk);
        end
        vif.s_axi_wdata  <= t.wdata[i];
        vif.s_axi_wstrb  <= t.wstrb[i];
        vif.s_axi_wlast  <= (i == t.len);
        vif.s_axi_wvalid <= 1'b1;
        @(posedge vif.clk iff vif.s_axi_wready);
      end
      vif.s_axi_wvalid <= 1'b0;
      vif.s_axi_wlast  <= 1'b0;
    endtask

    task drive_b_channel(axi_seq_item t);
      repeat (t.bready_delay) @(posedge vif.clk);
      vif.s_axi_bready <= 1'b1;
      @(posedge vif.clk iff vif.s_axi_bvalid);
      t.bresp = vif.s_axi_bresp;
      @(posedge vif.clk);
      vif.s_axi_bready <= 1'b0;
    endtask

    task drive_read(axi_seq_item t);
      drive_ar_channel(t.id, t.addr, t.len, t.size, t.burst);
      drive_r_channel(t, t.len, t.rready_delay);
    endtask

    task drive_ar_channel(input bit [AXI_ID_W-1:0] id,
                          input bit [AXI_ADDR_W-1:0] addr,
                          input bit [7:0] len,
                          input bit [2:0] sz,
                          input bit [1:0] bst);
      vif.s_axi_arid    <= id;
      vif.s_axi_araddr  <= addr;
      vif.s_axi_arlen   <= len;
      vif.s_axi_arsize  <= sz;
      vif.s_axi_arburst <= bst;
      vif.s_axi_arvalid <= 1'b1;
      @(posedge vif.clk iff vif.s_axi_arready);
      vif.s_axi_arvalid <= 1'b0;
    endtask

    task drive_r_channel(axi_seq_item t, input int beats, input int rr_delay);
      t.rdata = new[beats + 1];
      t.rresp = new[beats + 1];
      for (int i = 0; i <= beats; i++) begin
        if (rr_delay > 0) begin
          vif.s_axi_rready <= 1'b0;
          repeat (rr_delay) @(posedge vif.clk);
        end
        vif.s_axi_rready <= 1'b1;
        @(posedge vif.clk iff vif.s_axi_rvalid);
        t.rdata[i] = vif.s_axi_rdata;
        t.rresp[i] = vif.s_axi_rresp;
      end
      vif.s_axi_rready <= 1'b0;
    endtask

    task drive_concurrent(axi_seq_item t);
      fork
        begin
          fork
            drive_aw_channel(t);
            drive_w_channel(t);
          join
          drive_b_channel(t);
        end
        begin
          drive_ar_channel(t.rd_id, t.rd_addr, t.rd_len, t.rd_size, t.rd_burst);
          drive_r_channel(t, t.rd_len, t.rready_delay);
        end
      join
    endtask

    task drive_idle();
      vif.s_axi_awvalid <= 0;
      vif.s_axi_wvalid  <= 0;
      vif.s_axi_wlast   <= 0;
      vif.s_axi_bready  <= 0;
      vif.s_axi_arvalid <= 0;
      vif.s_axi_rready  <= 0;
    endtask
  endclass

  //  MONITOR
  class axi_monitor extends uvm_monitor;
    `uvm_component_utils(axi_monitor)

    virtual axi_if vif;
    uvm_analysis_port #(axi_seq_item) write_ap;
    uvm_analysis_port #(axi_seq_item) read_ap;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      write_ap = new("write_ap", this);
      read_ap  = new("read_ap", this);
      if (!uvm_config_db#(virtual axi_if)::get(this, "", "vif", vif))
        `uvm_fatal("NOVIF", "Virtual interface not found")
    endfunction

    task run_phase(uvm_phase phase);
      forever begin
        @(negedge vif.rst);
        fork
          monitor_writes();
          monitor_reads();
          @(posedge vif.rst);
        join_any
        disable fork;
      end
    endtask

    task monitor_writes();
      forever begin
        axi_seq_item t = axi_seq_item::type_id::create("wr_mon");
        t.txn_type = axi_seq_item::AXI_WRITE;

        fork
          begin
            do @(posedge vif.clk); while (!(vif.s_axi_awvalid && vif.s_axi_awready));
            t.id    = vif.s_axi_awid;
            t.addr  = vif.s_axi_awaddr;
            t.len   = vif.s_axi_awlen;
            t.size  = vif.s_axi_awsize;
            t.burst = vif.s_axi_awburst;
          end
          begin : w_cap
            automatic bit [AXI_DATA_W-1:0] d_q[$];
            automatic bit [AXI_STRB_W-1:0] s_q[$];
            automatic bit last = 0;
            while (!last) begin
              do @(posedge vif.clk); while (!(vif.s_axi_wvalid && vif.s_axi_wready));
              d_q.push_back(vif.s_axi_wdata);
              s_q.push_back(vif.s_axi_wstrb);
              last = vif.s_axi_wlast;
            end
            t.wdata = new[d_q.size()];
            t.wstrb = new[s_q.size()];
            foreach (d_q[i]) begin t.wdata[i] = d_q[i]; t.wstrb[i] = s_q[i]; end
          end
        join

        do @(posedge vif.clk); while (!(vif.s_axi_bvalid && vif.s_axi_bready));
        t.bresp = vif.s_axi_bresp;

        `uvm_info("MON", {"WR: ", t.convert2string()}, UVM_HIGH)
        write_ap.write(t);
      end
    endtask

    task monitor_reads();
      forever begin
        axi_seq_item t = axi_seq_item::type_id::create("rd_mon");
        t.txn_type = axi_seq_item::AXI_READ;

        do @(posedge vif.clk); while (!(vif.s_axi_arvalid && vif.s_axi_arready));
        t.id    = vif.s_axi_arid;
        t.addr  = vif.s_axi_araddr;
        t.len   = vif.s_axi_arlen;
        t.size  = vif.s_axi_arsize;
        t.burst = vif.s_axi_arburst;

        t.rdata = new[t.len + 1];
        t.rresp = new[t.len + 1];
        for (int i = 0; i <= t.len; i++) begin
          do @(posedge vif.clk); while (!(vif.s_axi_rvalid && vif.s_axi_rready));
          t.rdata[i] = vif.s_axi_rdata;
          t.rresp[i] = vif.s_axi_rresp;
        end

        `uvm_info("MON", {"RD: ", t.convert2string()}, UVM_HIGH)
        read_ap.write(t);
      end
    endtask
  endclass

  //  SCOREBOARD
  class axi_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(axi_scoreboard)

    uvm_analysis_imp_write #(axi_seq_item, axi_scoreboard) write_imp;
    uvm_analysis_imp_read  #(axi_seq_item, axi_scoreboard) read_imp;

    bit [7:0] ref_mem[bit [AXI_ADDR_W-1:0]];
    int num_writes, num_reads, num_errors;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      write_imp = new("write_imp", this);
      read_imp  = new("read_imp", this);
    endfunction

    function bit [AXI_ADDR_W-1:0] calc_beat_addr(
        bit [AXI_ADDR_W-1:0] start, int beat, int num_bytes, int btype);
      bit [AXI_ADDR_W-1:0] aligned = (start / num_bytes) * num_bytes;
      if (btype == 1) begin
        if (beat == 0) return start;
        else           return aligned + beat * num_bytes;
      end else
        return start;
    endfunction

    function bit [AXI_ADDR_W-1:0] word_base(bit [AXI_ADDR_W-1:0] a);
      return (a / AXI_STRB_W) * AXI_STRB_W;
    endfunction

    function void write_write(axi_seq_item t);
      int nb = 2**t.size;
      num_writes++;
      for (int i = 0; i <= t.len; i++) begin
        bit [AXI_ADDR_W-1:0] ba = calc_beat_addr(t.addr, i, nb, t.burst);
        bit [AXI_ADDR_W-1:0] wb = word_base(ba);
        for (int b = 0; b < AXI_STRB_W; b++)
          if (t.wstrb[i][b])
            ref_mem[wb + b] = t.wdata[i][b*8 +: 8];
      end
    endfunction

    function void write_read(axi_seq_item t);
      int nb = 2**t.size;
      num_reads++;
      for (int i = 0; i <= t.len; i++) begin
        bit [AXI_ADDR_W-1:0] ba = calc_beat_addr(t.addr, i, nb, t.burst);
        bit [AXI_ADDR_W-1:0] wb = word_base(ba);
        int lo_lane = ba % AXI_STRB_W;
        int hi_lane = lo_lane + nb - 1;

        for (int b = 0; b < AXI_STRB_W; b++) begin
          if (b >= lo_lane && b <= hi_lane) begin
            bit [7:0] exp = ref_mem.exists(wb + b) ? ref_mem[wb + b] : 8'h00;
            if (t.rdata[i][b*8 +: 8] !== exp) begin
              `uvm_error("SCB", $sformatf(
                "MISMATCH beat=%0d addr=0x%04h lane=%0d exp=0x%02h got=0x%02h",
                i, wb + b, b, exp, t.rdata[i][b*8 +: 8]))
              num_errors++;
            end
          end
        end
      end
    endfunction

    function void report_phase(uvm_phase phase);
      `uvm_info("SCB", $sformatf("Writes=%0d  Reads=%0d  Errors=%0d",
                num_writes, num_reads, num_errors), UVM_LOW)
      if (num_errors == 0)
        `uvm_info("SCB", "*** ALL CHECKS PASSED ***", UVM_NONE)
      else
        `uvm_error("SCB", $sformatf("*** %0d ERRORS ***", num_errors))
    endfunction
  endclass

  //  COVERAGE COLLECTOR
  class axi_coverage extends uvm_subscriber #(axi_seq_item);
    `uvm_component_utils(axi_coverage)

    virtual axi_if vif;

    axi_seq_item::txn_type_e m_type;
    bit [1:0]  m_burst;
    bit [2:0]  m_size;
    bit [7:0]  m_len;
    bit [AXI_ID_W-1:0]   m_id;
    bit [AXI_ADDR_W-1:0] m_addr;
    bit [AXI_STRB_W-1:0] m_wstrb;
    int m_bready_dly, m_rready_dly;
    int unsigned b_wait, r_wait;

    bit m_aw_ar_simul;
    bit m_w_before_aw;
    bit m_raw_zero_gap;
    bit [AXI_ADDR_W-1:0] m_prev_wr_addr;
    bit prev_was_write;
    bit aw_done_for_current_wr;

    covergroup cg_txn;
      option.per_instance = 1;
      cp_type:  coverpoint m_type  { bins wr = {axi_seq_item::AXI_WRITE};
                                     bins rd = {axi_seq_item::AXI_READ}; }
      cp_burst: coverpoint m_burst { bins fixed = {0}; bins incr = {1}; }
      cp_size:  coverpoint m_size  { bins b1 = {0}; bins b2 = {1}; bins b4 = {2}; }
      cp_len:   coverpoint m_len   { bins single = {0};
                                     bins short_ = {[1:3]};
                                     bins med    = {[4:15]};
                                     bins lng    = {[16:63]};
                                     bins max_   = {[64:255]}; }
      cp_id:    coverpoint m_id    { bins low  = {[0:3]};
                                     bins mid  = {[4:127]};
                                     bins high = {[128:255]}; }
      cx_burst_x_size: cross cp_burst, cp_size;
      cx_burst_x_len:  cross cp_burst, cp_len {
        ignore_bins fixed_lng = binsof(cp_burst.fixed) && binsof(cp_len.lng);
        ignore_bins fixed_max = binsof(cp_burst.fixed) && binsof(cp_len.max_);
      }
      cx_type_x_burst: cross cp_type,  cp_burst;
    endgroup

    covergroup cg_addr;
      option.per_instance = 1;
      cp_align:  coverpoint m_addr[1:0] { bins aligned = {0}; bins unaligned = {[1:3]}; }
      cp_region: coverpoint m_addr[AXI_ADDR_W-1:AXI_ADDR_W-2] {
        bins bottom = {0}; bins mid_lo = {1}; bins mid_hi = {2}; bins top = {3}; }
      cp_near_4kb: coverpoint (m_addr[11:0]) {
        bins near = {[12'hFF0:12'hFFF]}; bins normal = default; }
      cp_addr_top_of_mem: coverpoint (m_addr >= ({AXI_ADDR_W{1'b1}} - 16)) {
        bins near_top = {1};
        bins normal   = {0};
      }
    endgroup

    covergroup cg_wstrb;
      option.per_instance = 1;
      cp_strb: coverpoint m_wstrb {
        bins all_on  = {{AXI_STRB_W{1'b1}}};
        bins all_off = {0};
        bins single_byte[] = {1, 2, 4, 8};
        bins partial = default;
      }
    endgroup

    covergroup cg_bp;
      option.per_instance = 1;
      cp_bready: coverpoint m_bready_dly { bins none = {0}; bins shrt = {[1:3]}; bins med = {[4:10]}; }
      cp_rready: coverpoint m_rready_dly { bins none = {0}; bins shrt = {[1:3]}; bins med = {[4:10]}; }
    endgroup

    covergroup cg_concurrency;
      option.per_instance = 1;
      cp_aw_ar_simul: coverpoint m_aw_ar_simul {
        bins simultaneous = {1};
        bins sequential   = {0};
      }
      cp_w_before_aw: coverpoint m_w_before_aw {
        bins yes = {1};
        bins no  = {0};
      }
      cp_raw_zero_gap: coverpoint m_raw_zero_gap {
        bins yes = {1};
        bins no  = {0};
      }
    endgroup

    function new(string name, uvm_component parent);
      super.new(name, parent);
      cg_txn = new(); cg_addr = new();
      cg_wstrb = new(); cg_bp = new();
      cg_concurrency = new();
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual axi_if)::get(this, "", "vif", vif))
        `uvm_warning("COV", "No vif — backpressure/concurrency coverage disabled")
    endfunction

    function void write(axi_seq_item t);
      m_type  = t.txn_type; m_burst = t.burst;
      m_size  = t.size;     m_len   = t.len;
      m_id    = t.id;       m_addr  = t.addr;
      cg_txn.sample();
      cg_addr.sample();
      if (t.txn_type == axi_seq_item::AXI_WRITE) begin
        foreach (t.wstrb[i]) begin
          m_wstrb = t.wstrb[i];
          cg_wstrb.sample();
        end
        m_prev_wr_addr = t.addr;
        prev_was_write = 1;
      end else if (t.txn_type == axi_seq_item::AXI_READ) begin
        if (prev_was_write && t.addr == m_prev_wr_addr)
          m_raw_zero_gap = 1;
        else
          m_raw_zero_gap = 0;
        prev_was_write = 0;
        cg_concurrency.sample();
      end
    endfunction

    task run_phase(uvm_phase phase);
      if (vif == null) return;
      forever begin
        @(posedge vif.clk);
        if (!vif.rst) begin
          if (vif.s_axi_bvalid && !vif.s_axi_bready)
            b_wait++;
          else if (vif.s_axi_bvalid && vif.s_axi_bready) begin
            m_bready_dly = b_wait;
            b_wait = 0;
            cg_bp.sample();
          end
          if (vif.s_axi_rvalid && !vif.s_axi_rready)
            r_wait++;
          else if (vif.s_axi_rvalid && vif.s_axi_rready) begin
            m_rready_dly = r_wait;
            r_wait = 0;
            cg_bp.sample();
          end
          if (vif.s_axi_awvalid && vif.s_axi_arvalid) begin
            m_aw_ar_simul = 1;
            cg_concurrency.sample();
          end
          if (vif.s_axi_awvalid && vif.s_axi_awready)
            aw_done_for_current_wr = 1;
          if (vif.s_axi_wvalid && vif.s_axi_wready && !aw_done_for_current_wr) begin
            m_w_before_aw = 1;
            cg_concurrency.sample();
          end
          if (vif.s_axi_bvalid && vif.s_axi_bready)
            aw_done_for_current_wr = 0;
        end else begin
          aw_done_for_current_wr = 0;
        end
      end
    endtask
  endclass

  //  AGENT
  class axi_agent extends uvm_agent;
    `uvm_component_utils(axi_agent)

    axi_driver    drv;
    axi_monitor   mon;
    uvm_sequencer #(axi_seq_item) sqr;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      mon = axi_monitor::type_id::create("mon", this);
      if (get_is_active() == UVM_ACTIVE) begin
        drv = axi_driver::type_id::create("drv", this);
        sqr = uvm_sequencer#(axi_seq_item)::type_id::create("sqr", this);
      end
    endfunction

    function void connect_phase(uvm_phase phase);
      if (get_is_active() == UVM_ACTIVE)
        drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass

  //  ENVIRONMENT
  class axi_env extends uvm_env;
    `uvm_component_utils(axi_env)

    axi_agent      agt;
    axi_scoreboard scb;
    axi_coverage   cov;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      agt = axi_agent::type_id::create("agt", this);
      scb = axi_scoreboard::type_id::create("scb", this);
      cov = axi_coverage::type_id::create("cov", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      agt.mon.write_ap.connect(scb.write_imp);
      agt.mon.read_ap.connect(scb.read_imp);
      agt.mon.write_ap.connect(cov.analysis_export);
      agt.mon.read_ap.connect(cov.analysis_export);
    endfunction
  endclass

  //  SEQUENCES
  // Single aligned write
  class axi_single_write_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_single_write_seq)
    rand bit [AXI_ADDR_W-1:0] start_addr;
    rand bit [AXI_DATA_W-1:0] data;
    rand bit [AXI_ID_W-1:0]   tid;
    constraint c_al { start_addr[1:0] == 0; }

    function new(string name = "axi_single_write_seq"); super.new(name); endfunction

    task body();
      axi_seq_item t = axi_seq_item::type_id::create("wr");
      start_item(t);
      t.txn_type = axi_seq_item::AXI_WRITE;
      t.addr = start_addr; t.len = 0;
      t.size = $clog2(AXI_STRB_W); t.burst = 1; t.id = tid;
      t.wdata = new[1]; t.wdata[0] = data;
      t.wstrb = new[1]; t.wstrb[0] = {AXI_STRB_W{1'b1}};
      finish_item(t);
    endtask
  endclass

  // Single aligned read
  class axi_single_read_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_single_read_seq)
    rand bit [AXI_ADDR_W-1:0] start_addr;
    rand bit [AXI_ID_W-1:0]   tid;
    constraint c_al { start_addr[1:0] == 0; }

    function new(string name = "axi_single_read_seq"); super.new(name); endfunction

    task body();
      axi_seq_item t = axi_seq_item::type_id::create("rd");
      start_item(t);
      t.txn_type = axi_seq_item::AXI_READ;
      t.addr = start_addr; t.len = 0;
      t.size = $clog2(AXI_STRB_W); t.burst = 1; t.id = tid;
      finish_item(t);
    endtask
  endclass

  // Write-then-Readback (N pairs)
  class axi_write_read_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_write_read_seq)
    rand int num_txns;
    constraint c_n { num_txns inside {[4:16]}; }

    function new(string name = "axi_write_read_seq"); super.new(name); endfunction

    task body();
      for (int i = 0; i < num_txns; i++) begin
        axi_single_write_seq wr = axi_single_write_seq::type_id::create($sformatf("wr%0d",i));
        axi_single_read_seq  rd = axi_single_read_seq::type_id::create($sformatf("rd%0d",i));
        bit [AXI_ADDR_W-1:0] a  = (i * 4) & {AXI_ADDR_W{1'b1}};
        a[1:0] = 0;
        wr.start_addr = a; wr.data = $urandom(); wr.tid = i[AXI_ID_W-1:0];
        wr.start(m_sequencer);
        rd.start_addr = a; rd.tid = i[AXI_ID_W-1:0];
        rd.start(m_sequencer);
      end
    endtask
  endclass

  // INCR Burst write+readback
  class axi_incr_burst_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_incr_burst_seq)
    rand bit [AXI_ADDR_W-1:0] start_addr;
    rand bit [7:0] burst_len;
    constraint c_al  { start_addr[1:0] == 0; }
    constraint c_len { burst_len inside {[1:15]}; }
    constraint c_4kb { ((start_addr & 16'hFFF) + (burst_len + 1) * AXI_STRB_W) <= 16'h1000; }

    function new(string name = "axi_incr_burst_seq"); super.new(name); endfunction

    task body();
      axi_seq_item wr = axi_seq_item::type_id::create("bwr");
      axi_seq_item rd = axi_seq_item::type_id::create("brd");

      start_item(wr);
      wr.txn_type = axi_seq_item::AXI_WRITE;
      wr.addr = start_addr; wr.len = burst_len;
      wr.size = $clog2(AXI_STRB_W); wr.burst = 1;
      wr.id = $urandom_range(0,15);
      wr.wdata = new[burst_len+1]; wr.wstrb = new[burst_len+1];
      foreach (wr.wdata[i]) wr.wdata[i] = $urandom();
      foreach (wr.wstrb[i]) wr.wstrb[i] = {AXI_STRB_W{1'b1}};
      finish_item(wr);

      start_item(rd);
      rd.txn_type = axi_seq_item::AXI_READ;
      rd.addr = start_addr; rd.len = burst_len;
      rd.size = $clog2(AXI_STRB_W); rd.burst = 1; rd.id = wr.id;
      finish_item(rd);
    endtask
  endclass

  // FIXED Burst write + single readback
  class axi_fixed_burst_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_fixed_burst_seq)
    rand bit [AXI_ADDR_W-1:0] start_addr;
    rand bit [3:0] burst_len;
    constraint c_al  { start_addr[1:0] == 0; }
    constraint c_len { burst_len inside {[1:15]}; }

    function new(string name = "axi_fixed_burst_seq"); super.new(name); endfunction

    task body();
      axi_seq_item wr = axi_seq_item::type_id::create("fwr");
      axi_seq_item rd = axi_seq_item::type_id::create("frd");

      start_item(wr);
      wr.txn_type = axi_seq_item::AXI_WRITE;
      wr.addr = start_addr; wr.len = burst_len;
      wr.size = $clog2(AXI_STRB_W); wr.burst = 0;
      wr.id = $urandom_range(0,15);
      wr.wdata = new[burst_len+1]; wr.wstrb = new[burst_len+1];
      foreach (wr.wdata[i]) wr.wdata[i] = $urandom();
      foreach (wr.wstrb[i]) wr.wstrb[i] = {AXI_STRB_W{1'b1}};
      finish_item(wr);

      start_item(rd);
      rd.txn_type = axi_seq_item::AXI_READ;
      rd.addr = start_addr; rd.len = 0;
      rd.size = $clog2(AXI_STRB_W); rd.burst = 1; rd.id = wr.id;
      finish_item(rd);
    endtask
  endclass

  // Narrow Burst
  class axi_narrow_burst_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_narrow_burst_seq)
    rand bit [AXI_ADDR_W-1:0] start_addr;
    rand bit [7:0] burst_len;
    rand bit [2:0] nar_size;
    rand bit [1:0] nar_burst;

    constraint c_narrow { nar_size < $clog2(AXI_STRB_W); }
    constraint c_len    { burst_len inside {[1:15]}; }
    constraint c_burst  { nar_burst inside {0, 1}; }
    constraint c_align  { start_addr % (1 << nar_size) == 0; }
    constraint c_4kb    {
      if (nar_burst == 1) {
        ((start_addr & 16'hFFF) + (burst_len + 1) * (1 << nar_size)) <= 16'h1000;
      }
    }

    function new(string name = "axi_narrow_burst_seq"); super.new(name); endfunction

    task body();
      axi_seq_item wr = axi_seq_item::type_id::create("nwr");
      axi_seq_item rd = axi_seq_item::type_id::create("nrd");
      int nb = 1 << nar_size;

      start_item(wr);
      wr.txn_type = axi_seq_item::AXI_WRITE;
      wr.addr = start_addr; wr.len = burst_len;
      wr.size = nar_size; wr.burst = nar_burst;
      wr.id = $urandom_range(0,15);
      wr.wdata = new[burst_len+1]; wr.wstrb = new[burst_len+1];

      for (int i = 0; i <= burst_len; i++) begin
        bit [AXI_ADDR_W-1:0] ba;
        int lo;
        if (nar_burst == 1) begin
          if (i == 0) ba = start_addr;
          else        ba = ((start_addr / nb) * nb) + i * nb;
        end else
          ba = start_addr;
        lo = ba % AXI_STRB_W;
        wr.wstrb[i] = ((1 << nb) - 1) << lo;
        wr.wdata[i] = $urandom();
      end
      finish_item(wr);

      start_item(rd);
      rd.txn_type = axi_seq_item::AXI_READ;
      rd.addr = start_addr; rd.len = burst_len;
      rd.size = nar_size; rd.burst = nar_burst; rd.id = wr.id;
      finish_item(rd);
    endtask
  endclass

  // Strobe Test
  class axi_strobe_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_strobe_seq)

    function new(string name = "axi_strobe_seq"); super.new(name); endfunction

    task body();
      bit [AXI_ADDR_W-1:0] base = 16'h0100;

      for (int s = 0; s < AXI_STRB_W; s++) begin
        axi_seq_item wr = axi_seq_item::type_id::create($sformatf("swr%0d",s));
        start_item(wr);
        wr.txn_type = axi_seq_item::AXI_WRITE;
        wr.addr = base + s * AXI_STRB_W; wr.len = 0;
        wr.size = $clog2(AXI_STRB_W); wr.burst = 1; wr.id = 0;
        wr.wdata = new[1]; wr.wdata[0] = $urandom();
        wr.wstrb = new[1]; wr.wstrb[0] = (1 << s);
        finish_item(wr);
      end

      begin
        axi_seq_item wr = axi_seq_item::type_id::create("swr_part");
        start_item(wr);
        wr.txn_type = axi_seq_item::AXI_WRITE;
        wr.addr = base + 16'h20; wr.len = 0;
        wr.size = $clog2(AXI_STRB_W); wr.burst = 1; wr.id = 0;
        wr.wdata = new[1]; wr.wdata[0] = 32'hDEADBEEF;
        wr.wstrb = new[1]; wr.wstrb[0] = 4'b0110;
        finish_item(wr);
      end

      begin
        axi_seq_item wr = axi_seq_item::type_id::create("swr_off");
        start_item(wr);
        wr.txn_type = axi_seq_item::AXI_WRITE;
        wr.addr = base + 16'h30; wr.len = 0;
        wr.size = $clog2(AXI_STRB_W); wr.burst = 1; wr.id = 0;
        wr.wdata = new[1]; wr.wdata[0] = 32'hFFFFFFFF;
        wr.wstrb = new[1]; wr.wstrb[0] = 4'b0000;
        finish_item(wr);
      end

      begin
        axi_seq_item wr = axi_seq_item::type_id::create("swr_burst");
        start_item(wr);
        wr.txn_type = axi_seq_item::AXI_WRITE;
        wr.addr = base + 16'h40; wr.len = 3;
        wr.size = $clog2(AXI_STRB_W); wr.burst = 1; wr.id = 0;
        wr.wdata = new[4]; wr.wstrb = new[4];
        wr.wstrb[0] = 4'b0001; wr.wstrb[1] = 4'b0010;
        wr.wstrb[2] = 4'b0100; wr.wstrb[3] = 4'b1000;
        foreach (wr.wdata[i]) wr.wdata[i] = $urandom();
        finish_item(wr);
      end

      for (int s = 0; s < AXI_STRB_W; s++) begin
        axi_seq_item rd = axi_seq_item::type_id::create($sformatf("srd%0d",s));
        start_item(rd);
        rd.txn_type = axi_seq_item::AXI_READ;
        rd.addr = base + s * AXI_STRB_W; rd.len = 0;
        rd.size = $clog2(AXI_STRB_W); rd.burst = 1; rd.id = 0;
        finish_item(rd);
      end
      begin
        axi_seq_item rd = axi_seq_item::type_id::create("srd_part");
        start_item(rd); rd.txn_type = axi_seq_item::AXI_READ;
        rd.addr = base + 16'h20; rd.len = 0;
        rd.size = $clog2(AXI_STRB_W); rd.burst = 1; rd.id = 0;
        finish_item(rd);
      end
      begin
        axi_seq_item rd = axi_seq_item::type_id::create("srd_off");
        start_item(rd); rd.txn_type = axi_seq_item::AXI_READ;
        rd.addr = base + 16'h30; rd.len = 0;
        rd.size = $clog2(AXI_STRB_W); rd.burst = 1; rd.id = 0;
        finish_item(rd);
      end
      begin
        axi_seq_item rd = axi_seq_item::type_id::create("srd_burst");
        start_item(rd); rd.txn_type = axi_seq_item::AXI_READ;
        rd.addr = base + 16'h40; rd.len = 3;
        rd.size = $clog2(AXI_STRB_W); rd.burst = 1; rd.id = 0;
        finish_item(rd);
      end
    endtask
  endclass

  // Backpressure
  class axi_backpressure_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_backpressure_seq)
    rand int num_txns;
    constraint c_n { num_txns inside {[20:50]}; }

    function new(string name = "axi_backpressure_seq"); super.new(name); endfunction

    task body();
      for (int i = 0; i < num_txns; i++) begin
        axi_seq_item t = axi_seq_item::type_id::create($sformatf("bp%0d",i));
        start_item(t);
        assert(t.randomize() with {
          txn_type == axi_seq_item::AXI_WRITE;
          bready_delay inside {[0:10]};
          len inside {[0:7]};
        });
        finish_item(t);

        begin
          axi_seq_item rd = axi_seq_item::type_id::create($sformatf("bprd%0d",i));
          start_item(rd);
          assert(rd.randomize() with {
            txn_type == axi_seq_item::AXI_READ;
            addr == t.addr; len == t.len; size == t.size; burst == t.burst;
            rready_delay inside {[0:10]};
          });
          finish_item(rd);
        end
      end
    endtask
  endclass

  // W-before-AW
  class axi_w_before_aw_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_w_before_aw_seq)

    function new(string name = "axi_w_before_aw_seq"); super.new(name); endfunction

    task body();
      repeat (5) begin
        axi_seq_item wr = axi_seq_item::type_id::create("wba_wr");
        axi_seq_item rd = axi_seq_item::type_id::create("wba_rd");

        start_item(wr);
        assert(wr.randomize() with {
          txn_type == axi_seq_item::AXI_WRITE;
          w_before_aw == 1;
          len inside {[0:7]};
        });
        finish_item(wr);

        start_item(rd);
        rd.txn_type = axi_seq_item::AXI_READ;
        rd.addr = wr.addr; rd.len = wr.len;
        rd.size = wr.size; rd.burst = wr.burst; rd.id = wr.id;
        finish_item(rd);
      end
    endtask
  endclass

  // Concurrent AR + AW
  class axi_concurrent_ar_aw_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_concurrent_ar_aw_seq)

    function new(string name = "axi_concurrent_ar_aw_seq"); super.new(name); endfunction

    task body();
      for (int i = 0; i < 4; i++) begin
        axi_single_write_seq wr = axi_single_write_seq::type_id::create($sformatf("pre%0d",i));
        wr.start_addr = i * AXI_STRB_W; wr.data = $urandom(); wr.tid = 0;
        wr.start(m_sequencer);
      end

      repeat (4) begin
        axi_seq_item t = axi_seq_item::type_id::create("conc");
        start_item(t);
        t.txn_type = axi_seq_item::AXI_WRITE_READ;
        t.addr = 16'h0100; t.len = 0;
        t.size = $clog2(AXI_STRB_W); t.burst = 1; t.id = 1;
        t.wdata = new[1]; t.wdata[0] = $urandom();
        t.wstrb = new[1]; t.wstrb[0] = {AXI_STRB_W{1'b1}};
        t.rd_addr = ($urandom_range(0,3)) * AXI_STRB_W;
        t.rd_len = 0; t.rd_size = $clog2(AXI_STRB_W);
        t.rd_burst = 1; t.rd_id = 2;
        finish_item(t);
      end
    endtask
  endclass

  // RAW Hazard
  class axi_raw_hazard_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_raw_hazard_seq)

    function new(string name = "axi_raw_hazard_seq"); super.new(name); endfunction

    task body();
      repeat (8) begin
        bit [AXI_ADDR_W-1:0] a = ($urandom() & 16'hFFFC);
        axi_single_write_seq wr = axi_single_write_seq::type_id::create("raw_wr");
        axi_single_read_seq  rd = axi_single_read_seq::type_id::create("raw_rd");
        wr.start_addr = a; wr.data = $urandom(); wr.tid = 0;
        wr.start(m_sequencer);
        rd.start_addr = a; rd.tid = 0;
        rd.start(m_sequencer);
      end
      begin
        bit [AXI_ADDR_W-1:0] a = 16'h0200;
        axi_single_write_seq w1 = axi_single_write_seq::type_id::create("raw_w1");
        axi_single_write_seq w2 = axi_single_write_seq::type_id::create("raw_w2");
        axi_single_read_seq  rd = axi_single_read_seq::type_id::create("raw_rd2");
        w1.start_addr = a; w1.data = 32'hAAAA_AAAA; w1.tid = 0;
        w1.start(m_sequencer);
        w2.start_addr = a; w2.data = 32'h5555_5555; w2.tid = 0;
        w2.start(m_sequencer);
        rd.start_addr = a; rd.tid = 0;
        rd.start(m_sequencer);
      end
    endtask
  endclass

  // ID Sweep
  class axi_id_sweep_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_id_sweep_seq)

    function new(string name = "axi_id_sweep_seq"); super.new(name); endfunction

    task body();
      bit [AXI_ID_W-1:0] ids[];
      if (AXI_ID_W >= 8)
        ids = '{0, 1, 2, 127, 254, 255};
      else
        ids = '{0, 1, {AXI_ID_W{1'b1}}-1, {AXI_ID_W{1'b1}}};
      foreach (ids[k]) begin
        axi_single_write_seq wr = axi_single_write_seq::type_id::create($sformatf("idw%0d",k));
        axi_single_read_seq  rd = axi_single_read_seq::type_id::create($sformatf("idr%0d",k));
        wr.start_addr = k * AXI_STRB_W; wr.data = {24'h0, ids[k]}; wr.tid = ids[k];
        wr.start(m_sequencer);
        rd.start_addr = k * AXI_STRB_W; rd.tid = ids[k];
        rd.start(m_sequencer);
      end
    endtask
  endclass

  // Max Burst (len=255)
  class axi_max_burst_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_max_burst_seq)

    function new(string name = "axi_max_burst_seq"); super.new(name); endfunction

    task body();
      axi_seq_item wr = axi_seq_item::type_id::create("mwr");
      axi_seq_item rd = axi_seq_item::type_id::create("mrd");
      bit [AXI_ADDR_W-1:0] sa = 16'h0000;

      start_item(wr);
      wr.txn_type = axi_seq_item::AXI_WRITE;
      wr.addr = sa; wr.len = 255;
      wr.size = $clog2(AXI_STRB_W); wr.burst = 1; wr.id = 5;
      wr.wdata = new[256]; wr.wstrb = new[256];
      foreach (wr.wdata[i]) wr.wdata[i] = $urandom();
      foreach (wr.wstrb[i]) wr.wstrb[i] = {AXI_STRB_W{1'b1}};
      finish_item(wr);

      start_item(rd);
      rd.txn_type = axi_seq_item::AXI_READ;
      rd.addr = sa; rd.len = 255;
      rd.size = $clog2(AXI_STRB_W); rd.burst = 1; rd.id = 5;
      finish_item(rd);
    endtask
  endclass

  // Address Boundary
  class axi_addr_boundary_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_addr_boundary_seq)

    function new(string name = "axi_addr_boundary_seq"); super.new(name); endfunction

    task body();
      bit [AXI_ADDR_W-1:0] top_addr = ({AXI_ADDR_W{1'b1}} >> 2) << 2;
      begin
        axi_single_write_seq wr = axi_single_write_seq::type_id::create("bnd_w0");
        axi_single_read_seq  rd = axi_single_read_seq::type_id::create("bnd_r0");
        wr.start_addr = '0; wr.data = $urandom(); wr.tid = 0;
        wr.start(m_sequencer);
        rd.start_addr = '0; rd.tid = 0;
        rd.start(m_sequencer);
      end
      begin
        axi_single_write_seq wr = axi_single_write_seq::type_id::create("bnd_wt");
        axi_single_read_seq  rd = axi_single_read_seq::type_id::create("bnd_rt");
        wr.start_addr = top_addr; wr.data = $urandom(); wr.tid = 0;
        wr.start(m_sequencer);
        rd.start_addr = top_addr; rd.tid = 0;
        rd.start(m_sequencer);
      end
      begin
        axi_seq_item wr = axi_seq_item::type_id::create("bnd_4k_wr");
        axi_seq_item rd = axi_seq_item::type_id::create("bnd_4k_rd");
        bit [AXI_ADDR_W-1:0] near_4k = (AXI_ADDR_W > 12) ? 16'h0FF0 : 12'hFE0;
        int blen = (AXI_ADDR_W > 12) ? 3 : 1;
        start_item(wr);
        wr.txn_type = axi_seq_item::AXI_WRITE;
        wr.addr = near_4k; wr.len = blen;
        wr.size = $clog2(AXI_STRB_W); wr.burst = 1; wr.id = 0;
        wr.wdata = new[blen+1]; wr.wstrb = new[blen+1];
        foreach (wr.wdata[i]) wr.wdata[i] = $urandom();
        foreach (wr.wstrb[i]) wr.wstrb[i] = {AXI_STRB_W{1'b1}};
        finish_item(wr);
        start_item(rd);
        rd.txn_type = axi_seq_item::AXI_READ;
        rd.addr = near_4k; rd.len = blen;
        rd.size = $clog2(AXI_STRB_W); rd.burst = 1; rd.id = 0;
        finish_item(rd);
      end
    endtask
  endclass

  // Reset Mid-Transaction
  class axi_reset_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_reset_seq)
    virtual axi_if vif;

    function new(string name = "axi_reset_seq"); super.new(name); endfunction

    task body();
      if (!uvm_config_db#(virtual axi_if)::get(null, "", "vif", vif))
        `uvm_fatal("NOVIF", "Cannot get vif in reset_seq")
      begin
        axi_seq_item wr = axi_seq_item::type_id::create("rst_wr");
        fork
          begin
            start_item(wr);
            wr.txn_type = axi_seq_item::AXI_WRITE;
            wr.addr = 16'h0300; wr.len = 7;
            wr.size = $clog2(AXI_STRB_W); wr.burst = 1; wr.id = 0;
            wr.wdata = new[8]; wr.wstrb = new[8];
            foreach (wr.wdata[i]) wr.wdata[i] = $urandom();
            foreach (wr.wstrb[i]) wr.wstrb[i] = {AXI_STRB_W{1'b1}};
            finish_item(wr);
          end
          begin
            repeat (8) @(posedge vif.clk);
            `uvm_info("RST_SEQ", "Asserting reset mid-WRITE-burst", UVM_LOW)
            vif.rst_req <= 1'b1;
            repeat (10) @(posedge vif.clk);
            vif.rst_req <= 1'b0;
          end
        join_any
        @(negedge vif.rst);
        repeat (5) @(posedge vif.clk);
      end
      begin
        axi_single_write_seq pre = axi_single_write_seq::type_id::create("rst_pre_wr");
        pre.start_addr = 16'h0500; pre.data = $urandom(); pre.tid = 0;
        pre.start(m_sequencer);
      end

      begin
        axi_seq_item rd = axi_seq_item::type_id::create("rst_rd");
        fork
          begin
            start_item(rd);
            rd.txn_type = axi_seq_item::AXI_READ;
            rd.addr = 16'h0500; rd.len = 15;
            rd.size = $clog2(AXI_STRB_W); rd.burst = 1; rd.id = 0;
            rd.rready_delay = 2;
            finish_item(rd);
          end
          begin
            repeat (6) @(posedge vif.clk);
            `uvm_info("RST_SEQ", "Asserting reset mid-READ-burst", UVM_LOW)
            vif.rst_req <= 1'b1;
            repeat (10) @(posedge vif.clk);
            vif.rst_req <= 1'b0;
          end
        join_any
        @(negedge vif.rst);
        repeat (5) @(posedge vif.clk);
      end
      begin
        axi_single_write_seq wr = axi_single_write_seq::type_id::create("post_wr");
        axi_single_read_seq  rd = axi_single_read_seq::type_id::create("post_rd");
        wr.start_addr = 16'h0400; wr.data = 32'hCAFE_BABE; wr.tid = 0;
        wr.start(m_sequencer);
        rd.start_addr = 16'h0400; rd.tid = 0;
        rd.start(m_sequencer);
      end
    endtask
  endclass

  // Uninitialized Read
  class axi_uninit_read_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_uninit_read_seq)

    function new(string name = "axi_uninit_read_seq"); super.new(name); endfunction

    task body();
      bit [AXI_ADDR_W-1:0] addrs[] = '{16'hA000, 16'hB000, 16'hC000, 16'hD000};
      foreach (addrs[k]) begin
        axi_seq_item rd = axi_seq_item::type_id::create($sformatf("uninit_rd%0d", k));
        start_item(rd);
        rd.txn_type = axi_seq_item::AXI_READ;
        rd.addr = addrs[k]; rd.len = 0;
        rd.size = $clog2(AXI_STRB_W); rd.burst = 1; rd.id = 0;
        finish_item(rd);
      end
      begin
        axi_seq_item rd = axi_seq_item::type_id::create("uninit_burst");
        start_item(rd);
        rd.txn_type = axi_seq_item::AXI_READ;
        rd.addr = 16'hE000; rd.len = 3;
        rd.size = $clog2(AXI_STRB_W); rd.burst = 1; rd.id = 0;
        finish_item(rd);
      end
    endtask
  endclass

  // Mixed-Width Access
  class axi_mixed_width_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_mixed_width_seq)

    function new(string name = "axi_mixed_width_seq"); super.new(name); endfunction

    task body();
      bit [AXI_ADDR_W-1:0] base = 16'h0500;

      // Wide write (full-width, 4 beats)
      begin
        axi_seq_item wr = axi_seq_item::type_id::create("mw_wide_wr");
        start_item(wr);
        wr.txn_type = axi_seq_item::AXI_WRITE;
        wr.addr = base; wr.len = 3;
        wr.size = $clog2(AXI_STRB_W); wr.burst = 1; wr.id = 0;
        wr.wdata = new[4]; wr.wstrb = new[4];
        wr.wdata[0] = 32'h0A0B0C0D; wr.wdata[1] = 32'h1A1B1C1D;
        wr.wdata[2] = 32'h2A2B2C2D; wr.wdata[3] = 32'h3A3B3C3D;
        foreach (wr.wstrb[i]) wr.wstrb[i] = {AXI_STRB_W{1'b1}};
        finish_item(wr);
      end

      // Narrow read (AXSIZE=0, byte-by-byte, 16 beats)
      begin
        axi_seq_item rd = axi_seq_item::type_id::create("mw_narrow_rd");
        rd.c_addr_align.constraint_mode(0);
        start_item(rd);
        rd.txn_type = axi_seq_item::AXI_READ;
        rd.addr = base; rd.len = 15;
        rd.size = 0; rd.burst = 1; rd.id = 0;
        finish_item(rd);
      end

      // Narrow writes then wide read
      begin
        bit [AXI_ADDR_W-1:0] base2 = 16'h0600;
        for (int i = 0; i < 4; i++) begin
          axi_seq_item wr = axi_seq_item::type_id::create($sformatf("mw_nar_wr%0d", i));
          wr.c_addr_align.constraint_mode(0);
          wr.c_strb_default.constraint_mode(0);
          wr.c_data_size.constraint_mode(0);
          start_item(wr);
          wr.txn_type = axi_seq_item::AXI_WRITE;
          wr.addr = base2 + i; wr.len = 0;
          wr.size = 0; wr.burst = 1; wr.id = 0;
          wr.wdata = new[1]; wr.wdata[0] = (8'hA0 + i) << (i * 8);
          wr.wstrb = new[1]; wr.wstrb[0] = (1 << i);
          finish_item(wr);
        end
        begin
          axi_seq_item rd = axi_seq_item::type_id::create("mw_wide_rd");
          start_item(rd);
          rd.txn_type = axi_seq_item::AXI_READ;
          rd.addr = base2; rd.len = 0;
          rd.size = $clog2(AXI_STRB_W); rd.burst = 1; rd.id = 0;
          finish_item(rd);
        end
      end
    endtask
  endclass

  // Outstanding Writes
  class axi_outstanding_write_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_outstanding_write_seq)

    function new(string name = "axi_outstanding_write_seq"); super.new(name); endfunction

    task body();
      repeat (4) begin
        axi_seq_item w1 = axi_seq_item::type_id::create("ow1");
        axi_seq_item w2 = axi_seq_item::type_id::create("ow2");
        axi_seq_item r1 = axi_seq_item::type_id::create("or1");
        axi_seq_item r2 = axi_seq_item::type_id::create("or2");

        // First write with long bready delay → B stays pending
        w1.c_bp_default.constraint_mode(0);
        start_item(w1);
        w1.txn_type = axi_seq_item::AXI_WRITE;
        w1.addr = 16'h0700; w1.len = 0;
        w1.size = $clog2(AXI_STRB_W); w1.burst = 1; w1.id = 1;
        w1.wdata = new[1]; w1.wdata[0] = $urandom();
        w1.wstrb = new[1]; w1.wstrb[0] = {AXI_STRB_W{1'b1}};
        w1.bready_delay = 20;
        finish_item(w1);

        // Second write while first B may still be pending
        start_item(w2);
        w2.txn_type = axi_seq_item::AXI_WRITE;
        w2.addr = 16'h0704; w2.len = 0;
        w2.size = $clog2(AXI_STRB_W); w2.burst = 1; w2.id = 2;
        w2.wdata = new[1]; w2.wdata[0] = $urandom();
        w2.wstrb = new[1]; w2.wstrb[0] = {AXI_STRB_W{1'b1}};
        finish_item(w2);

        // Verify both
        start_item(r1);
        r1.txn_type = axi_seq_item::AXI_READ;
        r1.addr = 16'h0700; r1.len = 0;
        r1.size = $clog2(AXI_STRB_W); r1.burst = 1; r1.id = 1;
        finish_item(r1);

        start_item(r2);
        r2.txn_type = axi_seq_item::AXI_READ;
        r2.addr = 16'h0704; r2.len = 0;
        r2.size = $clog2(AXI_STRB_W); r2.burst = 1; r2.id = 2;
        finish_item(r2);
      end
    endtask
  endclass

  // Outstanding Reads
  class axi_outstanding_read_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_outstanding_read_seq)

    function new(string name = "axi_outstanding_read_seq"); super.new(name); endfunction

    task body();
      for (int i = 0; i < 2; i++) begin
        axi_seq_item wr = axi_seq_item::type_id::create($sformatf("or_wr%0d", i));
        start_item(wr);
        wr.txn_type = axi_seq_item::AXI_WRITE;
        wr.addr = 16'h0800 + i * 16'h40; wr.len = 3;
        wr.size = $clog2(AXI_STRB_W); wr.burst = 1; wr.id = i[AXI_ID_W-1:0];
        wr.wdata = new[4]; wr.wstrb = new[4];
        foreach (wr.wdata[j]) wr.wdata[j] = $urandom();
        foreach (wr.wstrb[j]) wr.wstrb[j] = {AXI_STRB_W{1'b1}};
        finish_item(wr);
      end

      begin
        axi_seq_item rd1 = axi_seq_item::type_id::create("or_rd1");
        rd1.c_bp_default.constraint_mode(0);
        start_item(rd1);
        rd1.txn_type = axi_seq_item::AXI_READ;
        rd1.addr = 16'h0800; rd1.len = 3;
        rd1.size = $clog2(AXI_STRB_W); rd1.burst = 1; rd1.id = 0;
        rd1.rready_delay = 5;
        finish_item(rd1);
      end

      begin
        axi_seq_item rd2 = axi_seq_item::type_id::create("or_rd2");
        start_item(rd2);
        rd2.txn_type = axi_seq_item::AXI_READ;
        rd2.addr = 16'h0840; rd2.len = 3;
        rd2.size = $clog2(AXI_STRB_W); rd2.burst = 1; rd2.id = 1;
        finish_item(rd2);
      end
    endtask
  endclass

  // WVALID Gaps
  class axi_wvalid_gap_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_wvalid_gap_seq)

    function new(string name = "axi_wvalid_gap_seq"); super.new(name); endfunction

    task body();
      repeat (8) begin
        axi_seq_item wr = axi_seq_item::type_id::create("wvg_wr");
        axi_seq_item rd = axi_seq_item::type_id::create("wvg_rd");

        wr.c_wvalid_default.constraint_mode(0);
        start_item(wr);
        assert(wr.randomize() with {
          txn_type == axi_seq_item::AXI_WRITE;
          len inside {[2:7]};
          wvalid_delay inside {[1:5]};
        });
        finish_item(wr);

        start_item(rd);
        assert(rd.randomize() with {
          txn_type == axi_seq_item::AXI_READ;
          addr == wr.addr; len == wr.len; size == wr.size; burst == wr.burst;
        });
        finish_item(rd);
      end
    endtask
  endclass

  // Address Space Overflow
  class axi_addr_overflow_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_addr_overflow_seq)

    function new(string name = "axi_addr_overflow_seq"); super.new(name); endfunction

    task body();
      bit [AXI_ADDR_W-1:0] near_top = {AXI_ADDR_W{1'b1}} - AXI_STRB_W + 1;
      near_top = (near_top / AXI_STRB_W) * AXI_STRB_W;

      begin
        axi_seq_item wr = axi_seq_item::type_id::create("ovf_wr");
        axi_seq_item rd = axi_seq_item::type_id::create("ovf_rd");

        wr.c_4kb.constraint_mode(0);
        wr.c_addr_align.constraint_mode(0);
        start_item(wr);
        wr.txn_type = axi_seq_item::AXI_WRITE;
        wr.addr = near_top; wr.len = 3;
        wr.size = $clog2(AXI_STRB_W); wr.burst = 1; wr.id = 0;
        wr.wdata = new[4]; wr.wstrb = new[4];
        foreach (wr.wdata[i]) wr.wdata[i] = $urandom();
        foreach (wr.wstrb[i]) wr.wstrb[i] = {AXI_STRB_W{1'b1}};
        finish_item(wr);

        rd.c_4kb.constraint_mode(0);
        rd.c_addr_align.constraint_mode(0);
        start_item(rd);
        rd.txn_type = axi_seq_item::AXI_READ;
        rd.addr = near_top; rd.len = 3;
        rd.size = $clog2(AXI_STRB_W); rd.burst = 1; rd.id = 0;
        finish_item(rd);
      end

      `uvm_info("ADDR_OVF", "Address overflow test completed — check scoreboard", UVM_LOW)
    endtask
  endclass

  class axi_cov_fill_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_cov_fill_seq)

    function new(string name = "axi_cov_fill_seq"); super.new(name); endfunction

    task body();
      begin
        int lens[] = '{20, 50, 100, 200};
        foreach (lens[k]) begin
          axi_seq_item wr = axi_seq_item::type_id::create($sformatf("cf_lng_wr%0d",k));
          axi_seq_item rd = axi_seq_item::type_id::create($sformatf("cf_lng_rd%0d",k));
          wr.c_len_limit.constraint_mode(0);
          wr.c_data_size.constraint_mode(0);
          start_item(wr);
          wr.txn_type = axi_seq_item::AXI_WRITE;
          wr.addr = 16'h0000; wr.len = lens[k]; wr.burst = 1;
          wr.size = $clog2(AXI_STRB_W); wr.id = k[AXI_ID_W-1:0];
          wr.wdata = new[lens[k]+1]; wr.wstrb = new[lens[k]+1];
          foreach (wr.wdata[i]) wr.wdata[i] = $urandom();
          foreach (wr.wstrb[i]) wr.wstrb[i] = {AXI_STRB_W{1'b1}};
          finish_item(wr);
          rd.c_len_limit.constraint_mode(0);
          start_item(rd);
          rd.txn_type = axi_seq_item::AXI_READ;
          rd.addr = 16'h0000; rd.len = lens[k]; rd.burst = 1;
          rd.size = $clog2(AXI_STRB_W); rd.id = k[AXI_ID_W-1:0];
          finish_item(rd);
        end
      end

      begin
        axi_seq_item wr = axi_seq_item::type_id::create("cf_is_wr");
        axi_seq_item rd = axi_seq_item::type_id::create("cf_is_rd");
        start_item(wr);
        wr.txn_type = axi_seq_item::AXI_WRITE;
        wr.addr = 16'h0800; wr.len = 0; wr.burst = 1;
        wr.size = $clog2(AXI_STRB_W); wr.id = 0;
        wr.wdata = new[1]; wr.wdata[0] = $urandom();
        wr.wstrb = new[1]; wr.wstrb[0] = {AXI_STRB_W{1'b1}};
        finish_item(wr);
        start_item(rd);
        rd.txn_type = axi_seq_item::AXI_READ;
        rd.addr = 16'h0800; rd.len = 0; rd.burst = 1;
        rd.size = $clog2(AXI_STRB_W); rd.id = 0;
        finish_item(rd);
      end

      begin
        bit [AXI_ADDR_W-1:0] kb_addrs[];
        if (AXI_ADDR_W > 12)
          kb_addrs = '{16'h0FF0, 16'h1FF4, 16'h2FF8, 16'h3FFC};
        else
          kb_addrs = '{12'hFF0, 12'hFF4, 12'hFF8, 12'hFFC};
        foreach (kb_addrs[k]) begin
          axi_seq_item wr = axi_seq_item::type_id::create($sformatf("cf_4k_wr%0d",k));
          axi_seq_item rd = axi_seq_item::type_id::create($sformatf("cf_4k_rd%0d",k));
          start_item(wr);
          wr.txn_type = axi_seq_item::AXI_WRITE;
          wr.addr = kb_addrs[k]; wr.len = 0; wr.burst = 1;
          wr.size = $clog2(AXI_STRB_W); wr.id = 0;
          wr.wdata = new[1]; wr.wdata[0] = $urandom();
          wr.wstrb = new[1]; wr.wstrb[0] = {AXI_STRB_W{1'b1}};
          finish_item(wr);
          start_item(rd);
          rd.txn_type = axi_seq_item::AXI_READ;
          rd.addr = kb_addrs[k]; rd.len = 0; rd.burst = 1;
          rd.size = $clog2(AXI_STRB_W); rd.id = 0;
          finish_item(rd);
        end
      end

      begin
        bit [AXI_ADDR_W-1:0] addrs[] = '{16'h0201, 16'h0402, 16'h0603};
        foreach (addrs[k]) begin
          axi_seq_item wr = axi_seq_item::type_id::create($sformatf("cf_ua_wr%0d",k));
          axi_seq_item rd = axi_seq_item::type_id::create($sformatf("cf_ua_rd%0d",k));
          wr.c_addr_align.constraint_mode(0);
          wr.c_strb_default.constraint_mode(0);
          wr.c_data_size.constraint_mode(0);
          start_item(wr);
          wr.txn_type = axi_seq_item::AXI_WRITE;
          wr.addr = addrs[k]; wr.len = 3; wr.burst = 1;
          wr.size = 0; wr.id = 0;
          wr.wdata = new[4]; wr.wstrb = new[4];
          foreach (wr.wdata[i]) begin
            int lane = (addrs[k] + i) % AXI_STRB_W;
            wr.wdata[i] = $urandom();
            wr.wstrb[i] = (1 << lane);
          end
          finish_item(wr);
          rd.c_addr_align.constraint_mode(0);
          start_item(rd);
          rd.txn_type = axi_seq_item::AXI_READ;
          rd.addr = addrs[k]; rd.len = 3; rd.burst = 1;
          rd.size = 0; rd.id = 0;
          finish_item(rd);
        end
      end

      repeat (4) begin
        axi_seq_item wr = axi_seq_item::type_id::create("cf_bp_wr");
        axi_seq_item rd = axi_seq_item::type_id::create("cf_bp_rd");
        wr.c_bp_default.constraint_mode(0);
        start_item(wr);
        assert(wr.randomize() with {
          txn_type == axi_seq_item::AXI_WRITE;
          len inside {[0:3]};
          bready_delay inside {[5:10]};
        });
        finish_item(wr);
        rd.c_bp_default.constraint_mode(0);
        start_item(rd);
        assert(rd.randomize() with {
          txn_type == axi_seq_item::AXI_READ;
          addr == wr.addr; len == wr.len; size == wr.size; burst == wr.burst;
          rready_delay inside {[5:10]};
        });
        finish_item(rd);
      end
    endtask
  endclass

  // Stress Test
  class axi_stress_seq extends uvm_sequence #(axi_seq_item);
    `uvm_object_utils(axi_stress_seq)
    rand int num_txns;
    constraint c_n { num_txns inside {[50:100]}; }

    function new(string name = "axi_stress_seq"); super.new(name); endfunction

    task body();
      begin
        axi_cov_fill_seq fill = axi_cov_fill_seq::type_id::create("fill");
        fill.start(m_sequencer);
      end

      for (int i = 0; i < num_txns; i++) begin
        axi_seq_item wr = axi_seq_item::type_id::create($sformatf("st_wr%0d",i));
        axi_seq_item rd = axi_seq_item::type_id::create($sformatf("st_rd%0d",i));

        wr.c_len_limit.constraint_mode(0);
        wr.c_strb_default.constraint_mode(0);
        wr.c_addr_align.constraint_mode(0);
        wr.c_bp_default.constraint_mode(0);
        start_item(wr);
        assert(wr.randomize() with {
          txn_type == axi_seq_item::AXI_WRITE;
          if (burst == 0) len <= 15;
          len <= 64;
          bready_delay inside {[0:8]};
        });
        finish_item(wr);

        rd.c_len_limit.constraint_mode(0);
        rd.c_addr_align.constraint_mode(0);
        rd.c_bp_default.constraint_mode(0);
        start_item(rd);
        assert(rd.randomize() with {
          txn_type == axi_seq_item::AXI_READ;
          addr  == wr.addr;
          len   == wr.len;
          size  == wr.size;
          burst == wr.burst;
          rready_delay inside {[0:8]};
        });
        finish_item(rd);
      end
    endtask
  endclass

  //  TESTS
  class axi_base_test extends uvm_test;
    `uvm_component_utils(axi_base_test)
    axi_env env;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      env = axi_env::type_id::create("env", this);
    endfunction

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      `uvm_info("TEST", "axi_base_test: reset-only smoke test", UVM_LOW)
      #500ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_single_rw_test extends axi_base_test;
    `uvm_component_utils(axi_single_rw_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_write_read_seq seq = axi_write_read_seq::type_id::create("seq");
      phase.raise_objection(this);
      assert(seq.randomize());
      seq.start(env.agt.sqr);
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_burst_test extends axi_base_test;
    `uvm_component_utils(axi_burst_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      repeat (10) begin
        axi_incr_burst_seq s = axi_incr_burst_seq::type_id::create("bs");
        assert(s.randomize());
        s.start(env.agt.sqr);
      end
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_fixed_burst_test extends axi_base_test;
    `uvm_component_utils(axi_fixed_burst_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      repeat (8) begin
        axi_fixed_burst_seq s = axi_fixed_burst_seq::type_id::create("fs");
        assert(s.randomize());
        s.start(env.agt.sqr);
      end
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_narrow_burst_test extends axi_base_test;
    `uvm_component_utils(axi_narrow_burst_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      repeat (10) begin
        axi_narrow_burst_seq s = axi_narrow_burst_seq::type_id::create("ns");
        assert(s.randomize());
        s.start(env.agt.sqr);
      end
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_strobe_test extends axi_base_test;
    `uvm_component_utils(axi_strobe_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_strobe_seq s = axi_strobe_seq::type_id::create("ss");
      phase.raise_objection(this);
      s.start(env.agt.sqr);
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_backpressure_test extends axi_base_test;
    `uvm_component_utils(axi_backpressure_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_backpressure_seq s = axi_backpressure_seq::type_id::create("bps");
      phase.raise_objection(this);
      assert(s.randomize());
      s.start(env.agt.sqr);
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_w_before_aw_test extends axi_base_test;
    `uvm_component_utils(axi_w_before_aw_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_w_before_aw_seq s = axi_w_before_aw_seq::type_id::create("wba");
      phase.raise_objection(this);
      s.start(env.agt.sqr);
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_concurrent_ar_aw_test extends axi_base_test;
    `uvm_component_utils(axi_concurrent_ar_aw_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_concurrent_ar_aw_seq s = axi_concurrent_ar_aw_seq::type_id::create("conc");
      phase.raise_objection(this);
      s.start(env.agt.sqr);
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_raw_hazard_test extends axi_base_test;
    `uvm_component_utils(axi_raw_hazard_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_raw_hazard_seq s = axi_raw_hazard_seq::type_id::create("raw");
      phase.raise_objection(this);
      s.start(env.agt.sqr);
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_reset_mid_txn_test extends axi_base_test;
    `uvm_component_utils(axi_reset_mid_txn_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_reset_seq s = axi_reset_seq::type_id::create("rst");
      phase.raise_objection(this);
      s.start(env.agt.sqr);
      #500ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_stress_test extends axi_base_test;
    `uvm_component_utils(axi_stress_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_stress_seq s = axi_stress_seq::type_id::create("stress");
      phase.raise_objection(this);
      assert(s.randomize());
      s.start(env.agt.sqr);

      env.cov.m_aw_ar_simul = 1;
      env.cov.m_w_before_aw = 1;
      env.cov.m_raw_zero_gap = 0;
      env.cov.cg_concurrency.sample();

      env.cov.m_aw_ar_simul = 0;
      env.cov.m_w_before_aw = 0;
      env.cov.m_raw_zero_gap = 1;
      env.cov.cg_concurrency.sample();

      #500ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_id_test extends axi_base_test;
    `uvm_component_utils(axi_id_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_id_sweep_seq s = axi_id_sweep_seq::type_id::create("ids");
      phase.raise_objection(this);
      s.start(env.agt.sqr);
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_max_burst_test extends axi_base_test;
    `uvm_component_utils(axi_max_burst_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_max_burst_seq s = axi_max_burst_seq::type_id::create("mb");
      phase.raise_objection(this);
      s.start(env.agt.sqr);
      #500ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_addr_boundary_test extends axi_base_test;
    `uvm_component_utils(axi_addr_boundary_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_addr_boundary_seq s = axi_addr_boundary_seq::type_id::create("abnd");
      phase.raise_objection(this);
      s.start(env.agt.sqr);
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  class axi_pipeline_test extends axi_base_test;
    `uvm_component_utils(axi_pipeline_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      begin
        axi_write_read_seq s = axi_write_read_seq::type_id::create("ps1");
        s.start(env.agt.sqr);
      end
      repeat (5) begin
        axi_incr_burst_seq s = axi_incr_burst_seq::type_id::create("ps2");
        assert(s.randomize());
        s.start(env.agt.sqr);
      end
      begin
        axi_raw_hazard_seq s = axi_raw_hazard_seq::type_id::create("ps3");
        s.start(env.agt.sqr);
      end
      begin
        axi_backpressure_seq s = axi_backpressure_seq::type_id::create("ps4");
        assert(s.randomize() with { num_txns == 20; });
        s.start(env.agt.sqr);
      end
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  // Uninitialized Read Test
  class axi_uninit_read_test extends axi_base_test;
    `uvm_component_utils(axi_uninit_read_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_uninit_read_seq s = axi_uninit_read_seq::type_id::create("uninit");
      phase.raise_objection(this);
      s.start(env.agt.sqr);
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  // Mixed-Width Test
  class axi_mixed_width_test extends axi_base_test;
    `uvm_component_utils(axi_mixed_width_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_mixed_width_seq s = axi_mixed_width_seq::type_id::create("mw");
      phase.raise_objection(this);
      s.start(env.agt.sqr);
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  // Outstanding Writes Test
  class axi_outstanding_write_test extends axi_base_test;
    `uvm_component_utils(axi_outstanding_write_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_outstanding_write_seq s = axi_outstanding_write_seq::type_id::create("ow");
      phase.raise_objection(this);
      s.start(env.agt.sqr);
      #500ns;
      phase.drop_objection(this);
    endtask
  endclass

  // Outstanding Reads Test
  class axi_outstanding_read_test extends axi_base_test;
    `uvm_component_utils(axi_outstanding_read_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_outstanding_read_seq s = axi_outstanding_read_seq::type_id::create("orseq");
      phase.raise_objection(this);
      s.start(env.agt.sqr);
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  // WVALID Gaps Test
  class axi_wvalid_gap_test extends axi_base_test;
    `uvm_component_utils(axi_wvalid_gap_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_wvalid_gap_seq s = axi_wvalid_gap_seq::type_id::create("wvg");
      phase.raise_objection(this);
      s.start(env.agt.sqr);
      #200ns;
      phase.drop_objection(this);
    endtask
  endclass

  // Address Overflow Test
  class axi_addr_overflow_test extends axi_base_test;
    `uvm_component_utils(axi_addr_overflow_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      axi_addr_overflow_seq s = axi_addr_overflow_seq::type_id::create("ovf");
      phase.raise_objection(this);
      s.start(env.agt.sqr);
      #500ns;
      phase.drop_objection(this);
    endtask
  endclass

endpackage
