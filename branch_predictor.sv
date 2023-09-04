task isHit;
    input branch_predictor_line [`BTB_WAYS-1:0][`BTB_SZ-1:0] BTB; 
    input word pc;
    output [$clog2(`BTB_WAYS):0] hit; //last bit is 1 if miss

    hit = `BTB_WAYS;
    foreach (BTB[i]) begin
        if (pc[`BTB_TAG_RANGE] == BTB[i][pc[`BTB_IDX_RANGE]].tag) begin
            hit = i;
            break; //take first one
        end
    end
endtask

module branch_predictor (
    input                              clk, rst,
    input [`SUPER-1:0]          is_branch_instr,
    input [`SUPER-1:0]            is_jump_instr,
    input word                          jump_pc,
    input word [`SUPER-1:0]         PC_to_check,

    input word [`SUPER-1:0]       actual_nextpc, //after checking PCs from decode, update with new data from execute
    input [`SUPER-1:0]               mispredict,

    output wire [`SUPER-1:0]       branch_taken, //if cache miss, just guess not taken
    output word                predicted_nextPC
);
    reg [$clog2(`BTB_WAYS)-1:0] LRU;
    wire [$clog2(`BTB_WAYS)-1:0] LRU_wire;
    reg branch_predictor_line [`BTB_WAYS-1:0][`BTB_SZ-1:0] BTB; 

    wire [`SUPER-1:0][$clog2(`BTB_SZ)-1:0] idx_bits;
    wire [`SUPER-1:0][32-$clog2(`BTB_SZ)-1:0] tag_bits;
    for (int i = 0; i < `SUPER; i++) {
        assign idx_bits[i] = PC_to_check[i][$clog2(`BTB_SZ)+1:2];
        assign tag_bits[i] = PC_to_check[i][31:$clog2(`BTB_SZ)+2];
    }


    always_comb begin
        //Lookup @ decode
        for (int i = 0; i < `SUPER; i++) begin
            branch_taken = 0; //cache miss, isn't even a branch instruction, or branch not taken
            if (!is_branch_instr[i]) continue;
            isHit(BTB, PC_to_check[i], hit);
            if (hit[$clog2(`BTB_WAYS)]) continue; //miss
            branch_taken[i] = BTB[hit][PC_to_check[i][BTB_IDX_RANGE]].counter[1];
            if (branch_taken[i]) begin
                predicted_nextPC = BTB[hit][PC_to_check[i][BTB_IDX_RANGE]].redirect; 
                if (BTB[hit][PC_to_check[i][BTB_IDX_RANGE]].counter < 2'b11) begin
                    BTB[hit][PC_to_check[i][BTB_IDX_RANGE]].counter++;
                end
                break; //take earliest branch
            end
            else if (is_jump_instr[i]) begin
                predicted_nextPC = jump_pc;
                break;
            end else begin
                if (BTB[hit][PC_to_check[i][BTB_IDX_RANGE]].counter > 2'b00) begin
                    BTB[hit][PC_to_check[i][BTB_IDX_RANGE]].counter--;
                end
            end
        end

        if (~&branch_taken) begin
            predicted_nextPC = PC_to_check[`SUPER-1] + 4;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            LRU <= 0;
            foreach (BTB[i][j]) begin
                BTB[i][j].redirect <= 0;
                BTB[i][j].tag <= 0;
                BTB[i][j].counter <= 2'b01; //initialize counters halfway between counter[1] = 1 and = 0 (so at 01)          
            end
        end
        //Fill with correct values
        else begin
            LRU_wire = LRU;
            for (int i = 0; i < `SUPER; i++) begin
                if (!mispredict[i]) continue;
                hit = isHit(i)
                if (!hit[$clog2(`BTB_WAYS)]) begin
                    BTB[hit][PC_to_check[i][BTB_IDX_RANGE]].redirect <= actual_nextpc[i];
                    BTB[hit][PC_to_check[i][BTB_IDX_RANGE]].counter <= 2'b01; //haven't logged predictions yet
                end
                else begin
                    BTB[LRU_wire][PC_to_check[i][BTB_IDX_RANGE]].tag <= tag_bits[i];
                    BTB[LRU_wire][PC_to_check[i][BTB_IDX_RANGE]].redirect <= actual_nextpc[i];
                    BTB[LRU_wire][PC_to_check[i][BTB_IDX_RANGE]].counter <= 2'b01; //haven't logged predictions yet

                    LRU_wire = (LRU_wire + 1)[$clog2(`BTB_WAYS)-1:0];//invariant: fills from left + right then back around
                end
            end
            LRU <= LRU_wire;
        end
    end
endmodule