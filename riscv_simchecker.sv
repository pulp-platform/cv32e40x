// Copyright 2015 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the “License”); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.

////////////////////////////////////////////////////////////////////////////////
// Engineer:       Andreas Traber - atraber@iis.ee.ethz.ch                    //
//                                                                            //
// Additional contributions by:                                               //
//                                                                            //
// Design Name:    RISC-V Tracer                                              //
// Project Name:   RI5CY                                                      //
// Language:       SystemVerilog                                              //
//                                                                            //
// Description:    Compares the executed instructions with a golden model     //
//                                                                            //
////////////////////////////////////////////////////////////////////////////////


import "DPI-C" function chandle riscv_checker_init(input int boot_addr, input int core_id, input int cluster_id);
import "DPI-C" function int     riscv_checker_step(input chandle cpu, input logic [31:0] pc, input logic [31:0] instr);
import "DPI-C" function void    riscv_checker_mem_access(input chandle cpu, input int we, input logic [31:0] addr, input logic [31:0] data);
import "DPI-C" function void    riscv_checker_reg_access(input chandle cpu, input logic [31:0] addr, input logic [31:0] data);

module riscv_simchecker
(
  // Clock and Reset
  input  logic        clk,
  input  logic        rst_n,

  input  logic [4:0]  core_id,
  input  logic [4:0]  cluster_id,

  input  logic [31:0] pc,
  input  logic [31:0] instr,
  input  logic        id_valid,
  input  logic        is_decoding,
  input  logic        pipe_flush,

  input  logic        ex_valid,
  input  logic [ 4:0] ex_reg_addr,
  input  logic        ex_reg_we,
  input  logic [31:0] ex_reg_wdata,

  input  logic        ex_data_req,
  input  logic        ex_data_gnt,
  input  logic        ex_data_we,
  input  logic [31:0] ex_data_addr,
  input  logic [31:0] ex_data_wdata,

  input  logic        lsu_misaligned,

  input  logic        wb_valid,
  input  logic [ 4:0] wb_reg_addr,
  input  logic        wb_reg_we,
  input  logic [31:0] wb_reg_wdata,

  input  logic        wb_data_rvalid,
  input  logic [31:0] wb_data_rdata
);

  // DPI stuff
  chandle dpi_simdata;

  // SV-only stuff
  typedef struct {
    logic [ 4:0] addr;
    logic [31:0] value;
  } reg_t;

  typedef struct {
    logic [31:0] addr;
    logic        we;
    logic [ 3:0] be;
    logic [31:0] wdata;
    logic [31:0] rdata;
  } mem_acc_t;

  class instr_trace_t;
    time         simtime;
    logic [31:0] pc;
    logic [31:0] instr;
    reg_t        regs_write[$];
    mem_acc_t    mem_access[$];

    function new ();
      regs_write = {};
      mem_access = {};
    endfunction
  endclass

  mailbox rdata_stack = new (4);
  integer rdata_writes = 0;

  mailbox instr_ex = new (2);
  mailbox instr_wb = new (2);

  // simchecker initialization
  initial
  begin
    #1;
    dpi_simdata = riscv_checker_init(32'h80, core_id, cluster_id);
  end

  // virtual ID/EX pipeline
  initial
  begin
    instr_trace_t trace;
    mem_acc_t     mem_acc;
    reg_t         reg_write;

    while(1) begin
      instr_ex.get(trace);

      // wait until we are going to the next stage
      do begin
        @(negedge clk);

        reg_write.addr  = ex_reg_addr;
        reg_write.value = ex_reg_wdata;

        if (ex_reg_we)
          trace.regs_write.push_back(reg_write);

        // look for data accesses and log them
        if (ex_data_req && ex_data_gnt) begin
          mem_acc.addr = ex_data_addr;
          mem_acc.we   = ex_data_we;

          if (mem_acc.we)
            mem_acc.wdata = ex_data_wdata;
          else
            mem_acc.wdata = 'x;

          trace.mem_access.push_back(mem_acc);
        end
      end while (!ex_valid || lsu_misaligned);

      instr_wb.put(trace);
    end
  end

  // virtual EX/WB pipeline
  initial
  begin
    instr_trace_t trace;
    reg_t         reg_write;
    logic [31:0]  tmp_discard;

    while(1) begin
      instr_wb.get(trace);

      // wait until we are going to the next stage
      do begin
        @(negedge clk);
        #1;

        reg_write.addr  = wb_reg_addr;
        reg_write.value = wb_reg_wdata;

        if (wb_reg_we)
          trace.regs_write.push_back(reg_write);

        // pop rdata from stack when there were pending writes
        while(rdata_stack.num() > 0 && rdata_writes > 0) begin
          rdata_writes--;
          rdata_stack.get(tmp_discard);
        end

      end while (!wb_valid);

      // keep care of rdata
      foreach(trace.mem_access[i]) begin
        if (trace.mem_access[i].we) begin
          // for writes we don't need to wait for the rdata, so if it has
          // not appeared yet, we count it and remove it later from out
          // stack
          rdata_writes++;

        end else begin
          if (rdata_stack.num() == 0)
            $warning("rdata stack is empty, but we are waiting for a read");

          rdata_stack.get(trace.mem_access[i].rdata);
        end
      end

      // instruction is ready now, all data is inserted
      foreach(trace.mem_access[i]) begin
        if (trace.mem_access[i].we)
          riscv_checker_mem_access(dpi_simdata, trace.mem_access[i].we, trace.mem_access[i].addr, trace.mem_access[i].wdata);
        else
          riscv_checker_mem_access(dpi_simdata, trace.mem_access[i].we, trace.mem_access[i].addr, trace.mem_access[i].rdata);
      end

      foreach(trace.regs_write[i]) begin
        riscv_checker_reg_access(dpi_simdata, trace.regs_write[i].addr, trace.regs_write[i].value);
      end

      if (riscv_checker_step(dpi_simdata, trace.pc, trace.instr))
        $display("%t: Mismatch between simulator and RTL detected", trace.simtime);
    end
  end

  // create rdata stack
  initial
  begin
    while(1) begin
      @(negedge clk);

      if (wb_data_rvalid) begin
        rdata_stack.put(wb_data_rdata);
      end
    end
  end

  // log execution
  initial
  begin
    instr_trace_t trace;

    while(1) begin
      @(negedge clk);

      // special case for WFI because we don't wait for unstalling there
      if ((id_valid && is_decoding) || pipe_flush)
      begin
        trace = new ();

        trace.simtime    = $time;
        trace.pc         = pc;
        trace.instr      = instr;

        instr_ex.put(trace);
      end
    end
  end

endmodule
