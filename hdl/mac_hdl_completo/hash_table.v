/*

Copyright (c) 2025 Carlos Megías Núñez

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

`resetall
`timescale 1ns / 1ps
`default_nettype none

module hash_table #
(   
    // Hash table configuration parameters
    // Number of entries (aggregated) of the hash table
    parameter DEPTH = 16384,
    // Number of tables used in the Cuckoo Hashing
    parameter TABLE_COUNT = 4,
    // Width of route value store part in bits
    parameter STORE_WIDTH = 16,
    // Width of key for hashing in bits
    parameter KEY_WIDTH = 48,
    // Maximum loop count
    parameter LOOP_COUNT = 100,
    // Width of maximum loop hit counter
    parameter MAX_LOOP_HIT_COUNTER_WIDTH = 32,
    // Enable configuration of table properties during execution time: DEPTH and TABLE_COUNT
    parameter CONFIG_ENABLE = 0,
    // Enable to set additional registers for help timing closure on write side of hash table (at cost of more latency)
    parameter REGISTER_STORE_STATE = 2,

    // Parameters for selecting insertion method
    // Select filter for initial insert step, 0: all tables; 1: prioritize free tables
    parameter INSERTION_INITIAL_FILTER = 0,
    // Select strategy for initial insert step, 0: first table; 1: random; 2: round-robin; 3: minimum load
    parameter INSERTION_INITIAL_STRATEGY = 0,
    // Select filter for reallocate step, 0: all tables; 1: prioritize free tables
    parameter INSERTION_REALLOCATE_FILTER = 0,
    // Select strategy for reallocate step, 0: first table; 1: random; 2: round-robin; 3: minimum load
    parameter INSERTION_REALLOCATE_STRATEGY = 0,

    // Width of ID signal for origin of transaction and sync purposes in bits
    parameter ID_WIDTH = 1,

    // LFSR-related parameters
    // Width of LFSR
    parameter LFSR_WIDTH = 32,
    // LFSR polynomial
    // parameter LFSR_POLY = 128'h66715bad1dfa979bedB8832004c11db7,
    parameter LFSR_POLY = 128'hc8f698af1dca6d1fedB8832004c11db7,
    // LFSR state in
    parameter LFSR_STATE_IN = 32'hffffffff,
    // LFSR configuration: "GALOIS", "FIBONACCI"
    parameter LFSR_CONFIG = "GALOIS",
    // LFSR feed forward enable
    parameter LFSR_FEED_FORWARD = 0,
    // Bit-reverse input and output
    parameter LFSR_REVERSE = 1,
    // Implementation style: "AUTO", "LOOP", "REDUCTION"
    parameter LFSR_STYLE = "AUTO"
)
(
    input  wire                                                 clk,
    input  wire                                                 rst,

    /*
     * Hash table query
     */
    input  wire [KEY_WIDTH-1:0]                                 query_request_data,
    input  wire [ID_WIDTH-1:0]                                  query_request_id,
    input  wire                                                 query_request_valid,
    output wire                                                 query_request_ready,

    output wire [STORE_WIDTH-1:0]                               query_response_data,
    output wire [ID_WIDTH-1:0]                                  query_response_id,
    output wire                                                 query_response_valid,
    input  wire                                                 query_response_ready,
    output wire                                                 query_response_error,
    output wire [$clog2(TABLE_COUNT)-1:0]                       query_response_table,

    /*
     * Hash table write
     */
    input  wire [KEY_WIDTH+STORE_WIDTH-1:0]                     write_request_data,
    input  wire                                                 write_request_active,
    input  wire                                                 write_request_valid,
    output wire                                                 write_request_ready,

    output wire                                                 write_response_error,
    output wire [LOOP_WIDTH-1:0]                                write_response_iteration,
    output wire                                                 write_response_valid,

    /*
     * Status
     */
    output wire [$clog2(DEPTH):0]                               utilization_table,
    output wire [($clog2(DEPTH/TABLE_COUNT)+1)*TABLE_COUNT-1:0] utilization_local_tables,
    output wire [MAX_LOOP_HIT_COUNTER_WIDTH-1:0]                max_loop_hit_counter,

    /*
     * Dynamic depth and table count configuration
     */
    input  wire [$clog2(DEPTH/TABLE_COUNT)-1:0]                 config_depth_mask,
    input  wire [$clog2(TABLE_COUNT):0]                         config_table_count,
    input  wire [$clog2(DEPTH):0]                               config_max_util,
    input  wire [LOOP_WIDTH-1:0]                                config_max_loop_count,

    /*
     * Clear signal
     */
    input  wire                                                 clear_table
);

// Width of counter of iterations in bits (do not touch)
localparam LOOP_WIDTH = LOOP_COUNT > 1 ? $clog2(LOOP_COUNT+1) : 1;

// Width of tables count used in the Cuckoo Hashing in bits
localparam TABLE_WIDTH = $clog2(TABLE_COUNT);

// Additional hash table parameters
localparam ADDR_WIDTH = $clog2(DEPTH/TABLE_COUNT);
localparam VALUE_WIDTH = STORE_WIDTH + 1;
localparam ENTRY_WIDTH = KEY_WIDTH + VALUE_WIDTH;

// Width of hash table words in bits
localparam WRITE_WIDTH = KEY_WIDTH + STORE_WIDTH;

localparam ACTIVE_OFFSET   = WRITE_WIDTH;

// Parameter for width of global utilization counter
localparam UTILIZATION_WIDTH = $clog2(DEPTH) + 1;
// Parameter for width of local utilization counters
localparam UTILIZATION_LOCAL_WIDTH = ADDR_WIDTH + 1;

localparam RANDOM_BITS = $clog2(TABLE_COUNT) + 4;

