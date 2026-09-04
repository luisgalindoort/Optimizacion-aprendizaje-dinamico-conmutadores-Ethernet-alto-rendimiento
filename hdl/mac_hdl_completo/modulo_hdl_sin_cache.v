`resetall
`timescale 1ns/1ps
`default_nettype none

module modulo_hdl_sin_cache #
(
    parameter PORT_GLOBAL_COUNT = 8,
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

    output wire [31:0]                   mac_table_write_requests,
    output wire [31:0]                   mac_table_write_responses,
    output wire [31:0]                   mac_table_write_success,
    output wire [31:0]                   mac_table_write_failed,
    output wire [31:0]                   mac_table_learned_entries
);

localparam KEY_WIDTH       = 48;
localparam STORE_WIDTH     = PORT_GLOBAL_COUNT;
localparam FIFO_DATA_WIDTH = KEY_WIDTH + STORE_WIDTH;
localparam ID_WIDTH        = FIFO_DATA_WIDTH;
localparam MAC_FIFO_DEPTH  = 64;
localparam MAC_LOOP_WIDTH  = MAC_LOOP_COUNT > 1 ? $clog2(MAC_LOOP_COUNT+1) : 1;

wire input_hs;

wire [FIFO_DATA_WIDTH-1:0] mac_fifo_wr_data;
wire [FIFO_DATA_WIDTH-1:0] mac_fifo_rd_data;
wire                       mac_fifo_wr_ready;
wire                       mac_fifo_wr_enable;
wire                       mac_fifo_rd_valid;
wire                       mac_fifo_rd_enable;
wire                       mac_fifo_empty;
wire                       mac_fifo_full;
wire [$clog2(MAC_FIFO_DEPTH):0] mac_fifo_status_depth;

assign learn_request_ready_out = mac_fifo_wr_ready;
assign input_hs = learn_request_valid_in && learn_request_ready_out;

assign learn_request_mac_out   = learn_request_mac_in;
assign learn_request_port_out  = learn_request_port_in;
assign learn_request_valid_out = input_hs;

assign mac_fifo_wr_data   = {learn_request_port_in, learn_request_mac_in};
assign mac_fifo_wr_enable = input_hs;

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

reg mac_write_wait_response_reg = 1'b0;

wire mac_write_ready;
wire mac_write_response_valid;
wire mac_write_response_error;
wire [MAC_LOOP_WIDTH-1:0] mac_write_response_iteration;
wire mac_write_hs;
wire mac_write_valid_reg;
wire [FIFO_DATA_WIDTH-1:0] mac_write_request_data;
wire [$clog2(MAC_HASH_DEPTH):0] mac_utilization_table;

reg [31:0] mac_table_write_requests_reg = 32'd0;
reg [31:0] mac_table_write_responses_reg = 32'd0;
reg [31:0] mac_table_write_success_reg = 32'd0;
reg [31:0] mac_table_write_failed_reg = 32'd0;

assign mac_write_valid_reg = (!mac_write_wait_response_reg || mac_write_response_valid) && mac_fifo_rd_valid;
assign mac_write_hs = mac_write_valid_reg && mac_write_ready;
assign mac_fifo_rd_enable = mac_write_hs;
assign mac_write_request_data = mac_fifo_rd_data;

assign mac_table_write_requests = mac_table_write_requests_reg;
assign mac_table_write_responses = mac_table_write_responses_reg;
assign mac_table_write_success = mac_table_write_success_reg;
assign mac_table_write_failed = mac_table_write_failed_reg;
assign mac_table_learned_entries = {{(32-($clog2(MAC_HASH_DEPTH)+1)){1'b0}}, mac_utilization_table};

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
