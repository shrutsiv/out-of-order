module phys_reg (
    input                                             clk, rst,
    input [`SUPER-1:0][$clog2(`PHYS_SZ)-1:0]   src1, src2, dst,
    input word [`SUPER-1:0]                            wr_data,
    input [`SUPER-1:0]                               wr_enable

    output word [`SUPER-1:0]                       data1, data2
);

    word [`PHYS_SZ-1:0] registers;
    word [`PHYS_SZ-1:0] registers_wire;

    always_comb begin
        registers_wire = registers;
        foreach (dst[i]) begin
            if (wr_enable[i]) begin
                registers_wire[dst[i]] = wr_data[i];
            end
        end
        foreach (src1[i]) begin
            data1[i] = registers_wire[src1[i]];
            data2[i] = registers_wire[src2[i]];
        end
    end


    always_ff @(posedge clk) begin
        if (rst) begin
            registers <= 0;
        end
        else begin
            registers <= registers_wire;
        end
    end
endmodule