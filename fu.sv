module alu (
    input                          clk, rst,
    input I2E                           i2e,

    output E2M                          e2m,
    output [$clog2(`RS_SZ)-1:0] finished_rs
);
    word cmp_result;
    word sft_result;
    word npc_result;
    word addr_result;
    wire branch;
    word b;

    opcode op;
    alu_func alufunc;
    br_func brfunc;
    mem_func memfunc;

    wire valid_wire;
    I2E e2m_reg;
    I2E e2m;

    always_comb begin
        //grab result of old op
        e2m = e2m_reg;
        finished_rs = rs;
        valid_wire = 0;

        //generate next result
        op = opcode'(i2e.op);
        alufunc = alu_func'(i2e.func);
        brfunc = br_func'(i2e.func);
        memfunc = mem_func'(i2e.func)

        b = (op == AluImm) ? i2e.imm : i2e.src2;
        cmp cmp_0 (
            .a(i2e.src1)
            .b(b)
            .sign(func == Slt || op == Branch)
            .isLess(cmp_result)
        );
        shift sft_0 (
            .a(i2e.src1)
            .b(b)
            .dir(func == Sll)
            .sign(func == Sra)
            .shifted(sft_result)
        );

        br br_0 (
            .a(i2e.src1),
            .b(i2e.src2),
            .func(brfunc),
            .branch(branch)
        );
        branch |= (op == Jump);
        adder#(32) npc (
            .carry(0),
            .a(i2e.pc),
            .b((branch) ? i2e.imm : 4),
            .sum(npc_result)
        );

        adder#(32) ls_addr (
            .carry(0),
            .a(i2e.src1),
            .b(i2e.imm),
            .sum(addr_result)
        );

        case (op)
            Branch, Jump:
                result = npc_result;
            Alu, AluImm: begin
                case (alufunc)
                    And: begin
                        result = a & b;
                    end
                    Or: begin
                        result = a | b;
                    end
                    Slt, Sltu: begin
                        result = cmp_result;
                    end
                    Sll, Srl, Sra: begin
                        result = cmp_result;
                    end
                endcase
            end
            Mem:
                result = i2e.src2; //always drive, just won't check if it's a load
            Lui:
                result = {i2e.imm[19:0], 12{1'b0}};
        endcase

        valid_wire = i2e.valid; //make sure we've loaded in an instruction after latest grab
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            e2m_reg <= 0;
            rs <= 0;
            valid <= 0;
        end else begin
            e2m_reg.data <= result;
            e2m_reg.addr <= addr_result;
            e2m_reg.op <= i2e.op;
            e2m_reg.func <= i2e.func;
            e2m_reg.pc <= i2e.pc;
            e2m_reg.valid <= valid_wire;
            rs <= i2e.rs;
        end
    end
endmodule

module br (
    input word        a, b,
    input branch_func func,
    output          branch
);
    //if -a is ge -b, a is le b
    word isLess;

    always_comb begin
        cmp cmp_br (
            .a(-a),
            .b(-b)
            .sign(1)
            .isLess(isLess)
        );
        case (func)
            Beq, Beqz:
                branch = (a == b);
            Ble:
                branch = !isLess[0];
        endcase
    end
endmodule

module cmp (
    input word      a, b,
    input           sign,
    output word   isLess
);
    word b_greater;
    word a_greater;

    assign a_greater = a & (b ^ a);
    assign b_greater = b & (b ^ a);

    always_comb begin
        if (a[31] ^ b[31]) begin //handling sign
            isLess = (sign) ? a[31] : b[31];
        end
        else begin
            if (b_greater[30:0] == 0) begin
                isLess = 0;
            end else begin
                for (int i = 30; i >= 0; i--) begin
                    if (a_greater[i]) begin
                        isLess = 0;
                        break;
                    end
                end
                isLess = 1;
            end
        end
    end
endmodule

module shift (
    input word     a, b,
    input           dir, //1 for left 0 for right
    input          sign,
    output word shifted
);
    always_comb begin
        shifted = (b[4]) ? (dir) ? {a[0:15], 16{1'b0}} : {16{sign}, a[31:16]} : a;
        shifted = (b[3]) ? (dir) ? {a[0:23], 8{1'b0}} : {8{sign}, a[31:8]} : shifted;
        shifted = (b[2]) ? (dir) ? {a[0:27], 4{1'b0}} : {4{sign}, a[31:4]} : shifted;
        shifted = (b[1]) ? (dir) ? {a[0:29], 2{1'b0}} : {2{sign}, a[31:2]} : shifted;
        shifted = (b[0]) ? (dir) ? {a[0:30], 1{1'b0}} : {1{sign}, a[31:2]} : shifted;
    end
endmodule


module adder #(parameter N = 32) (
    input        carry,
    input [N-1:0] a, b,

    output [N-1:0] sum
);
    wire [32:0] upperBit;
    wire [32:0] lowerBit;
    wire [32:0] cvec;
    
    always_comb begin
        upperBit = {a & b, 0};
        lowerBit = {a | b, 0};

        for (int i = 1, i < N; i << 1) begin
            upperBit[N:i+1] = upperBit[N:i+1] | (lowerBit[N:i+1] & upperBit[N-i:1]);
            lowerBit[N:i+1] = lowerBit[N:i+1] & lowerBit[N-i:1];
        end

        cvec = upperBit | (lowerBit & (32+1){carry});
        sum = a ^ b ^ cvec[n-1:0];
    end
endmodule

module add (
    input                          clk, rst,
    input I2E                           i2e,

    output E2M                          e2m,
    output [$clog2(`RS_SZ)-1:0] finished_rs
);
    word b;
    word sum;
    logic valid;
    wire valid_wire;

    I2E e2m_reg;
    I2E e2m;

    always_comb begin
        //grab result of old sum
        e2m = e2m_reg;
        finished_rs = rs;
        valid_wire = 0;

        //generate next sum
        b = (opcode'(i2e.op) == AluImm) ? i2e.imm : i2e.src2;
        adder#(32) adder_0 (
            .carry(1),
            .a(i2e.src1)
            .b(b)
            .sum(sum)
        );
        valid_wire = i2e.valid; //make sure we've loaded in an instruction after latest grab
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            e2m_reg <= 0;
            rs <= 0;
            valid <= 0;
        end else begin
            e2m_reg.data <= sum;
            e2m_reg.op <= i2e.op;
            e2m_reg.func <= i2e.func;
            e2m_reg.pc <= i2e.pc;
            e2m_reg.valid <= valid_wire;
            rs <= i2e.rs;
        end
    end
