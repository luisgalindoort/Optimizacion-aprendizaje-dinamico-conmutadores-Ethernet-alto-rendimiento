`resetall
`timescale 1ns/1ps
`default_nettype none

module modulo_hdl_cache #
(
    parameter PORT_GLOBAL_COUNT = 8,
    parameter HASH_DEPTH = 4096,
    parameter TABLE_COUNT = 4,
    parameter MAC_HASH_DEPTH = 16384,
    parameter MAC_TABLE_COUNT = 4,
    parameter MAC_LOOP_COUNT = 5,
    parameter MAC_LFSR_POLY = 128'hc8f698af1dca6d1fedB8832004c11db7
)
(
    input  wire                          clk,
    input  wire                          rst,

    input  wire [47:0]                   learn_request_mac_in,
    input  wire [PORT_GLOBAL_COUNT-1:0]  learn_request_port_in,
    input  wire                          learn_request_valid_in,
    output wire                          learn_request_ready_out,

    output wire [47:0]                   learn_request_mac_out,
    output wire [PORT_GLOBAL_COUNT-1:0]  learn_request_port_out,
    output wire                          learn_request_valid_out,
    input  wire                          learn_request_ready_in,
    output wire                          learn_request_accepted_out,
    output wire                          learn_request_dropped_out,

    output wire [31:0]                   mac_table_write_requests,
    output wire [31:0]                   mac_table_write_responses,
    output wire [31:0]                   mac_table_write_success,
    output wire [31:0]                   mac_table_write_failed,
    output wire [31:0]                   mac_table_learned_entries,
    output wire                          system_ready_out
);


// Parámetros de la hash_table


localparam KEY_WIDTH   = 48;
localparam STORE_WIDTH = PORT_GLOBAL_COUNT;
localparam LOOP_COUNT  = 8;
localparam LOOP_WIDTH  = LOOP_COUNT > 1 ? $clog2(LOOP_COUNT+1) : 1;
localparam MAC_LOOP_WIDTH = MAC_LOOP_COUNT > 1 ? $clog2(MAC_LOOP_COUNT+1) : 1;
localparam FIFO_DATA_WIDTH  = KEY_WIDTH + STORE_WIDTH;
localparam WRITE_FIFO_DEPTH = 64;
localparam MAC_FIFO_DEPTH = 64;

localparam ID_WIDTH = FIFO_DATA_WIDTH;


// Interfaz lectura de la hash_table usada como cache 


wire input_hs;

wire [KEY_WIDTH-1:0] query_data;
wire [ID_WIDTH-1:0]  query_request_id;
wire                 query_valid;
wire                 query_ready;

wire [ID_WIDTH-1:0] query_response_id;
wire query_response_valid;
wire query_response_error;
wire query_response_ready;

wire [KEY_WIDTH-1:0]   response_mac;
wire [STORE_WIDTH-1:0] response_port;

// Solo aceptamos una MAC si la cache puede aceptar una query

assign learn_request_ready_out = query_ready;

//handshake de entrada
assign input_hs = learn_request_valid_in && learn_request_ready_out;

assign query_data       = learn_request_mac_in;

//Preparo el request id con mac y puerto
assign query_request_id = {learn_request_port_in, learn_request_mac_in};
assign query_valid      = input_hs;

assign query_response_ready = 1'b1;


//Separo mac y puerto del id de respuesta
assign response_mac  = query_response_id[KEY_WIDTH-1:0];
assign response_port = query_response_id[KEY_WIDTH +: STORE_WIDTH];


// Salida hacia la tabla MAC final


wire miss_event;
wire output_hs;
wire mac_fifo_wr_ready;

assign miss_event = query_response_valid && query_response_error;

assign learn_request_mac_out   = response_mac;
assign learn_request_port_out  = response_port;
assign learn_request_valid_out = miss_event;


wire unused_learn_request_ready_in = learn_request_ready_in;
assign output_hs = learn_request_valid_out && mac_fifo_wr_ready;
assign learn_request_accepted_out = output_hs;
assign learn_request_dropped_out  = learn_request_valid_out && !mac_fifo_wr_ready;

// Si valid_out = 1 y la FIFO MAC no puede aceptar, el miss se descarta.


// FIFO de escritura de cache


wire [FIFO_DATA_WIDTH-1:0] write_fifo_wr_data;
wire [FIFO_DATA_WIDTH-1:0] write_fifo_rd_data;

wire write_fifo_wr_enable;
wire write_fifo_wr_ready;

wire write_fifo_rd_valid;
wire write_fifo_rd_enable;

assign write_fifo_wr_data   = {response_port, response_mac};
assign write_fifo_wr_enable = output_hs && write_fifo_wr_ready;

switch_simple_fifo #(
    .DEPTH(WRITE_FIFO_DEPTH),
    .DATA_WIDTH(FIFO_DATA_WIDTH),
    .FILL_INIT(0),
    .FRAME_FIFO_WR(0),
    .FRAME_FIFO_RD(0),
    .DROP_OVERSIZE_FRAME(0),
    .DROP_BAD_FRAME(0),
    .DROP_WHEN_FULL(0),
    .MARK_WHEN_FULL(0)
)
cache_write_fifo_inst (
    .clk(clk),
    .rst(rst),

    .wr_data(write_fifo_wr_data),
    .wr_enable(write_fifo_wr_enable),
    .wr_ready(write_fifo_wr_ready),
    .wr_sof(1'b1),
    .wr_eof(1'b1),
    .wr_drop(1'b0),
    .wr_init(),

    .rd_data(write_fifo_rd_data),
    .rd_valid(write_fifo_rd_valid),
    .rd_ready(),
    .rd_enable(write_fifo_rd_enable),
    .rd_sof(1'b1),
    .rd_eof(1'b1),
    .rd_drop(1'b0),
    .rd_mark(),

    .empty(),
    .full(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame(),
    .status_mark_frame()
);


// Interfaz escritura de la hash_table usada como cache 


reg                        write_wait_response_reg;

wire write_ready;
wire write_response_valid;
wire write_hs;
wire write_can_load;
wire write_valid_reg;
wire [FIFO_DATA_WIDTH-1:0] write_request_data;

//handhsake escritura cache
assign write_hs = write_valid_reg && write_ready;

assign write_valid_reg = (!write_wait_response_reg || write_response_valid) && write_fifo_rd_valid;
assign write_can_load = write_hs;

assign write_fifo_rd_enable = write_hs;
assign write_request_data = write_fifo_rd_data;


// Conectar señales de la hash_table usada como cache 


wire [$clog2(HASH_DEPTH/TABLE_COUNT)-1:0] config_depth_mask;
wire [$clog2(TABLE_COUNT):0]              config_table_count;
wire [$clog2(HASH_DEPTH):0]               config_max_util;
wire [LOOP_WIDTH-1:0]                     config_max_loop_count;

assign config_depth_mask     = {($clog2(HASH_DEPTH/TABLE_COUNT)){1'b0}};
assign config_table_count    = {($clog2(TABLE_COUNT)+1){1'b0}};
assign config_max_util       = {($clog2(HASH_DEPTH)+1){1'b0}};
assign config_max_loop_count = {LOOP_WIDTH{1'b0}};


// Instancia hash_table usada como cache


hash_table #(
    .DEPTH(HASH_DEPTH),
    .TABLE_COUNT(TABLE_COUNT),
    .STORE_WIDTH(STORE_WIDTH),
    .KEY_WIDTH(KEY_WIDTH),
    .LOOP_COUNT(LOOP_COUNT),

    .INSERTION_INITIAL_FILTER(1),
    .INSERTION_INITIAL_STRATEGY(0),
    .INSERTION_REALLOCATE_FILTER(1),
    .INSERTION_REALLOCATE_STRATEGY(0),

    .CONFIG_ENABLE(0),
    .REGISTER_STORE_STATE(2),
    .ID_WIDTH(ID_WIDTH)
)
hash_inst (
    .clk(clk),
    .rst(rst),

    .query_request_data(query_data),
    .query_request_id(query_request_id),
    .query_request_valid(query_valid),
    .query_request_ready(query_ready),

    .query_response_data(),
    .query_response_id(query_response_id),
    .query_response_valid(query_response_valid),
    .query_response_ready(query_response_ready),
    .query_response_error(query_response_error),
    .query_response_table(),

    .write_request_data(write_request_data),
    .write_request_active(1'b1),
    .write_request_valid(write_valid_reg),
    .write_request_ready(write_ready),

    .write_response_error(),
    .write_response_iteration(),
    .write_response_valid(write_response_valid),

    .utilization_table(),
    .utilization_local_tables(),
    .max_loop_hit_counter(),

    .config_depth_mask(config_depth_mask),
    .config_table_count(config_table_count),
    .config_max_util(config_max_util),
    .config_max_loop_count(config_max_loop_count),

    .clear_table(1'b0)
);


// Control de escritura de la cache


always @(posedge clk) begin
    if (rst) begin
        write_wait_response_reg <= 1'b0;

    end else begin
        if (write_response_valid) begin
            write_wait_response_reg <= 1'b0;
        end

        if (write_hs) begin
            write_wait_response_reg <= 1'b1;
        end

    end
end



// Cola MAC + tabla MAC 



wire [FIFO_DATA_WIDTH-1:0] mac_fifo_wr_data;
wire [FIFO_DATA_WIDTH-1:0] mac_fifo_rd_data;

wire mac_fifo_wr_enable;
wire mac_fifo_rd_valid;
wire mac_fifo_rd_enable;
wire mac_fifo_empty;
wire mac_fifo_full;
wire [$clog2(MAC_FIFO_DEPTH):0] mac_fifo_status_depth;

assign mac_fifo_wr_data   = {response_port, response_mac};
assign mac_fifo_wr_enable = output_hs;

switch_simple_fifo #(
    .DEPTH(MAC_FIFO_DEPTH),
    .DATA_WIDTH(FIFO_DATA_WIDTH),
    .FILL_INIT(0),
    .FRAME_FIFO_WR(0),
    .FRAME_FIFO_RD(0),
    .DROP_OVERSIZE_FRAME(0),
    .DROP_BAD_FRAME(0),
    .DROP_WHEN_FULL(0),
    .MARK_WHEN_FULL(0)
)
mac_write_fifo_inst (
    .clk(clk),
    .rst(rst),

    .wr_data(mac_fifo_wr_data),
    .wr_enable(mac_fifo_wr_enable),
    .wr_ready(mac_fifo_wr_ready),
    .wr_sof(1'b1),
    .wr_eof(1'b1),
    .wr_drop(1'b0),
    .wr_init(),

    .rd_data(mac_fifo_rd_data),
    .rd_valid(mac_fifo_rd_valid),
    .rd_ready(),
    .rd_enable(mac_fifo_rd_enable),
    .rd_sof(1'b1),
    .rd_eof(1'b1),
    .rd_drop(1'b0),
    .rd_mark(),

    .empty(mac_fifo_empty),
    .full(mac_fifo_full),
    .status_depth(mac_fifo_status_depth),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame(),
    .status_mark_frame()
);


// Interfaz escritura de la tabla MAC


reg                        mac_write_wait_response_reg;

wire mac_write_ready;
wire mac_write_response_valid;
wire mac_write_response_error;
wire [MAC_LOOP_WIDTH-1:0] mac_write_response_iteration;
wire mac_write_hs;
wire mac_write_can_load;
wire mac_write_valid_reg;
wire [FIFO_DATA_WIDTH-1:0] mac_write_request_data;
wire [$clog2(MAC_HASH_DEPTH):0] mac_utilization_table;

reg [31:0] mac_table_write_requests_reg = 32'd0;
reg [31:0] mac_table_write_responses_reg = 32'd0;
reg [31:0] mac_table_write_success_reg = 32'd0;
reg [31:0] mac_table_write_failed_reg = 32'd0;

assign mac_write_hs = mac_write_valid_reg && mac_write_ready;
assign mac_write_valid_reg = (!mac_write_wait_response_reg || mac_write_response_valid) && mac_fifo_rd_valid;
assign mac_write_can_load = mac_write_hs;
assign mac_fifo_rd_enable = mac_write_hs;
assign mac_write_request_data = mac_fifo_rd_data;

assign mac_table_write_requests = mac_table_write_requests_reg;
assign mac_table_write_responses = mac_table_write_responses_reg;
assign mac_table_write_success = mac_table_write_success_reg;
assign mac_table_write_failed = mac_table_write_failed_reg;
assign mac_table_learned_entries = {{(32-($clog2(MAC_HASH_DEPTH)+1)){1'b0}}, mac_utilization_table};
assign system_ready_out = learn_request_ready_out && mac_write_ready;


wire [$clog2(MAC_HASH_DEPTH/MAC_TABLE_COUNT)-1:0] mac_config_depth_mask;
wire [$clog2(MAC_TABLE_COUNT):0]                  mac_config_table_count;
wire [$clog2(MAC_HASH_DEPTH):0]                   mac_config_max_util;
wire [MAC_LOOP_WIDTH-1:0]                         mac_config_max_loop_count;

assign mac_config_depth_mask     = {($clog2(MAC_HASH_DEPTH/MAC_TABLE_COUNT)){1'b0}};
assign mac_config_table_count    = {($clog2(MAC_TABLE_COUNT)+1){1'b0}};
assign mac_config_max_util       = {($clog2(MAC_HASH_DEPTH)+1){1'b0}};
assign mac_config_max_loop_count = {MAC_LOOP_WIDTH{1'b0}};


hash_table #(
    .DEPTH(MAC_HASH_DEPTH),
    .TABLE_COUNT(MAC_TABLE_COUNT),
    .STORE_WIDTH(STORE_WIDTH),
    .KEY_WIDTH(KEY_WIDTH),
    .LOOP_COUNT(MAC_LOOP_COUNT),

    .INSERTION_INITIAL_FILTER(1),
    .INSERTION_INITIAL_STRATEGY(0),
    .INSERTION_REALLOCATE_FILTER(1),
    .INSERTION_REALLOCATE_STRATEGY(0),

    .CONFIG_ENABLE(0),
    .REGISTER_STORE_STATE(2),
    .LFSR_POLY(MAC_LFSR_POLY),
    .ID_WIDTH(ID_WIDTH)
)
mac_table_inst (
    .clk(clk),
    .rst(rst),

    .query_request_data({KEY_WIDTH{1'b0}}),
    .query_request_id({ID_WIDTH{1'b0}}),
    .query_request_valid(1'b0),
    .query_request_ready(),

    .query_response_data(),
    .query_response_id(),
    .query_response_valid(),
    .query_response_ready(1'b1),
    .query_response_error(),
    .query_response_table(),

    .write_request_data(mac_write_request_data),
    .write_request_active(1'b1),
    .write_request_valid(mac_write_valid_reg),
    .write_request_ready(mac_write_ready),

    .write_response_error(mac_write_response_error),
    .write_response_iteration(mac_write_response_iteration),
    .write_response_valid(mac_write_response_valid),

    .utilization_table(mac_utilization_table),
    .utilization_local_tables(),
    .max_loop_hit_counter(),

    .config_depth_mask(mac_config_depth_mask),
    .config_table_count(mac_config_table_count),
    .config_max_util(mac_config_max_util),
    .config_max_loop_count(mac_config_max_loop_count),

    .clear_table(1'b0)
);


// Control de escritura de la tabla MAC


always @(posedge clk) begin
    if (rst) begin
        mac_write_wait_response_reg <= 1'b0;
        mac_table_write_requests_reg <= 32'd0;
        mac_table_write_responses_reg <= 32'd0;
        mac_table_write_success_reg <= 32'd0;
        mac_table_write_failed_reg <= 32'd0;

    end else begin
        if (mac_write_response_valid) begin
            mac_write_wait_response_reg <= 1'b0;
            mac_table_write_responses_reg <= mac_table_write_responses_reg + 1;

            if (mac_write_response_error) begin
                mac_table_write_failed_reg <= mac_table_write_failed_reg + 1;
            end else begin
                mac_table_write_success_reg <= mac_table_write_success_reg + 1;
            end
        end

        if (mac_write_hs) begin
            mac_write_wait_response_reg <= 1'b1;
            mac_table_write_requests_reg <= mac_table_write_requests_reg + 1;
        end
    end
end

endmodule

`resetall
