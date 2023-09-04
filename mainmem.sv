task store_mask;
    input int blk;
    input [`LINE_SIZE*32-1:0] indata;
    input word store_req_data;
    output [`LINE_SIZE*32-1:0] sdata;

    sdata = (`LINE_SIZE*32){1'b1};
    sdata[(blk+1)*32-1:blk*32] = 32{1'b0};
    sdata &= indata;
    sdata |= (store_req_data << blk*32);
endtask

module mainmem(
    input clk, rst,

    //from icache
    input word icache_req,
    input icache_requested,

    //from dcache
    input word dcache_req,
    input [`LINE_SIZE*32-1:0] dcache_req_data,
    input dcache_requested,
    input wire dcache_req_store,
    input wire writeback,

    //to icache
    output word icacheaddr,
    output [`LINE_SIZE*32-1:0] icachedata,
    output icachevalid,
    output wand mem_full_icache,

    //to dcache
    output word dcacheaddr,
    output [`LINE_SIZE*32-1:0] dcachedata,
    output dcachevalid,
    output wand mem_full
);

    reg [`MEM_LINES-1:0][`LINE_SIZE-1:0] memory;

    reg reqline [`ACTIVE_REQS-1:0] active_reqs;

    wire [`LINE_SIZE*32-1:0] sdata;

    wire grabbed_i; 
    wire grabbed_d; 

    always_comb begin
        foreach (active_reqs[i]) begin
            mem_full_icache = ~active_reqs[i].ready || (mem_full); //all but one filled
            mem_full = ~active_reqs[i].ready;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            foreach (active_reqs[i]) begin
                active_reqs[i].ready <= 1;
            end
            memory <= 0;
        end else begin
            foreach (active_reqs[i]) begin
                if (active_reqs[i].delay) begin
                    active_reqs[i].delay <= active_reqs[i].delay - 1;
                end else if (active_reqs[i].ready) begin
                    //add new requests
                    if (dcache_requested) begin
                        active_reqs[i] <= {dcache_req, dcache_req_data, 1'b0, dcache_req_store, dcache_req_writeback, `MEM_DELAY, 1'b0, 1'b0};
                        dcache_requested = 0;
                    end else if (icache_requested) begin
                        active_reqs[i] <= {icache_req, (`LINE_SIZE*32){1'b0}, 1'b1, 2'b0, `MEM_DELAY, 1'b0, 1'b0};
                        icache_requested = 0;
                    end
                end else if (!active_reqs[i].queued) begin
                    if (active_reqs[i].writeback) begin
                        //handle writes
                        memory[active_reqs[i].addr[`MEM_IDX_RG]] <= active_reqs[i].data;
                        active_reqs[i].ready <= 1;
                    end else if (active_reqs[i].store) begin
                        //handle loads with modified data
                        store_mask(active_reqs[i].addr[`CACHE_BLK_RG], memory[active_reqs[i].addr[`MEM_IDX_RG]], active_reqs[i].data[$clog2(`LINE_SIZE)-1:0], sdata)
                        active_reqs[i].data = sdata;
                        active_reqs[i].data <= sdata;
                        active_reqs[i].queued <= 1;
                    end else begin
                        //handle loads
                        active_reqs[i].data <= memory[active_reqs[i].addr[`MEM_IDX_RG]];
                        active_reqs[i].queued <= 1;
                    end
                end else begin
                    //delay ended and instruction ready - send first one to icache
                    if (active_reqs[i].is_i && !grabbed_i) begin
                        icachedata = active_reqs[i].data;
                        icacheaddr = active_reqs[i].addr;
                        icachevalid = active_reqs[i].valid;
                        active_reqs[i].ready <= 1;
                        grabbed_i = 1;
                    end
                    if (!active_reqs[i].is_i && !grabbed_d) begin
                        dcachedata = active_reqs[i].data;
                        dcacheaddr = active_reqs[i].addr;
                        dcachevalid = active_reqs[i].valid;
                        active_reqs[i].ready <= 1;
                        grabbed_d = 1;
                    end
                end
            end
        end
    end
endmodule