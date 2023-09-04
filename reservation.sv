task release;
    input int start_idx, end_idx, i; 
    inout station [`RS_SZ-1:0] rs;
    inout bit counter;
    output bit [`SUPER-1:0] exe_valid;
    output int ptr;

    int ptr = (counter) ? start_idx : end_idx-1;
    if (counter) begin
        while (!(rs[ptr].src1_ready && rs[ptr].src2_ready)) begin
            if (ptr == start_idx) begin
                exe_valid[i] = 0;
                break;
            end
            ptr --;
        end
    end else begin
        while (!(rs[ptr].src1_ready && rs[ptr].src2_ready)) begin
            if (ptr == end_idx-1) begin
                exe_valid[i] = 0;
                break;
            end
            ptr ++;
        end
    end
    exe_valid[i] = 1;
    rs[ptr].done = 1;
    counter = ~counter;
endtask

task reserve;
    input int start_idx, end_idx, i;
    inout station [`RS_SZ-1:0] rs;
    inout bit counter;
    output bit stall;
    output int ptr;

    int ptr = (counter) ? start_idx : end_idx-1;
    if (counter) begin
        while (!(!rs[ptr].busy || rs[ptr].done)) begin
            if (ptr == start_idx) begin
                stall = 1;
                break;
            end
            ptr --;
        end
    end else begin
        while (!(!rs[ptr].busy || rs[ptr].done)) begin
            if (ptr == end_idx-1) begin
                stall = 1;
                break;
            end
            ptr ++;
        end
    end
endtask

task receive;
    input int dep_ptr;
    input word edata;
    input evalid;
    inout station [`RS_SZ-1:0] rs;

    while (rs[dep_ptr].read_dep_op != 0) begin
        if (rs[dep_ptr].read_dep_op[0]) begin
            //so we don't reassign data
            rs[dep_ptr].src1 = (rs[dep_ptr].src1.ready) ? rs[dep_ptr].src1 : edata;
            rs[dep_ptr].src1_ready = evalid;
        end
        if (rs[dep_ptr].read_dep_op[1]) begin
            rs[dep_ptr].src1 = (rs[dep_ptr].src2.ready) ? rs[dep_ptr].src2 : edata;
            rs[dep_ptr].src2_ready = evalid;
        end
        rs[dep_ptr].read_dep_op = 2'b00;
        dep_ptr = rs_wire[dep_ptr].read_dep;
    end
endtask

