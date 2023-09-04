module rename(
    input                                          clk, rst, annull,
    input [`SUPER-1:0][4:0]                         src1, src2, dst,
    input [`SUPER-1:0]                                       valids,

    input [`SUPER-1:0][4:0]                         committed_lregs,
    input [`SUPER-1:0][$clog2(`PHYS_SZ)-1:0]        committed_pregs,
    input [`SUPER-1:0]                                 valid_commit,

    input [`SUPER:0][$clog2(`PHYS_SZ):0]              executed_dsts, //from execute
    input [`SUPER:0]                                 executed_valid, //from execute

    output wire [`SUPER-1:0][$clog2(`PHYS_SZ-1):0]        src1_p, src2_p,
    output wire [`SUPER-1:0]                      src1_n_RAW, src2_n_RAW,
    output wire [`SUPER-1:0][$clog2(`PHYS_SZ-1):0] granted_phys_idx_wire //destination remappings
);
    //future rat - fixes WAW and WAR
    reg [31:0][$clog2(`PHYS_SZ)-1:0] f_rat;  
    wire [31:0][$clog2(`PHYS_SZ)-1:0] f_rat_wire;  

    //free reggies
    reg [`PHYS-1:0] free;
    wire [`PHYS-1:0] free_wire;
    reg [`SUPER-1:0][$clog2(`PHYS_SZ)-1:0] granted_phys_idx;

    //retirement rat - logs mapping at last commit
    reg [31:0][$clog2(`PHYS_SZ)-1:0] r_rat;  
    wire [`SUPER-1:0][`PHYS_SZ-1:0] old_phys_reggies;

    //determining read after writes
    reg [`PHYS_SZ-1:0] non_RAW;
    wire [`PHYS_SZ-1:0] non_RAW_wire;
    
    always_comb begin
        f_rat_wire = f_rat;
        //calculate the next free physical registers by taking stock of which ones are entering/leaving both RATs
        latest_issued = (annull) ? committed_pregs : granted_phys_idx;
        for (int i = `SUPER-1; i >= 0; i++) begin
            if (!valid_commit[i]) begin
                continue;
            end

            added[latest_issued[i]] = 1;
            leaving = (annull) ? r_rat[committed_lregs[i]] : f_rat[committed_lregs[i]];

            //still want to treat values that "enter" the RRAT and are immediately overwritten by another commit with the same logical register as committed
            if (freed[leaving] && annull) begin
                freed[committed_pregs[i]] = 1;
            end
            freed[leaving] = 1;
        end
        free_wire = (free & ~added) | freed

        //alternating grants from both sides of the physical register file
        int grant_big = `PHYS_SZ-1;
        int grant_small = 0;
        int j;
        for (int i = 0; i < `SUPER; i++) begin
            if (dst[i] == 0 || !valids[i]) begin //don't waste a grant
                continue;
            end
            if (j % 2 == 0) begin
                while (!free_wire[grant_big]) begin
                    grant_big --1;
                end
                granted_phys_idx_wire[i] = grant_big;
            end
            else begin
                while (!free_wire[grant_small]) begin
                    grant_small ++1;
                end
                granted_phys_idx_wire[i] = grant_small;
            end
            j++;
        end

        //not a RAW if dest already calculated - include newly executed instrs
        non_RAW_wire = non_RAW;
        foreach (executed_dsts[i]) begin
            if (executed_valid[i]) begin
                non_RAW_wire[executed_dsts[i]] = 1;
            end
        end

        for (int i = 0; i < `SUPER; i++) begin
            if (!valids[i]) continue;
            src1_p = f_rat_wire[src1[i]]; 
            src1_n_RAW = non_RAW_wire[src1[src1_p]];

            src2_p = f_rat_wire[src2[i]]; 
            src2_n_RAW = non_RAW_wire[src2[src2_p]];

            //if we're writing to a physical register, reroute following instrs to next available physical register to avoid WAR/WAW
            //assigned only on writes, so these act as our destination physical registers as well
            if (dst[i] == 0) continue; //invalid logical reggie
            f_rat_wire[dst[i]] = granted_phys_idx_wire[i];
            non_RAW_wire[granted_phys_idx[i]] = 1'b0;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            free[`PHYS_SZ-1:32] <= (`PHYS_SZ-32){1'b1};
            free[31:0] <= 0;
            granted_phys_idx <= 0;
            non_RAW <= `PHYS_SZ {1'b1};

            for (int i = 0; i < `SUPER; i++) begin
                f_rat[i] <= i;
                r_rat[i] <= i;
            end
        end
        else begin
            free <= free_wire;
            granted_phys_idx <= granted_phys_idx_wire;
            non_RAW <= non_RAW_wire;

            f_rat <= f_rat_wire;
            for (int i = 0; i < `SUPER; i++) begin
                r_rat[committed_lregs[i]] <= committed_pregs[i]
            end
        end
    end

endmodule

task decode;
    //from initial fetch processing
    input word instr;
    //from rename
    input [$clog2(`PHYS_SZ)-1:0] src1, src2, dst;
    input src1_r, src2_r;
    //from phys reg file
    input word a, b;
    output D2I d2i;

    //mark unused operands as ready
    case (opcode'(instr[OPCODE_RANGE]))
        Branch: begin
            d2i.wr_en = 0;
            d2i.src1 = (!src1_r) ? src1 : a;
            d2i.src1_ready = src1_r;
            d2i.imm = {instr[`IMM15_RANGE][31:21], instr[`DST_RANGE]}
            d2i.func = instr[`FUNC_RANGE];
            d2i.op = instr[`OPCODE_RANGE];
            case (br_func'(instr[`FUNC_RANGE]))
                Beqz: begin
                    d2i.src2_ready = 1;
                    d2i.src2 = 0;
                end
                default: begin
                    d2i.src2 = (!src2_r) ? src2 : b;
                    d2i.src2_ready = src2_r;
                end
            endcase
        end
        Jump: begin
            d2i.func = instr[`FUNC_RANGE];
            d2i.op = instr[`OPCODE_RANGE];
            d2i.wr_en = 1;
            d2i.dst = dst;
            d2i.src2_ready = 1;
            case (jump_func'(instr[`FUNC_RANGE]))
                Jal: begin
                    d2i.src1_ready = 1;
                    d2i.imm = instr[`IMM20_RANGE];
                end
                Jalr: begin
                    d2i.src1_ready = src1_r;
                    d2i.src1 = (!src1_r) ? src1 : a;
                    d2i.imm = instr[`IMM15_RANGE];
                end
            endcase
        end
        Alu: begin
            d2i.func = instr[`FUNC_RANGE];
            d2i.op = instr[`OPCODE_RANGE];
            d2i.wr_en = 1;
            d2i.dst = dst;
            d2i.src1 = (!src1_r) ? src1 : a;
            d2i.src2 = (!src2_r) ? src2 : b;
            d2i.src1_ready = src1_r;
            d2i.src2_ready = src2_r;
        end
        AluImm: begin
            d2i.func = instr[`FUNC_RANGE];
            d2i.op = instr[`OPCODE_RANGE];
            d2i.wr_en = 1;
            d2i.dst = dst;
            d2i.src1 = (!src1_r) ? src1 : a;
            d2i.src1_ready = src1_r;
            d2i.src2_ready = 1;
            d2i.imm = instr[`IMM15_RANGE];
        end
        Mem: begin
            d2i.func = instr[`FUNC_RANGE];
            d2i.op = instr[`OPCODE_RANGE];
            d2i.src1 = (!src1_r) ? src1 : a;
            d2i.src1_ready = src1_r;
            d2i.imm = instr[`IMM15_RANGE];
            case (mem_func'(instr[`FUNC_RANGE]))
                Load: begin
                    d2i.wr_en = 1;
                    d2i.dst = dst;
                    d2i.src2_ready = 1;
                end
                Store: begin
                    d2i.src2 = (!src2_r) ? src2 : b;
                    d2i.src2_ready = src2_r;
                    d2i.wr_en = 0;
                end
            endcase
        end
        Lui: begin
            d2i.src2_ready = 1;
            d2i.src1_ready = 1;
            d2i.func = instr[`FUNC_RANGE];
            d2i.op = instr[`OPCODE_RANGE];
            d2i.wr_en = 1;
            d2i.dst = dst;
            d2i.imm = instr[`IMM20_RANGE];
        end
    endcase
endtask