function [$clog2(TABLE_COUNT)-1:0] select_first_table(input [TABLE_COUNT-1:0] filtered_tables);
integer i;
begin
    select_first_table = 0;
    for (i = TABLE_COUNT - 1; i >= 0; i = i - 1) begin
        if (filtered_tables[i] == 1'b1) begin
            select_first_table = i;
        end
    end
end
endfunction

function [$clog2(TABLE_COUNT)-1:0] select_random_table(input [TABLE_COUNT-1:0] filtered_tables, input [$clog2(TABLE_COUNT)-1:0] random_table);
integer i, select_end;
begin
    // assume that random_table is already moduled
    select_random_table = random_table;
    select_end = 0;
    for (i = 0; i < TABLE_COUNT; i = i + 1) begin
        if (filtered_tables[(i+random_table)%TABLE_COUNT] == 1'b1 && select_end == 0) begin
            select_random_table = (i+random_table)%TABLE_COUNT;
            select_end = 1;
        end
    end
end
endfunction

function [$clog2(TABLE_COUNT)-1:0] select_round_robin_table(input [TABLE_COUNT-1:0] filtered_tables, input [$clog2(TABLE_COUNT)-1:0] last_table);
integer i, select_end;
begin
    select_round_robin_table = (1+last_table)%TABLE_COUNT;
    select_end = 0;
    for (i = 1; i < TABLE_COUNT + 1; i = i + 1) begin
        if (filtered_tables[(i+last_table)%TABLE_COUNT] == 1'b1 && select_end == 0) begin
            select_round_robin_table = (i+last_table)%TABLE_COUNT;
            select_end = 1;
        end
    end
end
endfunction

function [$clog2(TABLE_COUNT)-1:0] select_min_load_table(input [TABLE_COUNT-1:0] filtered_tables);
integer i, min_load_value;
begin
    select_min_load_table = 0;
    min_load_value = 2**UTILIZATION_LOCAL_WIDTH-1;
    for (i = 0; i < TABLE_COUNT; i = i + 1) begin
        if (filtered_tables[i] == 1'b1 && utilization_local_tables[i*UTILIZATION_LOCAL_WIDTH +: UTILIZATION_LOCAL_WIDTH] <= min_load_value) begin
            select_min_load_table = i;
            min_load_value = utilization_local_tables[i*UTILIZATION_LOCAL_WIDTH +: UTILIZATION_LOCAL_WIDTH];
        end
    end
end
endfunction

// check configuration
initial begin
    if (TABLE_COUNT <= 1) begin
        $error("Error: TABLE_COUNT requires being at least equal to 2 (instance %m)");
        $finish;
    end

    if (ADDR_WIDTH > LFSR_WIDTH) begin
        $error("Error: ADDR_WIDTH requires being shorter than or equal to LFSR_WIDTH (instance %m)");
        $finish;
    end

    if (INSERTION_REALLOCATE_FILTER == 0 && INSERTION_REALLOCATE_STRATEGY != 2) begin
        $error("Error: Set insertion method using all tables as reallocate filter and a reallocate strategy different from round-robin (instance %m)");
        $finish;
    end

    if (INSERTION_INITIAL_FILTER > 1) begin
        $error("Error: INSERTION_INITIAL_FILTER requires being lower or equal to 1 (instance %m)");
        $finish;
    end

    if (INSERTION_REALLOCATE_FILTER > 1) begin
        $error("Error: INSERTION_REALLOCATE_FILTER requires being lower or equal to 1 (instance %m)");
        $finish;
    end

    if (INSERTION_INITIAL_FILTER == 0 && INSERTION_REALLOCATE_FILTER == 1) begin
        $error("Error: INSERTION_REALLOCATE_FILTER set requires INSERTION_INITIAL_FILTER set (instance %m)");
        $finish;
    end

    if (INSERTION_INITIAL_STRATEGY > 3) begin
        $error("Error: INSERTION_INITIAL_STRATEGY requires being lower or equal to 3 (instance %m)");
        $finish;
    end

    if (INSERTION_REALLOCATE_STRATEGY > 3) begin
        $error("Error: INSERTION_REALLOCATE_STRATEGY requires being lower or equal to 3 (instance %m)");
        $finish;
    end
end

// Utilization of table: computation of overall utilization and current status based on threshold input signals
reg  [UTILIZATION_WIDTH-1:0] utilization_counter_reg = {UTILIZATION_WIDTH{1'b0}};
reg  [UTILIZATION_WIDTH-1:0] utilization_counter_next;
wire [UTILIZATION_LOCAL_WIDTH*TABLE_COUNT-1:0] utilization_counter_wire;

assign utilization_local_tables = utilization_counter_wire;

// Table states based on its current utilization
localparam [0:0]
    STATE_NORMAL = 1'd0,
    STATE_HIGH = 1'd1;

// finite state machine
reg state_utilization_reg = STATE_NORMAL, state_utilization_next;

integer t;
always @* begin
    utilization_counter_next = 0;

    state_utilization_next = state_utilization_reg;

    for (t = 0; t < TABLE_COUNT; t = t + 1) begin
        utilization_counter_next = utilization_counter_next + utilization_counter_wire[t*UTILIZATION_LOCAL_WIDTH +: UTILIZATION_LOCAL_WIDTH];
    end

    case (state_utilization_reg)
        STATE_NORMAL: begin
            if (utilization_counter_reg < DEPTH/2) begin
                state_utilization_next = STATE_NORMAL;
            end else begin
                state_utilization_next = STATE_HIGH;
            end
        end

        STATE_HIGH: begin
            if (utilization_counter_reg >= DEPTH/2) begin
                state_utilization_next = STATE_HIGH;
            end else begin
                state_utilization_next = STATE_NORMAL;
            end
        end
    endcase
end

always @(posedge clk) begin
    utilization_counter_reg <= utilization_counter_next;

    state_utilization_reg <= state_utilization_next;

    if (rst) begin
        utilization_counter_reg <= {UTILIZATION_WIDTH{1'b0}};
    end
end

assign utilization_table = utilization_counter_reg;

// Read side of hash table
// ready for pipeline propagation
wire query_response_ready_stage_1;
wire query_response_ready_stage_2;
wire query_response_ready_stage_3;
wire query_response_ready_stage_4;

// prepare address based on hash obtained and enable signal
reg rd_enable_reg = 1'b0;
reg [ID_WIDTH-1:0] id_hash_reg;

// perform reading from hash table
reg rd_data_valid_reg = 1'b0;
reg [ID_WIDTH-1:0] id_rd_reg;

// store, try to force output register for BRAMs (T1 and T2)
reg rd_store_valid_reg = 1'b0;
reg [ID_WIDTH-1:0] id_store_reg;

// check if read key from hash table is equal to the one used
reg rd_check_valid_reg = 1'b0;
reg [ID_WIDTH-1:0] id_check_reg;

always @(posedge clk) begin
    // if request to hash table is valid prepare reading
    if (query_response_ready_stage_1) begin
        // extract address based on read hash function state
        rd_enable_reg <= query_request_valid;
        id_hash_reg <= query_request_id;
    end

    // if a new hash has been computed
    if (query_response_ready_stage_2) begin
        rd_data_valid_reg <= rd_enable_reg;
        id_rd_reg <= id_hash_reg;
    end

    if (query_response_ready_stage_3) begin
        rd_store_valid_reg <= rd_data_valid_reg;
        id_store_reg <= id_rd_reg;
    end

    if (query_response_ready_stage_4) begin
        rd_check_valid_reg <= rd_store_valid_reg;
        id_check_reg <= id_store_reg;
    end

    if (rst) begin
        rd_enable_reg <= 1'b0;
        rd_data_valid_reg <= 1'b0;
        rd_store_valid_reg <= 1'b0;
        rd_check_valid_reg <= 1'b0;
    end
end

// registers for clearing the hash table
reg clear_table_reg = 1'b0, clear_table_next;

// propagate ready
assign query_response_ready_stage_1 = (!rd_enable_reg || query_response_ready_stage_2) && !clear_table_reg;
assign query_response_ready_stage_2 = (!rd_data_valid_reg || query_response_ready_stage_3) && !clear_table_reg;
assign query_response_ready_stage_3 = !rd_store_valid_reg || query_response_ready_stage_4;
assign query_response_ready_stage_4 = !rd_check_valid_reg || query_response_ready;

// set ready of request
assign query_request_ready = query_response_ready_stage_1;

// wires for share result from each table
wire [TABLE_COUNT-1:0] rd_check_match;
wire [TABLE_COUNT*STORE_WIDTH-1:0] rd_check_data;

// encode winner entry for data
wire [TABLE_WIDTH-1:0] query_response_select;
priority_encoder #(
    .WIDTH(TABLE_COUNT),
    .LSB_HIGH_PRIORITY(0)
)
priority_encoder_masked (
    .input_unencoded(rd_check_match),
    .output_valid(),
    .output_encoded(query_response_select),
    .output_unencoded()
);

// set response to query
assign query_response_data = rd_check_data[query_response_select*STORE_WIDTH +: STORE_WIDTH];
assign query_response_id = id_check_reg;
assign query_response_valid = rd_check_valid_reg;
assign query_response_error = !(|rd_check_match);
assign query_response_table = query_response_select;

// Write side of hash table
localparam [3:0]
    STATE_IDLE = 4'd0,
    STATE_READ_FIRST = 4'd1,
    STATE_STORE_FIRST = 4'd2,
    STATE_PREPARE_FIRST = 4'd3,
    STATE_CHECK_FIRST = 4'd4,
    STATE_READ_T2 = 4'd5,
    STATE_STORE_T2 = 4'd6,
    STATE_PREPARE_T2 = 4'd7,
    STATE_CHECK_T2 = 4'd8,
    STATE_CLEAR = 4'd9;

// finite state machine
reg [3:0] state_reg = STATE_IDLE, state_next;

// counter of iterations of cuckoo hashing
reg [LOOP_WIDTH-1:0] iteration_counter_reg = 0, iteration_counter_next;

// table pointer
reg [TABLE_WIDTH-1:0] table_reg = {TABLE_WIDTH{1'b0}}, table_next;

// registers to set the write ready signal
reg write_request_ready_reg = 1'b0, write_request_ready_next;

assign write_request_ready = write_request_ready_reg;

// last write operation results
reg write_response_valid_reg = 1'b0, write_response_valid_next;
reg write_response_error_reg = 1'b0, write_response_error_next;

assign write_response_error = write_response_error_reg;
assign write_response_iteration = iteration_counter_reg;
assign write_response_valid = write_response_valid_reg;

reg [MAX_LOOP_HIT_COUNTER_WIDTH-1:0] max_loop_hit_counter_reg = 0;

assign max_loop_hit_counter = max_loop_hit_counter_reg;

// registers to store read entries
wire [TABLE_COUNT*ENTRY_WIDTH-1:0] wr_data_reg;
reg  [TABLE_COUNT*ENTRY_WIDTH-1:0] wr_data_store_reg;

// depending on registers inserted or not
wire [TABLE_COUNT*ENTRY_WIDTH-1:0] wr_data_reg_int = REGISTER_STORE_STATE ? wr_data_store_reg : wr_data_reg;

// input to the hash functions
wire [KEY_WIDTH-1:0] write_request_data_input = write_request_ready_reg ? write_request_data[KEY_WIDTH-1:0] : write_request_data_next[KEY_WIDTH-1:0];

// output of the hash functions
wire [TABLE_COUNT*LFSR_WIDTH-1:0] write_request_hash;

// auxiliar registers to perform calculations, checks and writes
reg  [ENTRY_WIDTH-1:0] write_request_data_reg = {ENTRY_WIDTH{1'b0}}, write_request_data_next;

// pointers for reading and writing to the hash table
reg  [TABLE_COUNT*ADDR_WIDTH-1:0] wr_ptr_reg, wr_ptr_next;

// signals to read from and write to the hash table
reg [TABLE_COUNT-1:0] read_table;
reg [TABLE_COUNT-1:0] write_table;

// final write mask based on config values
wire write_table_config = CONFIG_ENABLE ? config_max_util > utilization_table: 1'b1;

// signals for checks in algorithm and writes to tables
reg [TABLE_COUNT-1:0] wr_rewrite_tables_reg = {TABLE_COUNT{1'b0}}, wr_rewrite_tables_next, wr_rewrite_tables_int; 
reg [TABLE_COUNT-1:0] wr_filter_tables_reg = {TABLE_COUNT{1'b0}}, wr_filter_tables_next, wr_filter_tables_int; 
reg [TABLE_COUNT-1:0] wr_all_tables_reg = 0, wr_all_tables_next;
reg [TABLE_COUNT-1:0] wr_prio_tables_reg = 0, wr_prio_tables_next, wr_prio_tables_int;
reg wr_request_active_reg = 1'b0, wr_request_active_next, wr_request_active_int;
reg wr_select_table_active_reg = 1'b0, wr_select_table_active_next, wr_select_table_active_int;

// helper wire for active
wire write_request_active_reg = write_request_data_reg[ACTIVE_OFFSET];

wire [ENTRY_WIDTH-1:0] write_request_input;

assign write_request_input[WRITE_WIDTH-1:0] = write_request_data;
assign write_request_input[ACTIVE_OFFSET] = write_request_active;

reg [$clog2(TABLE_COUNT)-1:0] write_select_table_reg = 0, write_select_table_next, write_select_table_int;
reg [$clog2(TABLE_COUNT)-1:0] write_last_select_table_reg = 0, write_last_select_table_next;
reg [$clog2(TABLE_COUNT)-1:0] write_start_last_select_table_reg = 0, write_start_last_select_table_next;

reg [$clog2(TABLE_COUNT)-1:0] random_seed_reg = 0, random_seed_next;
reg [48-1:0] key_random_reg = 48'h1122811C9DC5, key_random_next;

integer m;
always @* begin
    state_next = STATE_IDLE;

    iteration_counter_next = iteration_counter_reg;

    write_response_valid_next = 1'b0;
    write_response_error_next = 1'b0;

    table_next = table_reg;
    
    read_table = {TABLE_COUNT{1'b0}};
    write_table = {TABLE_COUNT{1'b0}};

    clear_table_next = clear_table_reg || clear_table;

    write_request_ready_next = write_request_ready_reg;

    write_request_data_next = write_request_data_reg;

    wr_ptr_next = wr_ptr_reg;

    wr_rewrite_tables_next = wr_rewrite_tables_reg;
    wr_filter_tables_next = wr_filter_tables_reg;
    wr_request_active_next = wr_request_active_reg;
    wr_select_table_active_next = wr_select_table_active_reg;

    write_select_table_next = write_select_table_reg;
    write_last_select_table_next = write_last_select_table_reg;
    write_start_last_select_table_next = write_start_last_select_table_reg;

    wr_all_tables_next = wr_all_tables_reg;
    wr_prio_tables_next = wr_prio_tables_reg;

    random_seed_next = random_seed_reg;
    key_random_next = ((key_random_reg << 5) + key_random_reg) + write_request_hash[1:0];

    case (state_reg)
        STATE_IDLE: begin
            // idle, wait for writing request
            write_request_ready_next = 1'b1;

            // accept input request
            if (write_request_valid && write_request_ready) begin
                write_request_ready_next = 1'b0;
                // store used key + route for hash inputs and active
                write_request_data_next = write_request_input;
                // store pointers based on hash results
                for (m = 0; m < TABLE_COUNT; m = m + 1) begin
                    wr_ptr_next[m*ADDR_WIDTH +: ADDR_WIDTH] = write_request_hash[m*LFSR_WIDTH +: ADDR_WIDTH];
                end
                
                // consider first iteration
                iteration_counter_next = 1;

                state_next = STATE_READ_FIRST;
            end else if (clear_table_reg || clear_table) begin
                write_request_ready_next = 1'b0;
                for (m = 0; m < TABLE_COUNT; m = m + 1) begin
                    wr_ptr_next[m*ADDR_WIDTH +: ADDR_WIDTH] = {ADDR_WIDTH{1'b0}};
                end

                write_request_data_next = {ENTRY_WIDTH{1'b0}};

                // reset counter of iterations
                iteration_counter_next = 0;

                state_next = STATE_CLEAR;
            end else begin
                write_request_data_next = {ENTRY_WIDTH{1'b0}};

                state_next = STATE_IDLE;
            end
        end 

        STATE_READ_FIRST: begin
            // read all tables
            write_request_ready_next = 1'b0;
            read_table = {TABLE_COUNT{1'b1}};

            // prepare random seed for insertion methods using random
            random_seed_next = key_random_reg[RANDOM_BITS-1:0] % TABLE_COUNT;

            if (REGISTER_STORE_STATE == 2) begin
                state_next = STATE_STORE_FIRST;
            end else if (REGISTER_STORE_STATE == 1) begin
                state_next = STATE_PREPARE_FIRST;
            end else begin
                state_next = STATE_CHECK_FIRST;
            end
        end

        STATE_STORE_FIRST: begin
            write_request_ready_next = 1'b0;

            // reset table filters
            wr_all_tables_next = 0;
            wr_prio_tables_next = 0;

            // initial insert step
            for (m = 0; m < TABLE_COUNT; m = m + 1) begin
                // check configuration mode is enabled and parallel table is enabled
                if (!CONFIG_ENABLE || m < config_table_count) begin
                    // substep 1: check if an element with the same key present in the parallel table: rewrite or deletion
                    wr_rewrite_tables_next[m] = wr_data_reg[m*ENTRY_WIDTH + ACTIVE_OFFSET] && (wr_data_reg[m*ENTRY_WIDTH +: KEY_WIDTH] == write_request_data_reg[KEY_WIDTH-1:0]);

                    // substep 2: apply filter, select group of tables for new write
                    // all tables are given the same consideration
                    wr_all_tables_next[m] = 1'b1;
                    // tables with a free location for the new element are prioritized
                    wr_prio_tables_next[m] = !wr_data_reg[m*ENTRY_WIDTH + ACTIVE_OFFSET];
                end else begin
                    wr_rewrite_tables_next[m] = 1'b0;
                end
            end

            // substep 2.5: when using prioritize free tables filter
            // check that wr_filter_tables_next is not all 0s, if not use all_tables filter result
            if (INSERTION_INITIAL_FILTER == 0) begin
                wr_filter_tables_next = wr_all_tables_next;
            end else begin
                wr_filter_tables_next = |wr_prio_tables_next ? wr_prio_tables_next : wr_all_tables_next;
            end

            state_next = STATE_PREPARE_FIRST;
        end

        STATE_PREPARE_FIRST: begin
            write_request_ready_next = 1'b0;

            if (REGISTER_STORE_STATE == 2) begin
                wr_filter_tables_int = wr_filter_tables_reg;
                wr_rewrite_tables_int = wr_rewrite_tables_reg;
                
            end else begin
                // reset table filters
                wr_all_tables_next = 0;
                wr_prio_tables_next = 0;

                // initial insert step
                for (m = 0; m < TABLE_COUNT; m = m + 1) begin
                    // check configuration mode is enabled and parallel table is enabled
                    if (!CONFIG_ENABLE || m < config_table_count) begin
                        // substep 1: check if an element with the same key present in the parallel table: rewrite or deletion
                        wr_rewrite_tables_next[m] = wr_data_reg[m*ENTRY_WIDTH + ACTIVE_OFFSET] && (wr_data_reg[m*ENTRY_WIDTH +: KEY_WIDTH] == write_request_data_reg[KEY_WIDTH-1:0]);

                        // substep 2: apply filter, select group of tables for new write
                        // all tables are given the same consideration
                        wr_all_tables_next[m] = 1'b1;
                        // tables with a free location for the new element are prioritized
                        wr_prio_tables_next[m] = !wr_data_reg[m*ENTRY_WIDTH + ACTIVE_OFFSET];
                    end else begin
                        wr_rewrite_tables_next[m] = 1'b0;
                    end
                end

                // substep 2.5: when using prioritize free tables filter
                // check that wr_filter_tables_next is not all 0s, if not use all_tables filter result
                if (INSERTION_INITIAL_FILTER == 0) begin
                    wr_filter_tables_next = wr_all_tables_next;
                end else begin
                    wr_filter_tables_next = |wr_prio_tables_next ? wr_prio_tables_next : wr_all_tables_next;
                end

                wr_rewrite_tables_int = wr_rewrite_tables_next;
                wr_filter_tables_int = wr_filter_tables_next;
            end

            // substep 3: apply strategy, select table for new write over the filtered tables
            if (|wr_rewrite_tables_int) begin
                // if a rewrite/deletion has been detected, select that table
                write_select_table_next = select_first_table(wr_rewrite_tables_int);
            end else if (INSERTION_INITIAL_STRATEGY == 0) begin
                // select first table
                write_select_table_next = select_first_table(wr_filter_tables_int);
            end else if (INSERTION_INITIAL_STRATEGY == 1) begin
                // select random table: based on the upper bits of the key
                write_select_table_next = select_random_table(wr_filter_tables_int, random_seed_reg);
            end else if (INSERTION_INITIAL_STRATEGY == 2) begin
                // select round-robin table
                write_select_table_next = select_round_robin_table(wr_filter_tables_int, write_start_last_select_table_reg);
            end else if (INSERTION_INITIAL_STRATEGY == 3) begin
                // select minimum load table
                write_select_table_next = select_min_load_table(wr_filter_tables_int);
            end

            write_start_last_select_table_next = write_select_table_next;

            // save write request active bit
            wr_request_active_next = write_request_active_reg;

            // save selected table active bit
            wr_select_table_active_next = REGISTER_STORE_STATE == 2 ? wr_data_store_reg[write_select_table_next*ENTRY_WIDTH + ACTIVE_OFFSET] : wr_data_reg[write_select_table_next*ENTRY_WIDTH + ACTIVE_OFFSET];

            state_next = STATE_CHECK_FIRST;
        end

        STATE_CHECK_FIRST: begin
            // check values read
            write_request_ready_next = 1'b0;

            if (REGISTER_STORE_STATE) begin
                wr_filter_tables_int = wr_filter_tables_reg;
                wr_rewrite_tables_int = wr_rewrite_tables_reg;
                write_select_table_int = write_select_table_reg;
                wr_request_active_int = wr_request_active_reg;
                wr_select_table_active_int = wr_select_table_active_reg;
                
            end else begin
                // reset table filters
                wr_all_tables_next = 0;
                wr_prio_tables_next = 0;

                // initial insert step
                for (m = 0; m < TABLE_COUNT; m = m + 1) begin
                    // check configuration mode is enabled and parallel table is enabled
                    if (!CONFIG_ENABLE || m < config_table_count) begin
                        // substep 1: check if an element with the same key present in the parallel table: rewrite or deletion
                        wr_rewrite_tables_int[m] = wr_data_reg[m*ENTRY_WIDTH + ACTIVE_OFFSET] && (wr_data_reg[m*ENTRY_WIDTH +: KEY_WIDTH] == write_request_data_reg[KEY_WIDTH-1:0]);

                        // substep 2: apply filter, select group of tables for new write
                        // all tables are given the same consideration
                        wr_all_tables_next[m] = 1'b1;
                        // tables with a free location for the new element are prioritized
                        wr_prio_tables_next[m] = !wr_data_reg[m*ENTRY_WIDTH + ACTIVE_OFFSET];
                    end else begin
                        wr_rewrite_tables_int[m] = 1'b0;
                    end
                end

                // substep 2.5: when using prioritize free tables filter
                // check that wr_filter_tables_next is not all 0s, if not use all_tables filter result
                if (INSERTION_INITIAL_FILTER == 0) begin
                    wr_filter_tables_int = wr_all_tables_next;
                end else begin
                    wr_filter_tables_int = |wr_prio_tables_next ? wr_prio_tables_next : wr_all_tables_next;
                end

                // substep 3: apply strategy, select table for new write over the filtered tables
                if (|wr_rewrite_tables_int) begin
                    // if a rewrite has been detected, select that table
                    write_select_table_int = select_first_table(wr_rewrite_tables_int);
                end else if (INSERTION_INITIAL_STRATEGY == 0) begin
                    // select first table
                    write_select_table_int = select_first_table(wr_filter_tables_int);
                end else if (INSERTION_INITIAL_STRATEGY == 1) begin
                    // select random table: based on the upper bits of the key
                    write_select_table_int = select_random_table(wr_filter_tables_int, random_seed_reg);
                end else if (INSERTION_INITIAL_STRATEGY == 2) begin
                    // select round-robin table
                    write_select_table_int = select_round_robin_table(wr_filter_tables_int, write_start_last_select_table_reg);
                end else if (INSERTION_INITIAL_STRATEGY == 3) begin
                    // select minimum load table
                    write_select_table_int = select_min_load_table(wr_filter_tables_int);
                end

                write_start_last_select_table_next = write_select_table_int;

                // save write request active bit
                wr_request_active_int = write_request_active_reg;

                // save selected table active bit
                wr_select_table_active_int = wr_data_reg[write_select_table_int*ENTRY_WIDTH + ACTIVE_OFFSET];
            end

            // write to selected table
            if (!CONFIG_ENABLE || (|wr_rewrite_tables_int)) begin
                write_table = |(wr_filter_tables_int | wr_rewrite_tables_int) << write_select_table_int;
            end else begin
                write_table = (write_table_config && |(wr_filter_tables_int)) << write_select_table_int;
            end

            write_select_table_next = write_select_table_int;

            // if it was a rewrite or deletion or new write in a free location
            if (|wr_rewrite_tables_int || (|wr_filter_tables_int && !wr_select_table_active_int)) begin
                // store last used table if new write
                if (!(|wr_rewrite_tables_int)) begin
                    write_last_select_table_next = write_select_table_int;
                end

                // keep iterations counter (it will be reset in the next state or directly set to 1 if inmediate write)
                iteration_counter_next = iteration_counter_reg;

                write_request_ready_next = !clear_table_next;
                write_response_valid_next = 1'b1;

                write_response_error_next = !(|write_table);

                write_request_data_next = {ENTRY_WIDTH{1'b0}};

                state_next = STATE_IDLE;

            // if the write displaced another element
            end else if (|wr_filter_tables_int && wr_select_table_active_int && (!CONFIG_ENABLE || write_table_config)) begin
                // store last used table
                write_last_select_table_next = write_select_table_int;

                // prepare future write to next table using exchanged (old) entry of T1
                write_request_data_next = wr_data_reg_int[write_select_table_int*ENTRY_WIDTH +: ENTRY_WIDTH];

                // store pointers based on hash results for all tables
                for (m = 0; m < TABLE_COUNT; m = m + 1) begin
                    wr_ptr_next[m*ADDR_WIDTH +: ADDR_WIDTH] = write_request_hash[m*LFSR_WIDTH +: ADDR_WIDTH];
                end

                // increase iteration counter by one
                iteration_counter_next = iteration_counter_reg + 1;

                state_next = STATE_READ_T2;

            // if it was a deletion and that element was not present in the table
            end else begin
                // keep iterations counter (it will be reset in the next state or directly set to 1 if inmediate write)
                iteration_counter_next = 0;

                write_request_ready_next = !clear_table_next;
                write_response_valid_next = 1'b1;

                write_response_error_next = !(|write_table);

                write_request_data_next = {ENTRY_WIDTH{1'b0}};

                state_next = STATE_IDLE;
            end
        end

        STATE_READ_T2: begin
            // read all tables using read value from previous table
            write_request_ready_next = 1'b0;
            read_table = {TABLE_COUNT{1'b1}};    

            // prepare random seed for insertion methods using random
            random_seed_next = key_random_reg[RANDOM_BITS-1:0] % TABLE_COUNT;

            if (REGISTER_STORE_STATE == 2) begin
                state_next = STATE_STORE_T2;
            end else if (REGISTER_STORE_STATE == 1) begin
                state_next = STATE_PREPARE_T2;
            end else begin
                state_next = STATE_CHECK_T2;
            end
        end

        STATE_STORE_T2: begin
            write_request_ready_next = 1'b0;

            // reset table filters
            wr_all_tables_next = 0;
            wr_prio_tables_next = 0;

            // reallocate step
            for (m = 0; m < TABLE_COUNT; m = m + 1) begin
                // check configuration mode is enabled and parallel table is enabled and that last table is not selected
                if (write_select_table_reg != m && (!CONFIG_ENABLE || m < config_table_count)) begin
                    // substep 1: apply filter, select group of tables for next write, exclude previous table
                    // all tables are given the same consideration
                    wr_all_tables_next[m] = 1'b1;
                    // tables with a free location for the new element are prioritized
                    wr_prio_tables_next[m] = !wr_data_reg[m*ENTRY_WIDTH + ACTIVE_OFFSET];
                end
            end

            // substep 1.5: when using prioritize free tables filter
            // check that wr_filter_tables_next is not all 0s, if not use all_tables filter result
            if (INSERTION_REALLOCATE_FILTER == 0) begin
                wr_filter_tables_next = wr_all_tables_next;
            end else begin
                wr_filter_tables_next = |wr_prio_tables_next ? wr_prio_tables_next : wr_all_tables_next;
            end

            state_next = STATE_PREPARE_T2;
        end

        STATE_PREPARE_T2: begin
            write_request_ready_next = 1'b0;

            if (REGISTER_STORE_STATE == 2) begin
                wr_filter_tables_int = wr_filter_tables_reg;
                wr_prio_tables_int = wr_prio_tables_reg;
            end else begin
                // reset table filters
                wr_all_tables_next = 0;
                wr_prio_tables_next = 0;

                // reallocate step
                for (m = 0; m < TABLE_COUNT; m = m + 1) begin
                    // check configuration mode is enabled and parallel table is enabled and that last table is not selected
                    if (write_select_table_reg != m && (!CONFIG_ENABLE || m < config_table_count)) begin
                        // substep 1: apply filter, select group of tables for new write
                        // all tables are given the same consideration
                        wr_all_tables_next[m] = 1'b1;
                        // tables with a free location for the new element are prioritized
                        wr_prio_tables_next[m] = !wr_data_reg[m*ENTRY_WIDTH + ACTIVE_OFFSET];
                    end
                end

                // substep 1.5: when using prioritize free tables filter
                // check that wr_filter_tables_next is not all 0s, if not use all_tables filter result
                if (INSERTION_REALLOCATE_FILTER == 0) begin
                    wr_filter_tables_next = wr_all_tables_next;
                end else begin
                    wr_filter_tables_next = |wr_prio_tables_next ? wr_prio_tables_next : wr_all_tables_next;
                end

                wr_prio_tables_int = wr_prio_tables_next;
                wr_filter_tables_int = wr_filter_tables_next;
            end

            // substep 2: apply strategy, select table for new write over the filtered tables
            if (INSERTION_REALLOCATE_FILTER == 0 || !(|wr_prio_tables_int)) begin
                // if filter prioritize free tables filter is active and wr_prio_tables_next in empty
                // select as in round robin (select next table to the one used)
                write_select_table_next = select_round_robin_table(wr_filter_tables_int, write_last_select_table_reg);
            end else if (INSERTION_REALLOCATE_STRATEGY == 0) begin
                // select first table
                write_select_table_next = select_first_table(wr_filter_tables_int);
            end else if (INSERTION_REALLOCATE_STRATEGY == 1) begin
                // select random table: based on the upper bits of the key
                write_select_table_next = select_random_table(wr_filter_tables_int, random_seed_reg);
            end else if (INSERTION_REALLOCATE_STRATEGY == 2) begin
                // select round-robin table
                write_select_table_next = select_round_robin_table(wr_filter_tables_int, write_last_select_table_reg);
            end else if (INSERTION_REALLOCATE_STRATEGY == 3) begin
                // select minimum load table
                write_select_table_next = select_min_load_table(wr_filter_tables_int);
            end

            // save selected table active bit
            wr_select_table_active_next = REGISTER_STORE_STATE == 2 ? wr_data_store_reg[write_select_table_next*ENTRY_WIDTH + ACTIVE_OFFSET] : wr_data_reg[write_select_table_next*ENTRY_WIDTH + ACTIVE_OFFSET];

            state_next = STATE_CHECK_T2;
        end

        STATE_CHECK_T2: begin
            // check value read from T2
            write_request_ready_next = 1'b0;

            if (REGISTER_STORE_STATE) begin
                write_select_table_int = write_select_table_reg;
                wr_select_table_active_int = wr_select_table_active_reg;
            end else begin
                // reset table filters
                wr_all_tables_next = 0;
                wr_prio_tables_next = 0;

                // reallocate step
                for (m = 0; m < TABLE_COUNT; m = m + 1) begin
                    // check configuration mode is enabled and parallel table is enabled
                    if (write_select_table_reg != m && (!CONFIG_ENABLE || m < config_table_count)) begin
                        // substep 1: apply filter, select group of tables for new write
                        // all tables are given the same consideration
                        wr_all_tables_next[m] = 1'b1;
                        // tables with a free location for the new element are prioritized
                        wr_prio_tables_next[m] = !wr_data_reg[m*ENTRY_WIDTH + ACTIVE_OFFSET];
                    end
                end

                // substep 1.5: when using prioritize free tables filter
                // check that wr_filter_tables_next is not all 0s, if not use all_tables filter result
                if (INSERTION_REALLOCATE_FILTER == 0) begin
                    wr_filter_tables_int = wr_all_tables_next;
                end else begin
                    wr_filter_tables_int = |wr_prio_tables_next ? wr_prio_tables_next : wr_all_tables_next;
                end

                // substep 2: apply strategy, select table for new write over the filtered tables
                if (INSERTION_REALLOCATE_FILTER == 0 || !(|wr_prio_tables_next)) begin
                    // if filter prioritize free tables filter is active and wr_prio_tables_next in empty
                    // select as in round robin (select next table to the one used)
                    write_select_table_int = select_round_robin_table(wr_filter_tables_int, write_last_select_table_reg);
                end else if (INSERTION_REALLOCATE_STRATEGY == 0) begin
                    // select first table
                    write_select_table_int = select_first_table(wr_filter_tables_int);
                end else if (INSERTION_REALLOCATE_STRATEGY == 1) begin
                    // select random table: based on the upper bits of the key
                    write_select_table_int = select_random_table(wr_filter_tables_int, random_seed_reg);
                end else if (INSERTION_REALLOCATE_STRATEGY == 2) begin
                    // select round-robin table
                    write_select_table_int = select_round_robin_table(wr_filter_tables_int, write_last_select_table_reg);
                end else if (INSERTION_REALLOCATE_STRATEGY == 3) begin
                    // select minimum load table
                    write_select_table_int = select_min_load_table(wr_filter_tables_int);
                end

                // save selected table active bit
                wr_select_table_active_int = wr_data_reg[write_select_table_int*ENTRY_WIDTH + ACTIVE_OFFSET];
            end

            // write to selected table
            write_table = 1 << write_select_table_int;

            write_select_table_next = write_select_table_int;

            // if write to a free location
            if (!wr_select_table_active_int || (!CONFIG_ENABLE && iteration_counter_reg == LOOP_COUNT) || (CONFIG_ENABLE && iteration_counter_reg == config_max_loop_count)) begin
                // store last used table
                write_last_select_table_next = write_select_table_int;

                // signal error in writing if not empty ending location
                write_response_error_next = wr_select_table_active_int;

                // keep iterations counter (it will be reset in the next state or directly set to 1 if inmediate write)
                iteration_counter_next = iteration_counter_reg;

                write_request_ready_next = !clear_table_next;
                write_response_valid_next = 1'b1;

                write_request_data_next = {ENTRY_WIDTH{1'b0}};

                state_next = STATE_IDLE;
            end else begin
                // store last used table
                write_last_select_table_next = write_select_table_int;

                // prepare future write to next table using exchanged (old) entry of T1
                write_request_data_next = wr_data_reg_int[write_select_table_int*ENTRY_WIDTH +: ENTRY_WIDTH];

                // store pointers based on hash results for all tables
                for (m = 0; m < TABLE_COUNT; m = m + 1) begin
                    wr_ptr_next[m*ADDR_WIDTH +: ADDR_WIDTH] = write_request_hash[m*LFSR_WIDTH +: ADDR_WIDTH];
                end

                // increase iteration counter by one
                iteration_counter_next = iteration_counter_reg + 1;

                state_next = STATE_READ_T2;
            end
        end

        STATE_CLEAR: begin
            write_request_ready_next = 1'b0;
            // walk through all entries of the tables
            write_request_data_next = {ENTRY_WIDTH{1'b0}};

            // clear management
            if (clear_table) begin
                // start again
                for (m = 0; m < TABLE_COUNT; m = m + 1) begin
                    wr_ptr_next[m*ADDR_WIDTH +: ADDR_WIDTH] = {ADDR_WIDTH{1'b0}};
                end
                clear_table_next = 1'b1;

                state_next = STATE_CLEAR;
            end else if (clear_table_reg) begin
                for (m = 0; m < TABLE_COUNT; m = m + 1) begin
                    wr_ptr_next[m*ADDR_WIDTH +: ADDR_WIDTH] = wr_ptr_reg[m*ADDR_WIDTH +: ADDR_WIDTH] + 1;
                    write_table[m] = 1'b1;
                end
                clear_table_next = wr_ptr_next[ADDR_WIDTH-1:0] != 0;

                write_request_ready_next = !clear_table_next;
                state_next = clear_table_next ? STATE_CLEAR : STATE_IDLE;
            end
        end
    endcase
end

// max loop hit counter
always @(posedge clk) begin
    if (write_response_valid_next && write_response_error_next) begin
        max_loop_hit_counter_reg <= max_loop_hit_counter_reg + 1;
    end else begin
        max_loop_hit_counter_reg <= max_loop_hit_counter_reg;
    end

    if (state_reg == STATE_CLEAR) begin
        max_loop_hit_counter_reg <= 0;
    end

    if (rst) begin
        max_loop_hit_counter_reg <= 0;
    end
end

always @(posedge clk) begin
    state_reg <= state_next;

    iteration_counter_reg <= iteration_counter_next;

    write_response_valid_reg <= write_response_valid_next;
    write_response_error_reg <= write_response_error_next;

    clear_table_reg <= clear_table_next;

    table_reg <= table_next;

    write_request_ready_reg <= write_request_ready_next;
    write_request_data_reg <= write_request_data_next;
    wr_ptr_reg <= wr_ptr_next;

    wr_rewrite_tables_reg <= wr_rewrite_tables_next;
    wr_filter_tables_reg <= wr_filter_tables_next;
    wr_request_active_reg <= wr_request_active_next;
    wr_select_table_active_reg <= wr_select_table_active_next;

    wr_data_store_reg <= wr_data_reg;

    write_select_table_reg <= write_select_table_next;
    write_last_select_table_reg <= write_last_select_table_next;
    write_start_last_select_table_reg <= write_start_last_select_table_next;

    wr_all_tables_reg <= wr_all_tables_next;
    wr_prio_tables_reg <= wr_prio_tables_next;

    random_seed_reg <= random_seed_next;
    key_random_reg <= key_random_next;

    if (rst) begin
        state_reg <= STATE_IDLE;

        iteration_counter_reg <= {LOOP_WIDTH{1'b0}};

        write_response_valid_reg <= 1'b0;
        write_response_error_reg <= 1'b0;

        clear_table_reg <= 1'b1;

        table_reg <= {TABLE_WIDTH{1'b0}};

        wr_rewrite_tables_reg <= {TABLE_COUNT{1'b0}};
        wr_filter_tables_reg <= {TABLE_COUNT{1'b0}};
        wr_request_active_reg <= 1'b0;
        wr_select_table_active_reg <= 1'b0;

        write_request_ready_reg <= 1'b0;

        write_select_table_reg <= 0;
        write_last_select_table_reg <= 0;
        write_start_last_select_table_reg <= 0;

        wr_all_tables_reg <= 0;
        wr_prio_tables_reg <= 0;

        random_seed_reg <= 0;
        key_random_reg <= 48'h1122811C9DC5;

        write_request_data_reg <= {ENTRY_WIDTH{1'b0}};
        wr_data_store_reg <= {TABLE_COUNT*ENTRY_WIDTH{1'b0}};
    end
end

// Table instantiations, hash functions and some handling
generate
    genvar n;

    for (n = 0; n < TABLE_COUNT; n = n + 1) begin: tables
        // Instantiation of table
        (* ram_style = "block", cascade_height = 0 *)
        reg [ENTRY_WIDTH-1:0] mem [2**ADDR_WIDTH-1:0];

        integer k;
        initial begin
            for (k = 0; k < 2**ADDR_WIDTH; k = k + 1) begin
                mem[k] = {ENTRY_WIDTH{1'b0}};
            end
        end

        // Read interface: lookup
        wire [LFSR_WIDTH-1:0] query_request_hash;

        lfsr #(
            .LFSR_WIDTH(LFSR_WIDTH),
            .LFSR_POLY(LFSR_POLY[LFSR_WIDTH*n +: LFSR_WIDTH]),
            .LFSR_CONFIG("GALOIS"),
            .LFSR_FEED_FORWARD(LFSR_FEED_FORWARD),
            .REVERSE(LFSR_REVERSE),
            .DATA_WIDTH(KEY_WIDTH),
            .STYLE(LFSR_STYLE)
        )
        read_hash_inst (
            .data_in(query_request_data),
            .state_in(LFSR_STATE_IN),
            .data_out(),
            .state_out(query_request_hash)
        );
        
        // store hash result and input key
        reg [ADDR_WIDTH-1:0] rd_ptr_reg;
        reg [KEY_WIDTH-1:0] query_request_data_reg;

        always @(posedge clk) begin
            // if request to hash table is valid prepare reading
            if (query_response_ready_stage_1) begin
                // extract address based on read hash function state
                if (CONFIG_ENABLE) begin
                    rd_ptr_reg <= query_request_hash[ADDR_WIDTH-1:0] & config_depth_mask;
                end else begin
                    rd_ptr_reg <= query_request_hash[ADDR_WIDTH-1:0];
                end
                query_request_data_reg <= query_request_data;
            end
        end

        // perform reading from hash table
        reg [ENTRY_WIDTH-1:0] rd_data_reg;
        reg [KEY_WIDTH-1:0] query_request_data_reg_reg;

        always @(posedge clk) begin
            // if a new hash has been computed
            if (query_response_ready_stage_2) begin
                rd_data_reg <= mem[rd_ptr_reg];
                query_request_data_reg_reg <= query_request_data_reg;
            end
        end

        // store, try to force output register for BRAMs (T1 and T2)
        reg [ENTRY_WIDTH-1:0] rd_data_store_reg;
        reg [KEY_WIDTH-1:0] query_request_data_store_reg;

        always @(posedge clk) begin
            // if a new hash has been computed
            if (query_response_ready_stage_3) begin
                rd_data_store_reg <= rd_data_reg;
                query_request_data_store_reg <= query_request_data_reg_reg;
            end
        end

        // check if read key from hash table is equal to the one used
        reg [STORE_WIDTH-1:0] rd_check_data_reg;
        reg rd_check_match_reg;

        always @(posedge clk) begin
            // if a new hash has been computed
            if (query_response_ready_stage_4) begin
                rd_check_data_reg <= rd_data_store_reg[KEY_WIDTH +: STORE_WIDTH];
                // check if active and keys match
                rd_check_match_reg <= rd_data_store_reg[ACTIVE_OFFSET] && (query_request_data_store_reg == rd_data_store_reg[KEY_WIDTH-1:0]);
            end
        end

        assign rd_check_match[n] = rd_check_match_reg;
        assign rd_check_data[n*STORE_WIDTH +: STORE_WIDTH] = rd_check_data_reg;

        // Write interface: insertion / deletion
        wire [LFSR_WIDTH-1:0] write_request_hash_local;

        lfsr #(
            .LFSR_WIDTH(LFSR_WIDTH),
            .LFSR_POLY(LFSR_POLY[LFSR_WIDTH*n +: LFSR_WIDTH]),
            .LFSR_CONFIG("GALOIS"),
            .LFSR_FEED_FORWARD(LFSR_FEED_FORWARD),
            .REVERSE(LFSR_REVERSE),
            .DATA_WIDTH(KEY_WIDTH),
            .STYLE(LFSR_STYLE)
        )
        write_hash_inst (
            .data_in(write_request_data_input),
            .state_in(LFSR_STATE_IN),
            .data_out(),
            .state_out(write_request_hash_local)
        );

        if (CONFIG_ENABLE) begin
            assign write_request_hash[n*LFSR_WIDTH +: LFSR_WIDTH] = write_request_hash_local & {{LFSR_WIDTH-ADDR_WIDTH{1'b1}}, config_depth_mask};
        end else begin
            assign write_request_hash[n*LFSR_WIDTH +: LFSR_WIDTH] = write_request_hash_local;
        end

        // register for word read
        reg [ENTRY_WIDTH-1:0] wr_data_local_reg = {ENTRY_WIDTH{1'b0}};
        
        // registers for new write word
        reg [ENTRY_WIDTH-1:0] write_request_local_data_reg, write_request_local_data_next;

        // utilization counter for table 'n'
        reg [UTILIZATION_LOCAL_WIDTH-1:0] utilization_counter_local_reg = {UTILIZATION_LOCAL_WIDTH{1'b0}};

        // counter to iterate over all the entries
        reg [ADDR_WIDTH-1:0] table_entry_reg = {ADDR_WIDTH{1'b0}}, table_entry_next;

        wire [ADDR_WIDTH-1:0] wr_ptr_reg_local = wr_ptr_reg[n*ADDR_WIDTH +: ADDR_WIDTH];

        always @(posedge clk) begin
            if (read_table[n]) begin
                wr_data_local_reg <= mem[wr_ptr_reg[n*ADDR_WIDTH +: ADDR_WIDTH]];
            end

            if (write_table[n]) begin
                mem[wr_ptr_reg[n*ADDR_WIDTH +: ADDR_WIDTH]] <= write_request_data_reg;
            end

            // increase/decrease counter
            if (state_reg == STATE_CLEAR) begin
                utilization_counter_local_reg <= {UTILIZATION_LOCAL_WIDTH{1'b0}};
            end else if (write_table[n]) begin
                if (REGISTER_STORE_STATE) begin
                    utilization_counter_local_reg <= utilization_counter_local_reg + write_request_data_reg[ACTIVE_OFFSET] - wr_data_store_reg[n*ENTRY_WIDTH + ACTIVE_OFFSET];
                end else begin
                    utilization_counter_local_reg <= utilization_counter_local_reg + write_request_data_reg[ACTIVE_OFFSET] - wr_data_local_reg[ACTIVE_OFFSET];
                end
            end

            if (rst) begin
                utilization_counter_local_reg <= {UTILIZATION_LOCAL_WIDTH{1'b0}};

                wr_data_local_reg <= {ENTRY_WIDTH{1'b0}};
            end
        end

        // If config enable, loop data from previous table to make it avaiable for the next writing in the next "usable table" (minimum number of tables is 2 (n > 1))
        if (CONFIG_ENABLE && n > 1) begin
            assign wr_data_reg[n*ENTRY_WIDTH +: ENTRY_WIDTH] = config_table_count > n ? wr_data_local_reg : wr_data_reg[(n-1)*ENTRY_WIDTH +: ENTRY_WIDTH];
        end else begin
            assign wr_data_reg[n*ENTRY_WIDTH +: ENTRY_WIDTH] = wr_data_local_reg;
        end

        assign utilization_counter_wire[n*UTILIZATION_LOCAL_WIDTH +: UTILIZATION_LOCAL_WIDTH] = utilization_counter_local_reg;
    end

endgenerate

endmodule

`resetall