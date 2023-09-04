task isHit;
    input cacheline [1:0] [`NUM_LINES-1:0] sram;
    input word pc;
    output [1:0] ld_hit; //last bit is 1 if miss

    ld_hit = 2;
    foreach (sram[i]) begin
        if (pc[`CACHE_TAG_RG] == sram[i][pc[`CACHE_IDX_RG]].tag && sram[i][pc[`CACHE_IDX_RG]].valid) begin
            ld_hit = i;
            break; //take first one
        end
    end
endtask

module icache(
    input clk, rst,
    //to read, from fetch
    input word [`SUPER-1:0] PCVec,
    //from memory
    input word memaddr,
    input [`LINE_SIZE*32-1:0] memdata,
    input memvalid,
    input mem_full_icache,

    //to fetch
    output word [`SUPER-1:0] data,
    output [`SUPER-1:0] data_valid,

    //look up in mem
    output word icache_req,
    output wire requested,
);
    reg cacheline [1:0] [`NUM_LINES-1:0] sram;
    word prefetch;
    reg LRU;

    wire [1:0] ld_hit;
    wire LRU_wire;
    wire new_write;
    wire requested;
    wire [$clog2(`PREFETCH)-1:0] prefetch_left; //don't fetch too far ahead lol
    wire [$clog2(`LINE_SIZE)-1:0] blk;

    always_comb begin
        LRU_wire = LRU;
        //process fetch data with new memory addition
        foreach (PCVec[i]) begin
            isHit(sram_wire, PCVec[i], ld_hit);
            blk = PCVec[i][`CACHE_BLK_RG];
            if (!ld_hit[1]) begin
                data[i] = sram[ld_hit[0]][PCVec[i][`CACHE_IDX_RG]].data[(blk+1)*32-1:blk*32];
                valid[i] = 1;
                LRU_wire = ~ld_hit[0];
            end else if (PCVec[i] == memaddr && memvalid) begin
                data[i] = memdata[(blk+1)*32-1:blk*32];
                valid[i] = 1;
                new_write = LRU_wire;
            end else if (!requested) begin
                icache_req = PCVec[i];
                requested = 1;
            end
        end

        if (!requested && prefetch_left) begin
            icache_req = prefetch;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sram <= 0; //invalid
            prefetch <= 0;
            LRU <= 0;
        end else begin
            if (memvalid) begin
                sram[new_write][memaddr[`CACHE_IDX_RG]] <= {1, 0, memdata, memaddr[`CACHE_TAG_RG]};
            end
            prefetch <= (mem_full_icache) ? icache_req : icache_req + 4*`LINE_SIZE;
            if (!requested && prefetch_left) begin
                prefetch_left <= prefetch_left - 1;
            end else if (requested) begin
                prefetch_left <= `PREFETCH;
            end
            LRU <= LRU_wire;
        end
    end

endmodule

task store_mask;
    input int blk;
    input word addr;
    input [`LINE_SIZE*32-1:0] indata;
    output [`LINE_SIZE*32-1:0] sdata;

    sdata = (`LINE_SIZE*32){1'b1};
    sdata[(blk+1)*32-1:blk*32] = 32{1'b0};
    sdata &= indata;
    sdata |= (store_req_data << blk*32);
endtask

module dcache(
    input clk, rst,

    //from loadstore
    input load_req,
    input word load_req_addr,
    input store_req,
    input word store_req_addr,
    input word store_req_data,

    //from memory
    input word memaddr,
    input [`LINE_SIZE*32-1:0] memdata,
    input memvalid,
    input mem_full,

    //to loadstore
    output word data,
    output data_valid,
    output store_sent,

    //look up in mem
    output word dcache_req,
    output [`LINE_SIZE*32-1:0] dcache_req_data,
    output wire requested,
    output wire dcache_req_store,
    output wire writeback,
);
    reg cacheline [1:0] [`NUM_LINES-1:0] sram;
    reg LRU;

    wire [1:0] ld_hit;
    wire [1:0] st_hit;
    wire [1:0] mem_hit;
    wire LRU_wire;
    wire new_write;
    wire requested;

    wire [$clog2(`LINE_SIZE)-1:0] blk;
    wire [`LINE_SIZE*32-1:0] sdata;
    
    //writeback
    wb_request last_wb;
    wb_request last_wb_wire;
    wire wb_pending;

    //when data 
    always_comb begin
        LRU_wire = LRU;

        last_wb_wire.pending = 0;
        //attempt to write pending dirty lines to cache, first
        if (last_wb.pending && !mem_full) begin
            dcache_req = last_wb.addr;
            dcache_req_data = last_wb.data;
            writeback = 1;
            requested = 1;
        end

        if (memvalid) begin
            isHit(sram_wire, memaddr, mem_hit);
            if (mem_hit[1] && sram[LRU][memaddr[`CACHE_IDX_RG]].dirty) begin
                //writeback
                if (!mem_full && !requested) begin
                    dcache_req = {sram[LRU][memaddr[`CACHE_IDX_RG]].tag, memaddr[`CACHE_IDX_RG], (BLK_BYT_OFFSET){1'b0}};
                    dcache_req_data = sram[LRU][memaddr[`CACHE_IDX_RG]].data;
                    writeback = 1;
                    requested = 1;
                end else begin
                    last_wb_wire.addr = {sram[LRU][memaddr[`CACHE_IDX_RG]].tag, memaddr[`CACHE_IDX_RG], (BLK_BYT_OFFSET){1'b0}};
                    last_wb_wire.data = sram[LRU][memaddr[`CACHE_IDX_RG]].data;
                    last_wb_wire.pending = 1;
                end
            end
        end

        if (load_req) begin
            isHit(sram_wire, load_req_addr, ld_hit);
            blk = load_req_addr[`CACHE_BLK_RG];
            if (load_req_addr == store_req_addr && store_req) begin //store to load fwd
                data = store_req_data;
                valid = 1;
                LRU_wire = ~ld_hit[0];
            end else if (!ld_hit[1]) begin
                data = sram[ld_hit[0]][load_req_addr[`CACHE_IDX_RG]].data[(blk+1)*32-1:blk*32];
                valid = 1;
                LRU_wire = ~ld_hit[0];
            end else if (load_req_addr == memaddr && memvalid) begin //mem fwd
                data = memdata[(blk+1)*32-1:blk*32];
                valid = 1;
                new_write = LRU;
            end else if (!mem_full) begin //once memory gets unfull we'll just make the same request
                dcache_req = load_req_addr;
                dcache_req_store = 0;
                requested = 1;
            end
        end

        if (store_req) begin
            isHit(sram_wire, store_req_addr, st_hit);
            if (!st_hit[1]) begin
                store_mask(store_req_addr[`CACHE_BLK_RG], sram[st_hit][store_req_addr[`CACHE_IDX_RG]].data, store_req_data, sdata);
                new_write = st_hit[0];
                store_sent = 1;
            end else if (store_req_addr == memaddr && memvalid) begin
                store_mask(store_req_addr[`CACHE_BLK_RG], memdata, store_req_data, sdata); //update incoming data
                new_write = LRU;
                store_sent = 1;
            end else if (!mem_full && !requested) begin
                dcache_req = store_req_addr;
                dcache_req_data = {((`LINE_SIZE-1)*32){1'b0}, store_req_data};
                dcache_req_store = 1;
                requested = 1;
                store_sent = 1;
            end
        end

    end

    always_ff @(posedge clk) begin
        if (rst) begin
            sram <= 0; //invalid
            LRU <= 0;
            last_wb <= 0;
            last_wb_addr <= 0;
            last_wb_pending <= 0;
        end else begin
            if (store_req && (!st_hit[1] || store_req_addr == memaddr)) begin
                sram[new_write][store_req_addr[`CACHE_IDX_RG]] <= {1, 1, sdata, store_req_addr[`CACHE_TAG_RG]};
            end
            if (memvalid && mem_hit[1] && store_req_addr != memaddr) begin
                sram[new_write][memaddr[`CACHE_IDX_RG]] <= {1, memdata, memaddr[`CACHE_TAG_RG]};
            end
            last_wb <= last_wb_wire;
            LRU <= LRU_wire;
        end
    end

endmodule