module reservation(
    input                                               clk, rst,
    
    //from decode
    input D2I [`SUPER-1:0]                       incoming_instrs,

    //from functional units
    input word [`SUPER-1:0]                             exe_data,
    input [`SUPER-1:0]                            exe_data_valid,
    input [`SUPER-1:0]                                   FU_free, //lsb->msb mul add alu
    input [`SUPER-1:0] [$clog2(`RS_SZ)-1:0]          finished_rs,
    
    //from loadstore
    input [`SUPER-1:0][$clog2(`LSQ_SZ)-1:0]         incoming_lsq,
    input word [`SUPER-1:0]                          exe_ld_data,
    input [`SUPER-1:0]                              exe_ld_valid,
    input [`SUPER-1:0][$clog2(`RS_SZ)-1:0]             exe_ld_rs,
    input word                                       mem_ld_data,
    input                                           mem_ld_valid,
    input [$clog2(`RS_SZ)-1:0]                         mem_ld_rs,

    //from rob
    input [`SUPER-1:0][$clog2(`ROB_SZ)-1:0]         incoming_rob,

    //to functional units
    output [$clog2(`RS_SZ)-1:0]                           exe_rs,
    output word [`SUPER-1:0] exe_src1, exe_src2, exe_imm, exe_pc,
    output [`SUPER-1:0]                                exe_valid,
    output [`SUPER-1:0][3:0]                                  op,
    output [`SUPER-1:0][2:0]                                func,

    //to loadstore
    input [`SUPER-1:0][$clog2(`RS_SZ)-1:0]             issued_rs,
    input [`SUPER-1:0][$clog2(`LSQ_SZ)-1:0]            ready_lsq,

    //to ROB
    output [`SUPER-1:0][$clog2(`ROB_SZ)-1:0]           ready_rob,
    output [$clog2(`ROB_SZ)-1:0]                      mem_ld_rob,

    output                                                 stall
);

    reg station station [`RS_SZ-1:0] rs; //lsb->msb mul add alu
    wire station station [`RS_SZ-1:0] rs_wire;

    reg [`PHYS_SZ-1:0][$clog2(`RS_SZ)-1:0] depmap;
    wire [`PHYS_SZ-1:0][$clog2(`RS_SZ)-1:0] depmap_wire;
    word edata;
    wire evalid;
    int dep_ptr;

    reg [2:0] counters; //so we uniformly add to the front and back
    wire [2:0] counters_wire;

    //combinational reads from reservation stations/generate reset signal
    always_comb begin
        rs_wire = rs;
        //grab new data from execute
        foreach (finished_rs[i]) begin
            if (!exe_data_valid[i] || opcode'(rs[finished_rs[i]].op) == Mem) continue;
            dep_ptr = finished_rs[i];
            ready_rob[i] = rs_wire[dep_ptr].rob_dest;
            ready_lsq[i] = rs_wire[dep_ptr].lsq;
            receive(dep_ptr, exe_data[i], 1, rs_wire);
        end

        //grab new data from memory
        if (mem_ld_valid) begin
            dep_ptr = mem_ld_rs;
            mem_ld_rob[i] = rs_wire[dep_ptr].rob_dest;
            receive(dep_ptr, mem_ld_data[i], 1, rs_wire);
        end

        //grab new data from load execute
        foreach (finished_rs[i]) begin
            if (!exe_ld_valid[i] || opcode'(rs[finished_rs[i]].op) != Mem) continue;
            dep_ptr = (mem_func'(rs[finished_rs[i]].func) == Store) ? exe_ld_rs[i] : finished_rs[i];
            ready_rob[i] = rs_wire[dep_ptr].rob_dest;
            receive(dep_ptr, exe_ld_data[i], exe_ld_valid[i], rs_wire);
        end

        //grab new data from memory
        
        //send an instruction to exe
        counters_wire = counters;
        foreach (FU_free[i]) begin
            if (!FU_free[i]) continue;
            int ptr;
            case (i) inside
                [0:0]: begin
                    release(0, 2, i, rs_wire, counters_wire[0], exe_valid, ptr);
                end
                [1:`ADD_NUM]: begin
                    release(2, 2+2*`ADD_NUM, i, rs_wire, counters_wire[1], exe_valid, ptr);
                end
                [ALU_NUM+1:`SUPER-1]: begin
                    release(2+2*`ADD_NUM, `RS_SZ, i, rs_wire, counters_wire[2], exe_valid, ptr);
                end
                if exe_valid[i] begin
                    exe_src1[i] = rs_wire[ptr].src1;
                    exe_src2[i] = rs_wire[ptr].src2;
                    exe_imm[i] = rs_wire[ptr].imm;
                    exe_op[i] = rs_wire[ptr].op;
                    exe_func[i] = rs_wire[ptr].func;
                    exe_rs[i] = ptr;
                end
            endcase
        end

        //issue valid instructions to rs
        foreach (incoming_instrs[i]) begin
            if (!incoming_instrs[i].valid) continue;
            int ptr;
            case (opcode'(incoming_instrs.op))
                Alu, AluImm: begin
                    case (alu_func'(incoming_instrs.func))
                        Mulh, Mull:
                            reserve(0, 2, i, rs_wire, counter[0], stall, ptr);
                        Sub:
                            reserve(2, 2+2*`ADD_NUM, i, rs_wire, counter[1], stall, ptr);
                        default:
                            reserve(2+2*`ADD_NUM, `RS_SZ, i, rs_wire, counter[2], stall, ptr);
                    endcase
                end
                default:
                    reserve(2+2*`ADD_NUM, `RS_SZ, i, rs_wire, counter[2], stall, ptr);
            endcase
            
            if (!stall) begin
                //adding dependencies
                depmap_wire[instrs[i].dst] = ptr;

                //grabbing dependencies
                if (!instrs[i].src1_ready) begin
                    rs_wire[depmap_wire[instrs[i].src1]].read_dep = ptr;
                    rs_wire[depmap_wire[instrs[i].src1]].read_dep_op[0] = 1;
                end
                if (!instrs[i].src1_ready) begin
                    rs_wire[depmap_wire[instrs[i].src2]].read_dep = ptr;
                    rs_wire[depmap_wire[instrs[i].src2]].read_dep_op[1] = 1;
                end

                //update map for future dependencies
                if (!instrs[i].src1_ready) begin
                    depmap_wire[instrs[i].src1] = ptr;
                end
                if (!instrs[i].src2_ready) begin
                    depmap_wire[instrs[i].src2] = ptr;
                end

                //filling out fields for execution
                rs_wire[ptr].src1 = instrs[i].src1;
                rs_wire[ptr].src2 = instrs[i].src2;
                rs_wire[ptr].imm = instrs[i].imm;
                rs_wire[ptr].src1_ready = instrs[i].src1_ready;
                rs_wire[ptr].src2_ready = instrs[i].src2_ready;
                rs_wire[ptr].op = instrs[i].op;
                rs_wire[ptr].func = instrs[i].func;
                rs_wire[ptr].pc = instrs[i].pc;
                rs_wire[ptr].busy = 1;
                rs_wire[ptr].done = 0;
                rs_wire[ptr].rob_dest = incoming_rob[i];
                rs_wire[ptr].lsq = incoming_lsq[i];

                issued_rs[i] = ptr;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            rs <= 0;
            counters <= 0;
        end
        else begin
            counters <= counters_wire;
            foreach (rs[i]) begin
                rs[i] <= (rs_wire[i].done) ? 0 : rs_wire[i];
            end
        end
    end

endmodule