module processor(
    input clk, rst
);

    //execute
    wand [`SUPER-1:0] FU_free;
    I2E [`SUPER-1:0] i2e;
    I2E [`SUPER-1:0] e2m;
    word [`SUPER-1:0] exe_data;
    wire [`SUPER-1:0] exe_data_valid;

    //loadstore
    wire ls_stall;
    wire ls_flush;
    wire new_load_pc;
    wire [`SUPER-1:0][31:2] inums;
    wire [`SUPER-1:0][`LSQ_SZ-1:0] incoming_lsq;
    wire [`SUPER-1:0][$clog2(`RS_SZ)-1:0] exe_ld_rs;
    word [`SUPER-1:0] exe_ld_data;
    wire [`SUPER-1:0] exe_ld_valid;
    wire [$clog2(`RS_SZ)-1:0] mem_ld_rs;
    word mem_ld_data;
    wire mem_ld_valid;
    wire load_req;
    word load_req_addr;
    wire [$clog2(`RS_SZ)-1:0] load_req_rs;
    wire store_req;
    word store_req_addr;
    word store_req_data;

    //dcache
    word dcache_data;
    wire dcache_data_valid;
    wire store_sent;
    word dcache_req;
    wire [`LINE_SIZE*32-1:0] dcache_req_data;
    wire dcache_requested;
    wire dcache_req_store;
    wire writeback;

    //memory
    word dcacheaddr;
    wire [`LINE_SIZE*32-1:0] dcachedata;
    word dcachevalid;
    wand mem_full;

    //reservation stations
    wire rs_stall;
    wire word [`SUPER-1:0] exe_src1, exe_src2, exe_imm, exe_pc;
    wire [`SUPER-1:0] exe_valid;
    wire [`SUPER-1:0][3:0] exe_op;
    wire [`SUPER-1:0][2:0] exe_func;
    wire [`SUPER-1:0][$clog2(`RS_SZ)-1:0] exe_rs, issued_rs;
    wire [`SUPER-1:0][$clog2(`ROB_SZ)-1:0] ready_rob;
    wire [`SUPER-1:0][$clog2(`LSQ_SZ)-1:0] ready_lsq;
    wire [$clog2(`ROB_SZ)-1:0] mem_ld_rob;

    //reorder buffer
    wire rob_stall;
    wire [`SUPER-1:0][$clog2(`ROB_SZ)-1:0] incoming_rob;
    wire mispredict;
    wire [`SUPER-1:0][$clog2(`RS_SZ)-1:0] finished_rs;
    wire [`SUPER-1:0][4:0] committed_lregs;
    wire [`SUPER-1:0][$clog2(`PHYS_SZ)-1:0] committed_pregs;
    word [`SUPER-1:0] committed_data;
    wire [`SUPER-1:0] committed_wr_en, is_ls_commit, committed_valid, committed_store;
    word branch_redirect;
    wire [$clog2(`LSQ_SZ)-1:0] first_lq_inv, first_sq_inv,
    wire first_lq_inv_v, first_sq_inv_v

    //fetch
    FetchAction fetchAction;
    word predicted_nextPC;
    word redirectPC;
    F2D [`SUPER-1:0] f2d;
    wand f2d_valid;
    word [`SUPER-1:0] currPCVec;
    word [`SUPER-1:0] dataFromI$;
    wire [`SUPER-1:0] dataFromI$;
    
    //icache
    word icache_req;
    wire icache_requested;

    //decode
    D2I [`SUPER-1:0] d2i_wire; 
    D2I [`SUPER-1:0] d2i;
    wire [`SUPER-1:0][4:0] src1, src2, dst;
    wire [`SUPER-1:0] is_jump_instr;
    word jump_pc;
    [`SUPER-1:0][1:0] is_ls;

    //branch predict
    word [`SUPER-1:0] branch_pcs;
    wire [`SUPER-1:0] is_branch_instr;
    wire [`SUPER-1:0] branch_taken;

    //rename
    wand [`SUPER-1:0] valids;

    //resolve all icache misses before proceeding!
    always_comb begin
        //MEMORY
        mainmem mainmem_0 (
            .clk(clk),
            .rst(rst),

            //from icache
            .icache_req(icache_req),
            .requested(icache_requested)

            //from dcache
            .dcache_req(dcache_req),
            .dcache_req_data(dcache_req_data),
            .dcache_requested(dcache_requested),
            .dcache_req_store(dcache_req_store),
            .writeback(writeback)

            //to dcache
            .dcacheaddr(dcacheaddr)
            .dcachedata(dcachedata)
            .dcachevalid(dcachevalid)
            .mem_full(mem_full)
            
            //to icache
            .icacheaddr(icacheaddr),
            .icachedata(icachedata),
            .icachevalid(icachevalid),
            .mem_full_icache(mem_full_icache),
        );

        dcache dcache_0 (
            .clk(clk),
            .rst(rst),
            
            //from loadstore
            .load_req(load_req),
            .load_req_addr(load_req_addr),
            .store_req(store_req),
            .store_req_addr(store_req_addr),
            .store_req_data(store_req_data),

            //from memory
            .memaddr(dcacheaddr)
            .memdata(dcachedata)
            .memvalid(dcachevalid)
            .mem_full(mem_full)

            //to loadstore
            .data(dcache_data),
            .data_valid(dcache_data_valid),
            .store_sent(store_sent),

            //to memory
            .dcache_req(dcache_req),
            .dcache_req_data(dcache_req_data),
            .dcache_requested(dcache_requested),
            .dcache_req_store(dcache_req_store),
            .writeback(writeback)
        ); 

        //EXECUTE

        //read last executed data + send to buffers
        foreach (e2m[i]) begin
            exe_data[i] = e2m[i].data;
            //only case where we don't fill in data from execute is a load
            exe_data_valid[i] = e2m[i].valid && !(opcode'(e2m[i].op) == Mem && mem_func(e2m[i].func) == Load);
            FU_free[i] = 1;
        end 

        reservation reservation_0 (
            .clk(clk),
            .rst(rst || ls_flush || rob_flush),

            //from decode
            .incoming_instrs(d2i),

            //from functional units
            .exe_data(exe_data),
            .exe_data_valid(exe_data_valid),
            .FU_free(FU_free),
            .finished_rs(finished_rs),

            //from loadstore
            .incoming_lsq(incoming_lsq),
            .exe_ld_data(exe_ld_data),
            .exe_ld_valid(exe_ld_valid),
            .exe_ld_rs(exe_ld_rs),
            .mem_ld_data(mem_ld_data),
            .mem_ld_valid(mem_ld_valid),
            .mem_ld_rs(mem_ld_rs),

            //from ROB
            .incoming_rob(incoming_rob),
            .rob_stall(rob_stall),
            .first_lq_inv(first_lq_inv),
            .first_sq_inv(first_sq_inv),
            .first_lq_inv_v(first_lq_inv_v),
            .first_sq_inv_v(first_sq_inv_v),

            //to functional units
            .exe_src1(exe_src1),
            .exe_src2(exe_src2),
            .exe_imm(exe_imm),
            .exe_pc(exe_pc),
            .exe_valid(exe_valid),
            .exe_op(exe_op),
            .exe_func(exe_func),
            .exe_rs(exe_rs),

            //to loadstore
            .issued_rs(issued_rs),
            .ready_lsq(ready_lsq),
            
            //to rob
            .ready_rob(ready_rob),
            .mem_ld_rob(mem_ld_rob),

            .stall(rs_stall)
        );

        reorder reorder_0 (
            .clk(clk),
            .rst(rst || ls_flush),

            //from decode
            .instrs(d2i),

            //from functional units
            .exe_data(exe_data),
            .exe_data_valid(exe_data_valid),

            //from lsq
            .incoming_lsq(incoming_lsq),
            .exe_ld_data(exe_ld_data),
            .exe_ld_valid(exe_ld_valid),
            .mem_ld_data(mem_ld_data),
            .mem_ld_valid(mem_ld_valid),

            //from reservation
            .ready_rob(ready_rob),
            .mem_ld_rob(mem_ld_rob),

            //outputs
            .stall(rob_stall),
            .flush(mispredict),
            .redirectPC(branch_redirect),
            
            //to rename
            .exe_dsts(exe_dsts),
            .exe_valid(exe_rename_valid),
            .committed_lregs(committed_lregs),
            .committed_pregs(committed_pregs),
            .committed_valid(committed_valid),
            .committed_data(committed_data),
            .committed_wr_en(committed_wr_en),

            //to loadstore
            .committed_lsq(committed_lsq),
            .is_ls_commit(is_ls_commit),
            .first_lq_inv(first_lq_inv),
            .first_sq_inv(first_sq_inv),
            .first_lq_inv_v(first_lq_inv_v),
            .first_sq_inv_v(first_sq_inv_v),
        );

        loadstore loadstore_0 (
            .clk(clk),
            .rst(rst),

            //from decode
            .issued_instrs(d2i),
            
            //from execute
            .exec_instrs(e2m),

            //from execute
            .issued_rs(issued_rs),
            .ready_lsq(ready_lsq),
            .ready_lsq(ready_lsq),

            //from rob
            .committed_lsq(committed_lsq),
            .is_ls_commit(is_ls_commit),
            .committed_wr_en(committed_wr_en),
            .committed_valid(committed_valid),

            //from fetch
            .pc_check_dep(branch_pcs),
            .is_ls(is_ls),

            //from dcache
            .cache_data(dcache_data)
            .cache_valid(dcache_data_valid)
            .store_sent(store_sent)
            
            //to execute
            .incoming_lsq(incoming_lsq),
            .exe_ld_data(exe_ld_data),
            .exe_ld_valid(exe_ld_valid),
            .exe_ld_rs(exe_ld_rs),
            .mem_ld_data(mem_ld_data),
            .mem_ld_valid(mem_ld_valid),
            .mem_ld_rs(mem_ld_rs),

            //to decode
            .inums(inums),

            //to dcache
            .load_req(load_req),
            .load_req_addr(load_req_addr),
            .store_req(store_req),
            .store_req_addr(store_req_addr),
            .store_req_data(store_req_data),

            //control flow
            .stall(ls_stall),
            .flush(ls_flush),
            .redirectPC(new_load_pc)
        );

        foreach (FU_free[i]) begin
            if (!FU_free[i]) continue;
            i2e[i].valid = exe_valid[i];
            i2e[i].src1 = exe_src1[i];
            i2e[i].src2 = exe_src2[i];
            i2e[i].imm = exe_imm[i];
            i2e[i].op = exe_op[i];
            i2e[i].func = exe_func[i];
            i2e[i].rs = exe_rs[i];
            i2e[i].pc = exe_pc[i];
        end

        //execute
        mul mul_0 (
            .clk(clk),
            .rst(rst),
            .i2e(i2e[0]),

            //read from last execution reg
            .e2m(e2m[0]),
            .FU_free(FU_free[0]),
            .finished_rs(finished_rs[0])
        );
        add add_0[`ADD_NUM-1:0] (
            .clk((`ADD_NUM-1){clk}),
            .rst((`ADD_NUM-1){rst}),
            .i2e(i2e[`ADD_NUM:1]),

            .e2m(e2m[`ADD_NUM:1]),
            .finished_rs(finished_rs[`ADD_NUM:1])
        );
        alu alu_0[`ALU_NUM-1:0] (
            .clk((`ALU_NUM-1){clk}),
            .rst((`ALU_NUM-1){rst}),
            .i2e(i2e[`SUPER-1:`ADD_NUM+1]),

            .e2m(e2m[`SUPER-1:`ADD_NUM+1]),
            .finished_rs(finished_rs[`SUPER-1:`ADD_NUM+1])
        );

        //DECODE
        //grab fetched instructions
        foreach (f2d[i]) begin
            f2d_valid = f2d[i].valid;
            if (!f2d_valid) begin
                break;
            end

            //process fetchdata
            src1[i] = f2d[i].instr[`SRC1_RANGE];
            src2[i] = f2d[i].instr[`SRC2_RANGE];
            case (opcode'(f2d[i].instr[OPCODE_RANGE]))
                Branch: begin
                    if (branch_func'(f2d[i].instr[`FUNC_RANGE]) > Beqz) begin
                        valids[i] = 0;
                    end else begin
                        dst[i] = 0;
                        is_branch_instr[i] = 1;
                    end
                end
                Jump: begin
                    case (jump_func'(f2d[i].instr[`FUNC_RANGE]))
                        Jal: begin
                            dst[i] = f2d[i].instr[`DST_RANGE];
                            is_jump_instr[i] = 1;

                            //is this how to correctly handle the offsets?
                            jump_pc = f2d[i].pc+f2d[i].instr[`IMM20_RANGE];
                            break;
                        end
                        Jalr: begin
                            dst[i] = f2d[i].instr[`DST_RANGE];
                            is_jump_instr[i] = 1;

                            jump_pc = f2d[i].pc+f2d[i].instr[`IMM15_RANGE];
                            break;
                        end
                        default:
                            valids[i] = 0;
                    endcase
                end
                Alu: begin
                    if (alu_func'(f2d[i].instr[`FUNC_RANGE]) > Mull) begin
                        valids[i] = 0;
                    end else begin
                        dst[i] = f2d[i].instr[`DST_RANGE];
                    end
                end
                AluImm: begin
                    if (alu_func'(f2d[i].instr[`FUNC_RANGE]) > Mull) begin
                        valids[i] = 0;
                    end else begin
                        dst[i] = f2d[i].instr[`DST_RANGE];
                    end
                end
                Mem: begin
                    case (mem_func'(f2d[i].instr[`FUNC_RANGE]))
                        Load: begin
                            dst[i] = f2d[i].instr[`DST_RANGE];
                            is_ls[i] = 1;
                        end
                        Store: begin
                            dst[i] = 0;
                            is_ls[i] = 2;
                        end
                        default:
                            valids[i] = 0;
                    endcase
                end
                Lui: begin
                    if (f2d[i].instr[`FUNC_RANGE] != 0) begin
                        valids[i] = 0;
                    end else begin
                        dst[i] = f2d[i].instr[`DST_RANGE];
                    end
                end
                default:
                    valids[i] = 0;
            endcase

            branch_pcs[i] = f2d[i].pc;
        end

        //branch predictor
        branch_predictor branch_predictor_0 (
            //from decode
            .clk(clk),
            .rst(rst),
            .is_branch_instr(is_branch_instr),
            .is_jump_instr(is_jump_instr),
            .jump_pc(jump_pc),
            .PC_to_check(branch_pcs),

            .actual_nextpc(branch_redirect),
            .mispredict(mispredict),

            .branch_taken(branch_taken),
            .predicted_nextPC(predicted_nextPC)

        );

        //invalidate instructions after a taken branch/jump
        for (int i = 1; i < `SUPER; i++) begin
            valids[i] = &(~branch_taken[i-1:0]);
            valids[i] = &(~is_jump_instr[i-1:0]);
        end

        //rename
        rename rename_0 (
            .clk(clk),
            .rst(rst),
            .annull(mispredict), //same signal as mispredict in branch predictor TO DO

            //from decode
            .src1(src1),
            .src2(src2),
            .dst(dst),
            .valids(valids),

            //from ROB/functional units
            .committed_lregs(committed_lregs),
            .committed_pregs(committed_pregs),
            .valid_commit(committed_valid),
            .executed_dsts(exe_dsts),
            .executed_valid(exe_rename_valid),

            .src1_p(src1_p),
            .src2_p(src2_p),
            .src1_n_RAW(src1_n_RAW),
            .src2_n_RAW(src2_n_RAW),
            .granted_phys_idx_wire(dst_p)
        );


        //physical registers
        phys_reg phys_reg_0 (
            .clk(clk),
            .rst(rst),

            //from renamer
            .src1(src1_p),
            .src2(src2_p),
            
            //from ROB
            .dst(committed_pregs),
            .wr_data(committed_data),
            .wr_en(committed_wr_en),

            .data1(data1),
            .data2(data2)
        );

        if (ls_flush) begin
            fetchAction = Redirect;
            redirectPC = new_load_pc;
        end else if (mispredict) begin
            fetchAction = Redirect;
            redirectPC = branch_redirect;
        end else if (!f2d_valid || ls_stall || rob_stall || rs_stall) begin
            fetchAction = Stall;
        end else begin
            //decode
            d2i_wire = d2i_reg;
            foreach (f2d[i]) begin
                d2i_wire[i].valid = valids[i];
                d2i_wire[i].dst_log = dst[i];
                d2i[i].pc = f2d[i].pc;
                d2i[i].inum = inums[i];
                if (branch_taken[i]) begin
                    d2i_wire[i].nextPC = predicted_nextPC;
                end else begin
                    d2i_wire[i].nextPC = f2d[i].pc + 4;
                end
                decode(f2d[i].instr, src1_p[i], src2_p[i], dst_p[i], src1_n_RAW[i], src2_n_RAW[i], data1, data2, d2i_wire[i]);
            end
            fetchAction = Dequeue;
        end

        //calls fetch
        fetch fetch_0 (
            .clk(clk),
            .rst(rst),
            
            //from decode
            .action(fetchAction),
            .predicted_nextPC(predicted_nextPC),
            .redirectPC(redirectPC),

            //from icache
            .data(dataFromI$),
            .data_valid(validFromI$),

            //to icache
            .currPCVec(currPCVec),

            //to decode
            .f2d(f2d)
        );

        icache icache_0 (
            .clk(clk),
            .rst(rst),
            .PCVec(currPCVec),

            //from main memory
            .memaddr(icacheaddr),
            .memdata(icachedata),
            .memvalid(icachevalid),
            .mem_full(mem_full_icache),

            //to fetch
            .data(dataFromI$),
            .data_valid(validFromI$),

            //to main memory
            .icache_req(icache_req),
            .requested(icache_requested)
        );
    end

endmodule