endmodule

module mul(
    input                          clk, rst,
    input I2E                           i2e,

    output E2M                          e2m,
    output logic                    FU_free,
    output [$clog2(`RS_SZ)-1:0] finished_rs
);
    wire [64:0] a_wire;
    word b_wire;
    wire [4:0] i_wire;
    wire [64:0] accum;
    wire [64:0] partial_product;
    wire [64:0] accum_tmp;
    wire finished;

    reg [64:0] a_reg;
    word b_reg;
    reg [4:0] i_reg;
    reg [$clog2(`RS_SZ)-1:0] rs;

    I2E e2m_reg;
    I2E e2m;

    always_comb begin
        FU_free = (i_reg == 0);

        //grabbing finished mul data
        if (i_reg == 31) begin
            e2m = e2m_reg;
            e2m.valid = 1; //can only reach ireg = 31 if we had an entering valid instruction
            FU_free = 1;
            finished_rs = rs;
            exe_data = accum_reg;
        end

        //doing the actual mul
        a_wire = (FU_free) ? {(32){1'b0}, i2e} : a_reg;
        b_wire = (FU_free) ? (opcode'(i2e.op) == AluImm) ? i2e.imm : i2e.src2 : b_reg;
        i_wire = (i_reg == 31) ? 0 : i_reg;
        accum = (i_reg == 31) ? 0 : accum_reg;

        partial_product = (64){b[0]};
        partial_product = a_wire & partial_product;

        repeat (8) begin
            adder#(64) partial_product(
                .carry(0)
                .a(partial_product)
                .b(accum)
                .sum(accum_tmp)
            );
            a_wire = a_wire << 1;
            b_wire = b_wire >> 1;
            accum = accum_tmp;
            if (!FU_free || i2e.valid) begin
                i_wire = (i_wire == 31) ? i_wire : i_wire + 1; //saturating counter
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            a_reg <= 0;
            b_reg <= 0;
            i_reg <= 0;
            rs <= 0;
            e2m_reg <= 0;
        end else begin
            a_reg <= a_wire;
            b_reg <= b_wire;
            e2m_reg.data <= accum;
            i_reg <= i_wire;
            rs <= (FU_free && i2e.valid) ? i2e.rs : rs;

            e2m_reg.op <= i2e.op;
            e2m_reg.func <= i2e.func;
            e2m_reg.pc <= i2e.pc;
        end
    end
endmodule