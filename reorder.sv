module reorder(
    input clk, rst,
    //from decode
    input D2I [`SUPER-1:0] instrs,
    
    //from functional units
    input word [`SUPER-1:0] exe_data,
    input [`SUPER-1:0] exe_data_valid,

    //from lsq
    input [`SUPER-1:0][$clog2(`LSQ_SZ)-1:0] incoming_lsq,
    input word [`SUPER-1:0] exe_ld_data,
    input [`SUPER-1:0] exe_ld_valid,
    input word mem_ld_data,
    input mem_ld_valid,
    
    //from reservation
    input [`SUPER-1:0][clog$(`ROB_SZ)-1:0] ready_rob,
    input [clog$(`ROB_SZ)-1:0] mem_ld_rob,

    output stall,
    output flush,
    output redirectPC,

    //to rename
    output [`SUPER:0][$clog2(`PHYS_SZ)-1:0] exe_dsts,
    output [`SUPER:0] exe_valid,
    output [`SUPER-1:0][4:0] committed_lregs,
    output [`SUPER-1:0][$clog2(`PHYS_SZ)-1:0] committed_pregs,
    output [`SUPER-1:0] committed_wr_en, is_ls_commit, committed_valid,
    output word [`SUPER-1:0] committed_data

    //to lsq
    output [`SUPER-1:0][clog$(`LSQ_SZ)-1:0] committed_lsq,
    output [$clog2(`LSQ_SZ)-1:0] first_lq_inv, first_sq_inv,
    output first_lq_inv_v, first_sq_inv_v
);
    reg [$clog2(`ROB_SZ)-1:0] head;
    reg [$clog2(`ROB_SZ)-1:0] tail;
    wire [$clog2(`ROB_SZ)-1:0] tail_wire;
    wire [$clog2(`ROB_SZ)-1:0] head_wire;

    reg rob_line [`ROB_SZ-1:0] rob;
    wire rob_line [`ROB_SZ-1:0] rob_wire;

    word edata;
    wire evalid;

    always_comb begin
        rob_wire = rob;

        //grabbing data from mem
        if (head <= mem_ld_rob && mem_ld_rob <= tail) begin
            rob_wire[mem_ld_rob].ready = mem_ld_valid;
            rob_wire[mem_ld_rob].value = mem_ld_data;
            exe_dsts[`SUPER] = rob_wire[ready_rob[i]].dst;
            exe_valid[`SUPER] = 1;
        end
        //grabbing data from functional/loadstore execute
        flush = 0;
        foreach (ready_rob[i]) begin
            if (!exe_data_valid[i]) continue;
            if (!(head <= ready_rob[i] && ready_rob[i] <= tail)) continue;

            edata = (rob[ready_rob[i]].instr_type == 2'b10) : exe_ld_data[i] ? exe_data[i];
            evalid = (rob[ready_rob[i]].instr_type == 2'b10) : exe_ld_valid[i] ? 1'b1;

            if (rob_wire[ready_rob[i]].instr_type == 2'b01 && exe_data[i] != rob_wire[ready_rob[i]].nextPC) begin
                rob_wire[ready_rob[i]].flush = 1'b1;
                rob_wire[ready_rob[i]].redirectPC = exe_data[i];
            end else begin
                rob_wire[ready_rob[i]].ready = evalid;
                rob_wire[ready_rob[i]].value = edata;
                exe_dsts[i] = rob_wire[ready_rob[i]].dst;
                exe_valid[i] = 1;
            end
        end

        //adding valid instructions to ROB at issue
        tail_wire = tail;
        foreach (instrs[i]) begin
            if (!instrs[i].valid) continue;
            if (rob_wire[tail_wire].occupied) begin
                stall = 1;
                break;
            end
            rob_wire[tail_wire].dst = instrs[i].dst;
            rob_wire[tail_wire].wr_en = instrs[i].wr_en;
            rob_wire[tail_wire].nextPC = instrs[i].nextPC;
            rob_wire[tail_wire].occupied = 1;
            rob_wire[tail_wire].flush = 0;
            rob_wire[head_wire].ready = 0;
            rob_wire[tail_wire].dst_log = instrs[i].dst_log;
            case (opcode'(instrs[i].op))
                Branch: begin
                    rob_wire[tail_wire].instr_type = 2'b01;
                end
                Mem: begin
                    rob_wire[tail_wire].instr_type = 2'b10; //will check this against write enable to see if store
                    rob_wire[tail_wire].lsq = issued_lsq[i];
                end
                default: begin
                    rob_wire[tail_wire].instr_type = 2'b00;
                end
            endcase
            tail_wire = (tail_wire + 1)[$clog2(`ROB_SZ)-1:0];
        end

        head_wire = head;
        for (int i = 0; i < `SUPER; i++) begin
            //handles crossover even with wrapping
            if (head_wire == tail_wire) break;
            if (rob_wire[head_wire].flush) begin
                flush = 1;
                redirectPC = rob_wire[head_wire].redirectPC;
                while (head_wire != tail_wire) begin
                    if (rob_wire[head_wire].instr_type == 2'b10 && rob_wire[head_wire].wr_en) begin
                        first_lq_inv = 1;
                        first_lq_inv = rob_wire[head_wire].lsq;
                        break;
                    end else if (rob_wire[head_wire].instr_type == 2'b10) begin
                        first_lq_inv = 1;
                        first_sq_inv = rob_wire[head_wire].lsq;
                        break;
                    end
                    head_wire = (head_wire + 1)[`ROB_SZ-1:0];
                end
                break;
            end
            //in order commit
            if (!rob_wire[head_wire].ready && rob_wire[head_wire].wr_en) break;
            committed_pregs[i] = rob_wire[head_wire].dst;
            committed_data[i] = rob_wire[head_wire].value;
            committed_lregs[i] = rob_wire[head_wire].dst_log;
            committed_wr_en[i] = rob_wire[head_wire].wr_en;
            committed_lsq[i] = rob_wire[head_wire].lsq;
            is_ls_commit[i] = (rob_wire[head_wire].instr_type == 2'b10);
            committed_valid[i] = 1;
            rob_wire[head_wire].occupied = 0;

            head_wire = (head_wire + 1)[`ROB_SZ-1:0];
        end
        
    end


    always_ff @(posedge clk) begin
        if (rst || flush) begin
            rob <= 0;
            head <= 0;
            tail <= 0;
        end
        else begin
            rob <= rob_wire;
            head <= head_wire + head;
            tail <= tail_wire;
        end

    end
endmodule