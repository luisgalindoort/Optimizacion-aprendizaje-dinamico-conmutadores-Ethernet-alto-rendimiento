/*

Copyright (c) 2025 Carlos Megías Núñez.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * FPGA top-level module
 */
module fpga_core #
(
    // Cuckoo hashing table parameters
    parameter TABLE_DEPTH = 16384,
    parameter TABLE_COUNT = 4,
    parameter TABLE_KEY_WIDTH = 48,
    parameter TABLE_STORE_WIDTH = 16,
    parameter TABLE_LOOP_COUNT = 100,
    parameter TABLE_CONFIG_ENABLE = 1,
    parameter TABLE_REGISTER_STORE_STATE = 1,

    // Parameters for selecting insertion method
    // Select filter for initial insert step, 0: all tables; 1: prioritize free tables
    parameter TABLE_INSERTION_INITIAL_FILTER = 0,
    // Select strategy for initial insert step, 0: first table; 1: random; 2: round-robin; 3: minimum load
    parameter TABLE_INSERTION_INITIAL_STRATEGY = 2,
    // Select filter for reallocate step, 0: all tables; 1: prioritize free tables
    parameter TABLE_INSERTION_REALLOCATE_FILTER = 0,
    // Select strategy for reallocate step, 0: first table; 1: random; 2: round-robin; 3: minimum load
    parameter TABLE_INSERTION_REALLOCATE_STRATEGY = 2,

    // LFSR-related parameters for hash functions
    // Width of LFSR
    parameter TABLE_LFSR_WIDTH = 32,
    // LFSR polynomial
    parameter TABLE_LFSR_POLY = 128'hc8f698af1dca6d1fedB8832004c11db7,
    // LFSR state in
    parameter TABLE_LFSR_STATE_IN = 32'hffffffff,
    // LFSR configuration: "GALOIS", "FIBONACCI"
    parameter TABLE_LFSR_CONFIG = "GALOIS",
    // LFSR feed forward enable
    parameter TABLE_LFSR_FEED_FORWARD = 0,
    // Bit-reverse input and output
    parameter TABLE_LFSR_REVERSE = 1,
    // Implementation style: "AUTO", "LOOP", "REDUCTION"
    parameter TABLE_LFSR_STYLE = "AUTO",

    // AXIL parameters
    parameter AXIL_DATA_WIDTH = 32,
    parameter AXIL_ADDR_WIDTH = 16,
    parameter AXIL_STRB_WIDTH = (AXIL_DATA_WIDTH/8)
)
(
    /*
     * Clock
     * Synchronous reset
     */
    input  wire                                                  clk,
    input  wire                                                  rst,

    /*
     * AXI-Lite slave configuration interface
     */
    input  wire [AXIL_ADDR_WIDTH-1:0]                            s_axil_awaddr,
    input  wire [2:0]                                            s_axil_awprot,
    input  wire                                                  s_axil_awvalid,
    output wire                                                  s_axil_awready,
    input  wire [AXIL_DATA_WIDTH-1:0]                            s_axil_wdata,
    input  wire [AXIL_STRB_WIDTH-1:0]                            s_axil_wstrb,
    input  wire                                                  s_axil_wvalid,
    output wire                                                  s_axil_wready,
    output wire [1:0]                                            s_axil_bresp,
    output wire                                                  s_axil_bvalid,
    input  wire                                                  s_axil_bready,
    input  wire [AXIL_ADDR_WIDTH-1:0]                            s_axil_araddr,
    input  wire [2:0]                                            s_axil_arprot,
    input  wire                                                  s_axil_arvalid,
    output wire                                                  s_axil_arready,
    output wire [AXIL_DATA_WIDTH-1:0]                            s_axil_rdata,
    output wire [1:0]                                            s_axil_rresp,
    output wire                                                  s_axil_rvalid,
    input  wire                                                  s_axil_rready
);

