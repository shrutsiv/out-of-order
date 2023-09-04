module fetch (
    input clk, rst,  //clock and reset
    
    //from decode
    input FetchAction action,   //stall, dequeue, or redirect
    input word predicted_nextPC,
    input word redirectPC,

    //from cache
    input word [`SUPER-1:0] dataFromI$,
    input [`SUPER-1:0] validFromI$,

    //to cache
    output word [`SUPER-1:0] currPCVec

    //to decode
    output F2D [`SUPER-1:0] f2d,
    
);
    reg PC;
    wire currPC;
    word [`SUPER-1:0] currPCVec;
    word [`SUPER-1:0] dataFromI$;
    [`SUPER-1:0] validFromI$;

    always_comb begin
        case (action)
            Stall: currPC = PC;
            Dequeue: currPC = predicted_nextPC;
            Redirect: currPC = redirectPC;
        endcase
        currPC = PC;

        //grab results from icache
        foreach (dataFromI$[i]) begin
            f2d[i].pc = PC + 4*i; //from old pc reg
            f2d[i].instr = dataFromI$[i];
            f2d[i].valid = validFromI$[i];

        //generate new PC + requests to icache
            currPCVec[i] = currPC + 4*i
        end

    end

    always_ff @(posedge clk) begin
        if (rst) begin
            PC <= 0;
        end else begin
            PC <= currPC;
        end
    end
endmodule