//generic parameters
`define SUPER                                            4;
`define MEM_DELAY                                       50;
`define ACTIVE_REQS                               `SUPER+2;
`define PREFETCH                                         2;

//size macros
`define PHYS_SZ                                         64;
`define SSIT_SZ                                        256;
`define LFST_SZ                                        128;
`define BTB_SZ                                          32;
`define BTB_WAYS                                         4;
`define ALU_NUM                           (`SUPER + 1) / 2;
`define ADD_NUM                      `SUPER - `ALU_NUM - 1;
`define RS_SZ                        3*ALU_NUM+2*ADD_NUM+1;
`define ROB_SZ                                          32;
`define LSQ_SZ                                          16;
`define MEM_BYTES                                  1 << 20; //1 MB
`define MEM_WORDS                           `MEM_BYTES / 4;
`define MEM_LINES                  `MEM_WORDS / `LINE_SIZE;
`define LINE_SIZE                                        8;
`define NUM_LINES                                       64;
`define BLK_BYT_OFFSET                $clog2(`LINE_SIZE)+2;

//range macros
`define BTB_IDX_RANGE                  $clog2(`BTB_SZ)+1:2;
`define BTB_TAG_RANGE                 31:$clog2(`BTB_SZ)+2;
`define OPCODE_RANGE                                   2:0;
`define FUNC_RANGE                                     6:3;
`define DST_RANGE                                     11:7;
`define SRC1_RANGE                                   16:12;
`define SRC2_RANGE                                   20:17;
`define IMM15_RANGE                                  31:17;
`define IMM20_RANGE                                  31:12;
`define SSIT_IDX_RANGE                $clog2(`SSIT_SZ)+1:2;
`define MEM_IDX_RG    $clog2(`MEM_LINES)-1:`BLK_BYT_OFFSET;
`define CACHE_BLK_RG                $clog2(`LINE_SIZE)+1:2;
`define CACHE_IDX_RG  $clog2(`NUM_LINES)-1:`BLK_BYT_OFFSET;
`define CACHE_TAG_RG 31:$clog2(`NUM_LINES)+`BLK_BYT_OFFSET;

typedef logic [31:0]                                  word;

//pipeline register structs
typedef struct packed {
    word pc,
    word instr,
    logic valid,
} F2D;

typedef struct packed {
    word pc;
    word src1;
    word src2;
    logic src1_ready;
    logic src2_ready;
    word imm;
    logic [$clog2(`PHYS_SZ)-1:0] dst;
    logic [4:0] dst_log;
    logic wr_en;
    logic [3:0] op;
    logic [2:0] func;
    logic valid;
    logic nextPC;
    logic [31:2] inum; //find a better one lol, right now it's just the PC
} D2I;


typedef struct packed {
    wire valid;
    word pc;
    word src1;
    word src2;
    word imm;
    logic [3:0] op;
    logic [2:0] func;
    logic [$clog2(`RS_SZ)-1:0] rs;
} I2E;

typedef struct packed {
    logic valid;
    word pc;
    word data;
    word addr;
    logic [2:0] op;
    logic [3:0] func;
} E2M;

//buffer/table entry structs
typedef struct packed {
    logic [1:0] counter;
    logic [$clog2(`LFST_SZ)-1:0] ssid;
} SSIT_entry;

typedef struct packed {
    logic valid;
    logic [31:2] inum;
} LSFT_entry;

typedef struct packed {
    logic commit;
    logic ready;
    word addr; //tag?
    word data;
    word pc;
    word inum; //to enforce dependence
    logic [$clog2(`LSQ_SZ)-1:0] age;
    logic occupied;
} sq_line;

typedef struct packed {
    logic commit;
    logic datastate; //0, nothing ready, 1 addr ready, 2, need to search from memory, 3, sent to memory
    word addr; //tag?
    word data;
    word pc; //to enforce dependence
    word inum;
    logic [$clog2(`LSQ_SZ)-1:0] age;
    logic occupied;
    logic raw;
    logic [$clog2(`LSQ_SZ)-1:0] dependent_store;
    logic [$clog2(`RS_SZ)-1:0] rs;
} lq_line;

typedef struct packed {
   logic [2:0] instr_type;
   logic [$clog(`LSQ_SZ)-1:0] lsq;
   logic [4:0] dst_log;
   word nextPC;
   word pc;
   logic [$clog(`PHYS_SZ)-1:0] dst;
   logic wr_en;
   word value; 
   logic ready;
   logic occupied;
   logic flush;
   logic redirectPC;
} rob_line;

typedef struct packed {
   word                              pc;
   word                            src1;
   word                            src2;
   word                             imm;
   logic                     src1_ready;
   logic                     src2_ready;
   logic [3:0]                       op;
   logic [2:0]                     func;
   logic                           busy;
   logic                           done;
   logic [$clog2(`ROB_SZ)-1:0] rob_dest;
   logic [$clog2(`LSQ_SZ)-1:0]      lsq;
   logic [$clog2(`RS_SZ)-1:0]  read_dep;
   logic [1:0]              read_dep_op; //encoding - 01 op1, 02 op2, 03 both, 0 no valid dependence
} station;

typedef struct packed {
    word addr;
    logic [`LINE_SIZE*32-1:0] data;
    logic is_i;
    logic store;
    logic writeback;
    logic [$clog2(`MEM_DELAY)-1:0] delay;
    logic queued;
    logic ready;
} reqline;

typedef struct packed {
    logic [30-$clog2(`BTB_SZ)-1:0] tag;
    logic [1:0] counter;
    logic [31:0] redirect;
} branch_predictor_line;

typedef struct packed {
    logic valid;
    logic dirty;
    logic [`LINE_SIZE*32-1:0] data;
    logic [$clog2(`NUM_LINES)-`BLK_BYT_OFFSET:0] tag;
} cacheline;

typedef struct packed {
    word addr;
    logic [`LINE_SIZE*32-1:0] data;
    logic pending;
} wb_request;

//enums
typedef enum bit[1:0] {
    Stall, 
    Dequeue, 
    Redirect
} FetchAction;

typedef enum {
    Branch,
    Jump,
    Alu,
    AluImm,
    Mem,
    Lui
} opcode;

typedef enum {
    Beq,
    Ble,
    Beqz
} branch_func;

typedef enum {
    Jal,
    Jalr,
} jump_func;

typedef enum {
    And,
    Or,
    Sll,
    Sra,
    Srl,
    Slt,
    Sltu,
    Sub,
    Mulh,
    Mull
} alu_func;

typedef enum {
    Load,
    Store
} mem_func;