localparam RB_BASE_ADDR = 0;
localparam RBB = RB_BASE_ADDR & {REG_ADDR_WIDTH{1'b1}}; 

localparam REG_ADDR_WIDTH = AXIL_DATA_WIDTH;
localparam REG_DATA_WIDTH = AXIL_DATA_WIDTH;
localparam REG_STRB_WIDTH = AXIL_STRB_WIDTH;

// control register wires
wire [REG_ADDR_WIDTH-1:0]  ctrl_reg_wr_addr;
wire [REG_DATA_WIDTH-1:0]  ctrl_reg_wr_data;
wire [REG_STRB_WIDTH-1:0]  ctrl_reg_wr_strb;
wire                       ctrl_reg_wr_en;
wire                       ctrl_reg_wr_wait;
wire                       ctrl_reg_wr_ack;
wire [REG_ADDR_WIDTH-1:0]  ctrl_reg_rd_addr;
wire                       ctrl_reg_rd_en;
wire [REG_DATA_WIDTH-1:0]  ctrl_reg_rd_data;
wire                       ctrl_reg_rd_wait;
wire                       ctrl_reg_rd_ack;

axil_reg_if #(
    .DATA_WIDTH(REG_DATA_WIDTH),
    .ADDR_WIDTH(REG_ADDR_WIDTH),
    .STRB_WIDTH(REG_STRB_WIDTH),
    .TIMEOUT(40)
)
axil_reg_if_inst (
    .clk(clk),
    .rst(rst),

    /*
     * AXI-Lite slave interface
     */
    .s_axil_awaddr(s_axil_awaddr),
    .s_axil_awprot(s_axil_awprot),
    .s_axil_awvalid(s_axil_awvalid),
    .s_axil_awready(s_axil_awready),
    .s_axil_wdata(s_axil_wdata),
    .s_axil_wstrb(s_axil_wstrb),
    .s_axil_wvalid(s_axil_wvalid),
    .s_axil_wready(s_axil_wready),
    .s_axil_bresp(s_axil_bresp),
    .s_axil_bvalid(s_axil_bvalid),
    .s_axil_bready(s_axil_bready),
    .s_axil_araddr(s_axil_araddr),
    .s_axil_arprot(s_axil_arprot),
    .s_axil_arvalid(s_axil_arvalid),
    .s_axil_arready(s_axil_arready),
    .s_axil_rdata(s_axil_rdata),
    .s_axil_rresp(s_axil_rresp),
    .s_axil_rvalid(s_axil_rvalid),
    .s_axil_rready(s_axil_rready),

    /*
     * Register interface
     */
    .reg_wr_addr(ctrl_reg_wr_addr),
    .reg_wr_data(ctrl_reg_wr_data),
    .reg_wr_strb(ctrl_reg_wr_strb),
    .reg_wr_en(ctrl_reg_wr_en),
    .reg_wr_wait(ctrl_reg_wr_wait),
    .reg_wr_ack(ctrl_reg_wr_ack),
    .reg_rd_addr(ctrl_reg_rd_addr),
    .reg_rd_en(ctrl_reg_rd_en),
    .reg_rd_data(ctrl_reg_rd_data),
    .reg_rd_wait(ctrl_reg_rd_wait),
    .reg_rd_ack(ctrl_reg_rd_ack)
);


reg ctrl_reg_wr_ack_reg = 1'b0;
reg [AXIL_DATA_WIDTH-1:0] ctrl_reg_rd_data_reg = {AXIL_DATA_WIDTH{1'b0}};
reg ctrl_reg_rd_ack_reg = 1'b0;

assign ctrl_reg_wr_wait = 1'b0;
assign ctrl_reg_wr_ack = ctrl_reg_wr_ack_reg;
assign ctrl_reg_rd_data = ctrl_reg_rd_data_reg;
assign ctrl_reg_rd_wait = 1'b0;
assign ctrl_reg_rd_ack = ctrl_reg_rd_ack_reg;

// registers for write request generation
reg  [REG_DATA_WIDTH-1:0] modifier_reg = 0;
reg  write_valid_reg = 1'b0;
reg  [TABLE_KEY_WIDTH-1:0] key_random_reg = 48'h1122811C9DC5;
wire [TABLE_KEY_WIDTH-1:0] key_random;

// wires for writing in the Cuckoo hashing table
localparam WRITE_WIDTH = TABLE_STORE_WIDTH + TABLE_KEY_WIDTH;

wire [WRITE_WIDTH-1:0]              write_request_data = {{TABLE_STORE_WIDTH{1'b0}}, key_random_reg};
wire                                write_request_active = 1'b1;
wire                                write_request_valid = write_valid_reg;
wire                                write_request_ready;

wire [$clog2(TABLE_LOOP_COUNT+1)-1:0] write_response_iteration;
wire                                write_response_error;
wire                                write_response_valid;

// utilization counter wire from address table
wire [$clog2(TABLE_DEPTH):0] utilization_table;
wire [($clog2(TABLE_DEPTH/TABLE_COUNT)+1)*TABLE_COUNT-1:0] utilization_local_tables;
wire [REG_DATA_WIDTH-1:0] max_loop_hit_counter_reg;

// configure depth mask for each parallel table (maximum is TABLE_DEPTH/TABLE_COUNT-1)
reg [$clog2(TABLE_DEPTH/TABLE_COUNT)-1:0] config_depth_mask_table = TABLE_DEPTH/TABLE_COUNT-1;
// configure number of parallel tables (maximum is TABLE_COUNT)
reg [$clog2(TABLE_COUNT):0] config_table_count_table = TABLE_COUNT;
// configure maximum load factor (in number of entries) for the table (maximum is DEPTH)
reg [$clog2(TABLE_DEPTH):0] config_max_util_table = TABLE_DEPTH;

// clear registers
reg clear_table = 1'b0;

// configure other value for TABLE_LOOP_COUNT (taking into account that the width is restricted to $clog2(TABLE_LOOP_COUNT+1))
reg [$clog2(TABLE_LOOP_COUNT+1)-1:0] config_max_loop_count_reg = TABLE_LOOP_COUNT;

// number of iterations of last written element once the utilization of the table has reached the config_max_util_table value
reg [$clog2(TABLE_LOOP_COUNT+1)-1:0] config_last_count_iterations_reg = 0;
reg config_last_error_reg = 1'b0;
reg config_last_capture_reg = 1'b0;

always @(posedge clk) begin
    ctrl_reg_wr_ack_reg <= 1'b0;
    ctrl_reg_rd_data_reg <= {REG_DATA_WIDTH{1'b0}};
    ctrl_reg_rd_ack_reg <= 1'b0;
    
    clear_table <= 1'b0;

    if (TABLE_CONFIG_ENABLE) begin
        // capture number of iterations for last written element once the utilization of the table has reached the config_max_util_table value or an error has been produced because of the collision limit has been hit
        if (config_last_capture_reg == 1'b0 && write_response_valid && (config_max_util_table == (utilization_table + 1) || write_response_error)) begin
            config_last_count_iterations_reg <= write_response_iteration;
            config_last_error_reg <= write_response_error;
            config_last_capture_reg <= 1'b1;
            // block writing more entries to capture utilization of tables when write_response_error is hit (to not attempting filling the table to config_max_util_table)
            write_valid_reg <= 1'b0;
        end
    end

    // update modifier register for random keys
    modifier_reg <= modifier_reg + (write_request_valid && write_request_ready);

    // Write
    if (ctrl_reg_wr_en && !ctrl_reg_wr_ack_reg) begin
        // write operation
        ctrl_reg_wr_ack_reg <= 1'b1;

        if ({ctrl_reg_wr_addr >> 2, 2'b00} < RBB+8'h20) begin
            case ({ctrl_reg_wr_addr >> 2, 2'b00})
                // Port control
                RBB+8'h00: begin 
                    clear_table <= 1'b1;                              // Cuckoo hashing table: clear table
                    config_last_capture_reg <= 1'b0; // Cuckoo hashing table: reset capture register for number of iterations of last written element once the utilization of the table has reached the config_max_util_table value
                end
                default: ctrl_reg_wr_ack_reg <= 1'b0;
            endcase

        end else if (TABLE_CONFIG_ENABLE && {ctrl_reg_wr_addr >> 2, 2'b00} < RBB+8'h80) begin
            case ({ctrl_reg_wr_addr >> 2, 2'b00})
                RBB+8'h60: config_depth_mask_table <= ctrl_reg_wr_data[$clog2(TABLE_DEPTH/TABLE_COUNT)-1:0];     // Cuckoo hashing table: configure depth mask for each parallel table
                RBB+8'h64: config_table_count_table <= ctrl_reg_wr_data[$clog2(TABLE_COUNT):0];                  // Cuckoo hashing table: configure table count
                RBB+8'h68: config_max_util_table <= ctrl_reg_wr_data[$clog2(TABLE_DEPTH):0];                     // Cuckoo hashing table: configure maximum global utilization
                RBB+8'h6C: config_max_loop_count_reg <= ctrl_reg_wr_data;                                        // Cuckoo hashing table: configure iterations limit (replaces TABLE_LOOP_COUNT, and must be equal or lower than it)
                RBB+8'h70: config_last_count_iterations_reg <= ctrl_reg_wr_data[$clog2(TABLE_LOOP_COUNT+1)-1:0]; // Cuckoo hashing table: number of iterations for last written element once the utilization of the table has reached the config_max_util_table value
                default: ctrl_reg_wr_ack_reg <= 1'b0;
            endcase

        // write request generation registers
        end else if ({ctrl_reg_wr_addr >> 2, 2'b00} < RBB+8'h90) begin
            case ({ctrl_reg_wr_addr >> 2, 2'b00})
                RBB+8'h80: modifier_reg <= ctrl_reg_wr_data;        // Seed for random key generation
                RBB+8'h84: write_valid_reg <= ctrl_reg_wr_data[0];  // Bit for enabling/disabling write requests to the hash table
                default: ctrl_reg_wr_ack_reg <= 1'b0;
            endcase
        end else begin
            ctrl_reg_wr_ack_reg <= 1'b0;
        end
    end

    // Read
    if (ctrl_reg_rd_en && !ctrl_reg_rd_ack_reg) begin
        ctrl_reg_rd_ack_reg <= 1'b1;
        // hash table registers
        if ({ctrl_reg_rd_addr >> 2, 2'b00} < RBB+8'h4C) begin
            case ({ctrl_reg_rd_addr >> 2, 2'b00})
                // Port
                RBB+8'h00: ctrl_reg_rd_data_reg <= 32'h00000000;                   // Type of module
                RBB+8'h04: ctrl_reg_rd_data_reg <= 32'h00000001;                   // Version of module

                RBB+8'h10: ctrl_reg_rd_data_reg <= TABLE_DEPTH;                    // Cuckoo hashing table depth
                RBB+8'h14: ctrl_reg_rd_data_reg <= TABLE_COUNT;                    // Cuckoo hashing table number of tables
                RBB+8'h18: ctrl_reg_rd_data_reg <= TABLE_KEY_WIDTH;                // Cuckoo hashing table key width in bits
                RBB+8'h1C: ctrl_reg_rd_data_reg <= TABLE_STORE_WIDTH;              // Cuckoo hashing table store/value width in bits
                RBB+8'h20: ctrl_reg_rd_data_reg <= TABLE_LOOP_COUNT;               // Cuckoo hashing table maximum number of allowed iterations
                RBB+8'h24: ctrl_reg_rd_data_reg <= TABLE_CONFIG_ENABLE;            // Cuckoo hashing table configuration mode enabled
                RBB+8'h28: ctrl_reg_rd_data_reg <= TABLE_REGISTER_STORE_STATE;     // Cuckoo hashing table additional register store state enabled (help timing closure)
                
                RBB+8'h2C: ctrl_reg_rd_data_reg <= TABLE_INSERTION_INITIAL_FILTER;      // Cuckoo hashing table insertion method configuration
                RBB+8'h30: ctrl_reg_rd_data_reg <= TABLE_INSERTION_INITIAL_STRATEGY;    // Cuckoo hashing table insertion method configuration
                RBB+8'h34: ctrl_reg_rd_data_reg <= TABLE_INSERTION_REALLOCATE_FILTER;   // Cuckoo hashing table insertion method configuration
                RBB+8'h38: ctrl_reg_rd_data_reg <= TABLE_INSERTION_REALLOCATE_STRATEGY; // Cuckoo hashing table insertion method configuration

                RBB+8'h3C: ctrl_reg_rd_data_reg <= max_loop_hit_counter_reg;       // Cuckoo hashing table: Counts the number of times TABLE_LOOP_COUNT has been hit when inserting new elements
                RBB+8'h40: ctrl_reg_rd_data_reg <= utilization_table;              // Cuckoo hashing table current global utilization
                RBB+8'h44: ctrl_reg_rd_data_reg <= utilization_local_tables[0*($clog2(TABLE_DEPTH/TABLE_COUNT)+1) +: ($clog2(TABLE_DEPTH/TABLE_COUNT)+1)]; // Cuckoo hashing table current local utilization of T0
                RBB+8'h48: ctrl_reg_rd_data_reg <= utilization_local_tables[1*($clog2(TABLE_DEPTH/TABLE_COUNT)+1) +: ($clog2(TABLE_DEPTH/TABLE_COUNT)+1)]; // Cuckoo hashing table current local utilization of T1
                default: ctrl_reg_rd_ack_reg <= 1'b0;
            endcase
        
        end else if (TABLE_COUNT > 2 && {ctrl_reg_rd_addr >> 2, 2'b00} == RBB+8'h4C) begin
            ctrl_reg_rd_data_reg <= utilization_local_tables[2*($clog2(TABLE_DEPTH/TABLE_COUNT)+1) +: ($clog2(TABLE_DEPTH/TABLE_COUNT)+1)];                // Cuckoo hashing table current local utilization of parallel table T2
        end else if (TABLE_COUNT > 3 && {ctrl_reg_rd_addr >> 2, 2'b00} == RBB+8'h50) begin
            ctrl_reg_rd_data_reg <= utilization_local_tables[3*($clog2(TABLE_DEPTH/TABLE_COUNT)+1) +: ($clog2(TABLE_DEPTH/TABLE_COUNT)+1)];                // Cuckoo hashing table current local utilization of parallel table T3
        end else if (TABLE_COUNT > 4 && {ctrl_reg_rd_addr >> 2, 2'b00} == RBB+8'h54) begin
            ctrl_reg_rd_data_reg <= utilization_local_tables[4*($clog2(TABLE_DEPTH/TABLE_COUNT)+1) +: ($clog2(TABLE_DEPTH/TABLE_COUNT)+1)];                // Cuckoo hashing table current local utilization of parallel table T4
        end else if (TABLE_COUNT > 5 && {ctrl_reg_rd_addr >> 2, 2'b00} == RBB+8'h58) begin
            ctrl_reg_rd_data_reg <= utilization_local_tables[5*($clog2(TABLE_DEPTH/TABLE_COUNT)+1) +: ($clog2(TABLE_DEPTH/TABLE_COUNT)+1)];                // Cuckoo hashing table current local utilization of parallel table T5

        end else if (TABLE_CONFIG_ENABLE) begin
            case ({ctrl_reg_rd_addr >> 2, 2'b00})
                RBB+8'h60: ctrl_reg_rd_data_reg <= config_depth_mask_table;                        // Cuckoo hashing table: configured depth mask for each parallel table
                RBB+8'h64: ctrl_reg_rd_data_reg <= config_table_count_table;                       // Cuckoo hashing table: configured table count
                RBB+8'h68: ctrl_reg_rd_data_reg <= config_max_util_table;                          // Cuckoo hashing table: configured maximum global utilization
                RBB+8'h6C: ctrl_reg_rd_data_reg <= config_max_loop_count_reg;                      // Cuckoo hashing table: configured iterations limit (replaces TABLE_LOOP_COUNT, and must be equal or lower than it)
                RBB+8'h70: ctrl_reg_rd_data_reg <= config_last_count_iterations_reg;               // Cuckoo hashing table: number of iterations for last written element once the utilization of the table has reached the config_max_util_table value
                RBB+8'h74: ctrl_reg_rd_data_reg <= config_last_error_reg;                          // Cuckoo hashing table: error flag for last written element
                RBB+8'h78: ctrl_reg_rd_data_reg <= config_last_capture_reg;                        // Cuckoo hashing table: capture flag for last written element
                default: ctrl_reg_rd_ack_reg <= 1'b0;
            endcase

        end else begin
            ctrl_reg_rd_ack_reg <= 1'b0;
        end
    end

    key_random_reg <= key_random;

    if (rst) begin
        ctrl_reg_wr_ack_reg <= 1'b0;
        ctrl_reg_rd_ack_reg <= 1'b0;

        config_depth_mask_table <= TABLE_DEPTH/TABLE_COUNT-1;
        config_table_count_table <= TABLE_COUNT;
        config_max_util_table <= TABLE_DEPTH;
        config_max_loop_count_reg <= TABLE_LOOP_COUNT;

        config_last_count_iterations_reg <= 0;
        config_last_error_reg <= 1'b0;
        config_last_capture_reg <= 1'b0;

        clear_table <= 1'b0;

        modifier_reg <= 0;
        write_valid_reg <= 1'b0;
        key_random_reg <= 48'h1122811C9DC5;
    end
end

assign key_random = ((key_random_reg << 5) + key_random_reg) + modifier_reg;

// instantiate of Cuckoo Hashing table
hash_table #(
    .DEPTH(TABLE_DEPTH),
    .TABLE_COUNT(TABLE_COUNT),
    .STORE_WIDTH(TABLE_STORE_WIDTH),
    .KEY_WIDTH(TABLE_KEY_WIDTH),
    .LOOP_COUNT(TABLE_LOOP_COUNT),
    .MAX_LOOP_HIT_COUNTER_WIDTH(REG_DATA_WIDTH),
    .CONFIG_ENABLE(TABLE_CONFIG_ENABLE),
    .REGISTER_STORE_STATE(TABLE_REGISTER_STORE_STATE),
    .INSERTION_INITIAL_FILTER(TABLE_INSERTION_INITIAL_FILTER),
    .INSERTION_INITIAL_STRATEGY(TABLE_INSERTION_INITIAL_STRATEGY),
    .INSERTION_REALLOCATE_FILTER(TABLE_INSERTION_REALLOCATE_FILTER),
    .INSERTION_REALLOCATE_STRATEGY(TABLE_INSERTION_REALLOCATE_STRATEGY),
    .ID_WIDTH(1),
    .LFSR_WIDTH(TABLE_LFSR_WIDTH),
    .LFSR_POLY(TABLE_LFSR_POLY),
    .LFSR_STATE_IN(TABLE_LFSR_STATE_IN),
    .LFSR_CONFIG(TABLE_LFSR_CONFIG),
    .LFSR_FEED_FORWARD(TABLE_LFSR_FEED_FORWARD),
    .LFSR_REVERSE(TABLE_LFSR_REVERSE),
    .LFSR_STYLE(TABLE_LFSR_STYLE)
)
cuckoo_hashing_table_inst (
    .clk(clk),
    .rst(rst),

    /*
    * Query interface
    */
    .query_request_data(0),
    .query_request_id(0),
    .query_request_valid(1'b0),
    .query_request_ready(),

    .query_response_data(),
    .query_response_id(),
    .query_response_valid(),
    .query_response_ready(1'b1),
    .query_response_error(),
    .query_response_table(),

    /*
    * Write interface
    */
    .write_request_data(write_request_data),
    .write_request_active(write_request_active),
    .write_request_valid(write_request_valid),
    .write_request_ready(write_request_ready),

    .write_response_error(write_response_error),
    .write_response_iteration(write_response_iteration),
    .write_response_valid(write_response_valid),

    /*
     * Status
     */
    .utilization_table(utilization_table),
    .utilization_local_tables(utilization_local_tables),
    .max_loop_hit_counter(max_loop_hit_counter_reg),

    /*
     * Dynamic depth and table count configuration
     */
    .config_depth_mask(config_depth_mask_table),
    .config_table_count(config_table_count_table),
    .config_max_util(config_max_util_table),
    .config_max_loop_count(config_max_loop_count_reg),

    /*
     * Clear signal
     */
    .clear_table(clear_table)
);

endmodule

`resetall
