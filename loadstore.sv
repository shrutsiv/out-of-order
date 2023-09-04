task hash;
    input word pc;
    output logic [$clog2(`LFST_SZ)-1:0] ssid;
    int padding_amt;

    for (int i = $clog2(`LSFT_SZ)-1; i < 32; i += $clog2(`LFST_SZ)) begin
        ssid ^= pc[i:i-($clog2(`LSFT_SZ)-1)];
    end
endtask

//also figure out how to handle store dependencies, but i'll do that after i write my cache
module loadstore(
    input clk, rst,
    //from decode
    input d2e [`SUPER-1:0] issued_instrs,

    //from execute
    input e2m [`SUPER-1:0] exec_instrs,

    //from reservation
    input [`SUPER-1:0][`$clog2(`RS_SZ)-1:0] issued_rs;
    input [`SUPER-1:0][`$clog2(`LSQ_SZ)-1:0] ready_lsq;

    //from rob
    input [`SUPER-1:0][clog$(`LSQ_SZ)-1:0] committed_lsq,
    input [`SUPER-1:0] is_ls_commit, , committed_wr_en, committed_valid,
    input [$clog2(`LSQ_SZ)-1:0] first_lq_inv, first_sq_inv,
    input first_lq_inv_v, first_sq_inv_v
    input rob_flush,

    //from fetch
    input word [`SUPER-1:0] pc_check_dep,
    input [`SUPER-1:0][1:0] is_ls,

    //from cache
    input word cache_data,
    input cache_valid,
    input store_sent,

    //to reservation
    output [`SUPER-1:0][`LSQ_SZ-1:0] incoming_lsq,
    output [`SUPER-1:0][$clog2(`RS_SZ)-1:0] exe_ld_rs,
    output word [`SUPER-1:0] exe_ld_data,
    output [`SUPER-1:0] exe_ld_valid,
    output [$clog2(`RS_SZ)-1:0] mem_ld_rs,
    output word mem_ld_data,
    output mem_ld_valid,

    //to decode
    output [`SUPER-1:0][31:2] inums,

    //to dcache
    output wire load_req,
    output word load_req_addr,
    output wire store_req,
    output word store_req_addr,
    output word store_req_data,

    //control flow
    output stall,
    output flush,
    output redirectPC,
);
    reg lq_line [LSQ_SZ] lq_reg;
    reg sq_line [LSQ_SZ] sq_reg;
    reg [$clog(`LSQ_SZ)-1:0] lq_head;
    reg [$clog(`LSQ_SZ)-1:0] sq_head;
    reg [$clog(`LSQ_SZ)-1:0] lq_tail;
    reg [$clog(`LSQ_SZ)-1:0] sq_tail;

    wire lq_line [LSQ_SZ] lq_wire;
    wire sq_line [LSQ_SZ] sq_wire;
    wire [$clog(`LSQ_SZ)-1:0] lq_head_wire;
    wire [$clog(`LSQ_SZ)-1:0] sq_head_wire;
    wire [$clog(`LSQ_SZ)-1:0] lq_tail_wire;
    wire [$clog(`LSQ_SZ)-1:0] sq_tail_wire;

    //load execution
    wire [$clog(`LSQ_SZ)-1:0] fwded;
    wire [$clog(`LSQ_SZ)-1:0] dep_resolved;
    wire dep;
    reg [$clog(`LSQ_SZ)-1:0] last_req;
    wire [$clog(`LSQ_SZ)-1:0] last_req_wire;

    //store execution
    reg sreq_made;
    reg [$clog(`LSQ_SZ)-1:0] last_sreq;
    wire [$clog(`LSQ_SZ)-1:0] last_sreq_wire;

    //store-set predictor
    reg SSIT_entry [`SSIT_SZ-1:0] SSIT_reg;
    wire SSIT_entry [`SSIT_SZ-1:0] SSIT_wire;
    reg LSFT_entry [`LFST_SZ-1:0] LFST_reg;
    wire LSFT_entry [`LFST_SZ-1:0] LFST_wire;
    wire [$clog2(`LFST_SZ)-1:0] new_ssid;

    always_comb begin
        lq_wire = lq_reg;
        sq_wire = sq_reg;
        

        //grab new cache value
        mem_ld_valid = cache_valid;
        if (cache_valid) begin
            lq_wire[last_req].datastate = 2'b01;
            lq_wire[last_req].data = cache_data;

            mem_ld_data = cache_data;
            mem_ld_rs = lq_wire[last_req].rs;
        end

        //send dependencies to fetched instrs
        foreach(pc_check_dep[i]) begin
            if (is_ls[i] == 1) begin
                if (SSIT_wire[pc_check_dep[i][`SSIT_IDX_RANGE]].counter[1]) begin
                    if (LFST_wire[SSIT_wire[pc_check_dep[i][`SSIT_IDX_RANGE]].ssid].valid) begin
                        inums[i] = LFST_wire[SSIT_wire[pc_check_dep[i][`SSIT_IDX_RANGE]].ssid].inum;
                    end
                end
            end else if (is_ls[i] == 2) begin
                if (SSIT_wire[pc_check_dep[i][`SSIT_IDX_RANGE]].counter[1]) begin
                    if (LFST_wire[SSIT_wire[pc_check_dep[i][`SSIT_IDX_RANGE]].ssid].valid) begin
                        inums[i] = LFST_wire[SSIT_wire[pc_check_dep[i][`SSIT_IDX_RANGE]].ssid].inum;
                    end
                    //add dependency to yourself for future loads/stores
                    LFST_wire[SSIT_wire[pc_check_dep[i][`SSIT_IDX_RANGE]].ssid].inum = pc_check_dep[i][31:2];
                    LFST_wire[SSIT_wire[pc_check_dep[i][`SSIT_IDX_RANGE]].ssid].valid = 1;
                end
            end
        end

        //Grabbing calculated addresses from alu
        foreach(exec_instrs[i]) begin
            if (!(exec_instrs[i].valid && opcode'(exec_instrs[i].op) == Mem)) continue;
            case (mem_func'(exec_instrs[i].func))
                Load: begin
                    if (!lq_wire[ready_lsq[i]].datastate) begin
                        lq_wire[ready_lsq[i]].addr = exec_instrs[i].addr;
                        lq_wire[ready_lsq[i]].datastate = 2'b01;
                    end
                end
                Store: begin
                    if (!sq_wire[ready_lsq[i]].ready) begin
                        sq_wire[ready_lsq[i]].addr = exec_instrs[i].addr;
                        sq_wire[ready_lsq[i]].data = exec_instrs[i].data;
                        sq_wire[ready_lsq[i]].ready = 1;

                        //forwarding to dependent loads
                        foreach (lq_wire[j]) begin
                            if (lq_wire[j].occupied && sq_wire[ready_lsq[i]].pc[31:2] == lq_wire[i].inum) begin
                                lq_wire[j].data = exec_instrs[i].data;
                                dep_resolved[j] = 1;

                                exe_ld_rs[i] = lq_wire[j].rs;
                                exe_ld_data[i] = sq_wire[j].data;
                                exe_ld_valid[i] = 1;
                            end
                        end
                    end
                end
            endcase
        end

        //execute newly ready loads
        int j;
        foreach(exec_instrs[i]) begin
            if (!(exec_instrs[i].valid && opcode'(exec_instrs[i].op) == Mem)) continue;
            if (!(mem_func'(exec_instrs[i].func) == Load && lq_wire[ready_lsq[i]].datastate == 2'b01)) continue;
            dep = 0;
            j = lq_wire[ready_lsq[i]].age;
            while (j != sq_head) begin
                j = (j - 1) % `LSQ_SZ;
                //wait for unresolved dependency
                if (sq_wire[j].pc[31:2] == lq_wire[ready_lsq[i]].inum && !dep_resolved[i]) begin
                    dep = 1;
                    break;
                end
                //or, store to load forward
                if (sq_wire[j].ready && sq_wire[j].addr == lq_wire[ready_lsq[i]].addr) begin
                    lq_wire[ready_lsq[i]].data = sq_wire[j].data;
                    fwded[i] = 1;
                    exe_ld_data[i] = sq_wire[j].data;
                    exe_ld_valid[i] = 1;
                    break;
                end
            end
            if (!fwded[i] && !dep) begin
                lq_wire[ready_lsq[i]].datastate = 2'b10; //need to at some point request from memory
            end
        end

        //send new request to cache if last read finished
        last_req_wire = last_req;
        if (!lq_wire[last_req].datastate != 2'b11) begin
            for (int i = lq_head; i < lq_tail; i++) begin
                if (lq_wire[i].datastate == 2'b10) begin
                    load_req = 1;
                    load_req_addr = lq_wire[i].addr;
                    lq_wire[i].datastate = 2'b11; //waiting on cache results
                    last_req_wire = i;
                    break;
                end
            end
        end else begin
            load_req = 1;
            load_req_addr = lq_wire[last_req].addr;
        end

        //grabbing committed loads/stores from rob
        foreach(committed_lsq[i]) begin
            if (!(committed_valid[i] && is_ls_commit[i])) continue;
            if (committed_wr_en[i]) begin
                lq_wire[committed_lsq[i]].commit = 1;
            end else begin
                sq_wire[committed_lsq[i]].commit = 1;
            end
        end

        //Allocating space in LSQ at issue
        lq_tail_wire = lq_tail;
        sq_tail_wire = lq_tail;

        foreach(issued_instrs[i]) begin
            if (issued_instrs[i].valid && opcode'(issued_instrs[i].op) == Mem) begin
                case (mem_func'(issued_instrs[i].func))
                    Load: begin
                        if (lq_wire[lq_tail_wire].occupied) begin
                            stall = 1;
                            break;
                        end
                        //older stores will be stores after/including the store head, < the lq age
                        //bc sq_tail_wire is the position of the next store
                        lq_wire[lq_tail_wire].age = sq_tail_wire;
                        lq_wire[lq_tail_wire].occupied = 1;
                        lq_wire[lq_tail_wire].ready = 0;
                        lq_wire[lq_tail_wire].commit = 0;
                        lq_wire[lq_tail_wire].raw = 0;
                        lq_wire[lq_tail_wire].pc = issued_instrs[i].pc;
                        lq_wire[lq_tail_wire].inum = issued_instrs[i].inum;
                        lq_wire[lq_tail_wire].rs = issued_rs[i];
                        incoming_lsq[i] = lq_tail_wire; 

                        lq_tail_wire = (lq_tail + 1)[$clog2(`LSQ_SZ)-1:0];
                    end
                    Store: begin
                        if (sq_wire[sq_tail_wire].occupied) begin
                            stall = 1;
                            break;
                        end
                        //younger loads will be loads before the tail, >= the sq age
                        sq_wire[sq_tail_wire].age = lq_tail_wire;
                        sq_wire[sq_tail_wire].occupied = 1;
                        sq_wire[lq_tail_wire].ready = 0;
                        sq_wire[lq_tail_wire].commit = 0;
                        sq_wire[lq_tail_wire].raw = 0;
                        sq_wire[lq_tail_wire].pc = issued_instrs[i].pc;
                        sq_wire[lq_tail_wire].inum = issued_instrs[i].inum;
                        incoming_lsq[i] = sq_tail_wire; 

                        sq_tail_wire = (sq_tail + 1)[$clog2(`LSQ_SZ)-1:0];

                        //invalidate dependence on PC at issue
                        if (SSIT_wire[issued_instrs[i].pc[`SSIT_IDX_RANGE]].counter[1]) begin
                            if (LFST_wire[SSIT_wire[issued_instrs[i].pc[`SSIT_IDX_RANGE]].ssid].inum = issued_instrs[i].pc[31:2]) begin
                                LFST_wire[SSIT_wire[issued_instrs[i].pc[`SSIT_IDX_RANGE]].ssid].valid = 0;
                            end
                        end
                    end
                endcase
            end
        end

        //committing store
        sq_head_wire = sq_head;
        last_sreq_wire = last_sreq;
        if (store_sent || !sreq_made) begin
            store_req = 0;
            if (sq_wire[sq_head_wire].commit && sq_wire[sq_head_wire].ready && sq_head_wire != sq_tail_wire) begin
                store_req_addr = sq_wire[sq_head_wire].addr;
                store_req_data = sq_wire[sq_head_wire].data;
                store_req = 1'b1;
                last_sreq_wire = sq_head_wire;

                //SSIT feedback
                j = sq_wire[sq_head_wire].age;
                while (j != lq_tail) begin
                    //if there is a predicted dependence
                    if (lq_wire[j].inum == sq_wire[sq_head_wire].pc[31:2]) begin
                        if (lq_wire[j].addr == sq_wire[sq_head_wire].addr) begin
                            if (SSIT_wire[sq_wire[sq_head_wire].pc[`SSIT_IDX_RANGE]].counter < 2'b11) begin
                                SSIT_wire[sq_wire[sq_head_wire].pc[`SSIT_IDX_RANGE]].counter++;
                            end
                            if (SSIT_wire[lq_wire[j].pc[`SSIT_IDX_RANGE]].counter < 2'b11) begin
                                SSIT_wire[lq_wire[j].pc[`SSIT_IDX_RANGE]].counter++;
                            end
                        end else begin
                            //too trigger happy w the dependencies
                            if (SSIT_wire[sq_wire[sq_head_wire].pc[`SSIT_IDX_RANGE]].counter > 0) begin
                                SSIT_wire[sq_wire[sq_head_wire].pc[`SSIT_IDX_RANGE]].counter--;
                            end
                            if (SSIT_wire[lq_wire[j].pc[`SSIT_IDX_RANGE]].counter > 0) begin
                                SSIT_wire[lq_wire[j].pc[`SSIT_IDX_RANGE]].counter--;
                            end
                        end
                    end else begin
                        //want to get first dependence not already resolved on that initial cycle
                        if (sq_wire[sq_head_wire].addr == lq_wire[j].addr && !(fwded[j] || lq_wire[j].raw)) begin
                            lq_wire[j].raw = 1;
                            lq_wire[j].dependent_store = sq_head_wire;
                        end
                    end
                    j = (j + 1) % `LSQ_SZ;
                end
                sq_head_wire.occupied = 0;
                sq_head_wire.raw = 0;
                sq_head_wire = (sq_head_wire + 1)[`LSQ_SZ-1:0];
            end
        end else begin
            store_req_addr = sq_wire[last_sreq_wire].addr;
            store_req_data = sq_wire[last_sreq_wire].data;
            store_req = 1'b1;
        end


        //committing load
        lq_head_wire = lq_head;
        if (lq_wire[lq_head_wire].commit && lq_wire[lq_head_wire].ready && lq_head_wire != lq_tail_wire) begin
            if (lq_wire[lq_head_wire].raw) begin
                case ({
                SSIT_wire[lq_wire[lq_head_wire].pc[`SSIT_IDX_RANGE]].counter[1], 
                SSIT_wire[sq_wire[lq_wire[lq_head_wire].dependent_store].pc[`SSIT_IDX_RANGE]].counter[1]
                })
                    2'b00: begin
                        hash(lq_wire[lq_head_wire].pc, new_ssid);
                        SSIT_wire[lq_wire[lq_head_wire].pc[`SSIT_IDX_RANGE]].ssid = new_ssid;
                        SSIT_wire[lq_wire[lq_head_wire].pc[`SSIT_IDX_RANGE]].counter = 2'b11;
                        SSIT_wire[sq_wire[lq_wire[lq_head_wire].dependent_store].pc[`SSIT_IDX_RANGE]].counter = 2'b11;
                        SSIT_wire[sq_wire[lq_wire[lq_head_wire].dependent_store].pc[`SSIT_IDX_RANGE]].ssid = new_ssid;
                    end
                    2'b01: begin
                        SSIT_wire[sq_wire[lq_wire[lq_head_wire].dependent_store].pc[`SSIT_IDX_RANGE]].counter = 2'b11;
                        SSIT_wire[sq_wire[lq_wire[lq_head_wire].dependent_store].pc[`SSIT_IDX_RANGE]].ssid = SSIT_wire[lq_wire[lq_head_wire].pc[`SSIT_IDX_RANGE]].ssid;
                    end
                    2'b10: begin
                        SSIT_wire[lq_wire[lq_head_wire].pc[`SSIT_IDX_RANGE]].ssid = SSIT_wire[sq_wire[lq_wire[lq_head_wire].dependent_store].pc[`SSIT_IDX_RANGE]].ssid;
                        SSIT_wire[lq_wire[lq_head_wire].pc[`SSIT_IDX_RANGE]].counter = 2'b11;
                    end
                    2'b11: begin
                        //arbitrarily pick larger ssid so we don't trade evicting dependencies + lose both
                        if (SSIT_wire[lq_wire[lq_head_wire].pc[`SSIT_IDX_RANGE]].ssid > SSIT_wire[sq_wire[lq_wire[lq_head_wire].dependent_store].pc[`SSIT_IDX_RANGE]].ssid) begin
                            SSIT_wire[sq_wire[lq_wire[lq_head_wire].dependent_store].pc[`SSIT_IDX_RANGE]].ssid = SSIT_wire[lq_wire[lq_head_wire].pc[`SSIT_IDX_RANGE]].ssid;
                        end else begin
                            SSIT_wire[lq_wire[lq_head_wire].pc[`SSIT_IDX_RANGE]].ssid = SSIT_wire[sq_wire[lq_wire[lq_head_wire].dependent_store].pc[`SSIT_IDX_RANGE]].ssid;
                        end
                    end
                endcase
                flush = 1;
                redirectPC = lq_wire[lq_head_wire].pc;
            end
            lq_wire[lq_head_wire].occupied = 0;
            lq_head_wire = (lq_head_wire + 1)[`LSQ_SZ-1:0];
        end

        //flush
        if (rob_flush) begin
            if (first_lq_inv_v) begin
                int i = first_lq_inv;
                while (i != lq_tail_wire) begin
                    lq_wire[i].occupied = 0;
                    i = (i + 1) % `LSQ_SZ; 
                end
                lq_tail_wire = first_lq_inv;
                int i = lq_wire[first_lq_inv].age;
                while (i != sq_tail_wire) begin
                    sq_wire[i].occupied = 0;
                    i = (i + 1) % `LSQ_SZ; 
                end
                sq_tail_wire = lq_wire[first_lq_inv].age;
            end
            if (first_sq_inv_v) begin
                int i = first_sq_inv;
                while (i != sq_tail_wire) begin
                    sq_wire[i].occupied = 0;
                    i = (i + 1) % `LSQ_SZ; 
                end
                sq_tail_wire = first_sq_inv;
                int i = sq_wire[first_sq_inv].age;
                while (i != lq_tail_wire) begin
                    lq_wire[i].occupied = 0;
                    i = (i + 1) % `LSQ_SZ; 
                end
                lq_tail_wire = sq_wire[first_lq_inv].age;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            last_req <= 0;
            sreq_made <= 0;
            last_sreq <= 0;
            lq_reg <= 0;
            sq_reg <= 0;
            lq_head <= 0;
            lq_tail <= 0;
            sq_head <= 0;
            sq_tail <= 0;
        end else begin
            last_req <= last_req_wire;
            sreq_made <= store_req;
            last_sreq <= last_sreq_wire;
            lq_reg <= lq_wire;
            sq_reg <= sq_wire;
            lq_head <= lq_head_wire;
            lq_tail <= lq_tail_wire;
            sq_head <= sq_head_wire;
            sq_tail <= sq_tail_wire;
        end
    end
endmodule