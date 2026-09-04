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

Modified for this proyect by Luis Galindo Ortuño.
This file adapts the original FPGA test core to implement the cache-based
MAC learning and filtering experiment.

*/

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * FPGA test core for modulo_hdl_cache.

 */
module cache_core #
(
    parameter TABLE_DEPTH = 4096,
    parameter TABLE_COUNT = 4,
    parameter TABLE_KEY_WIDTH = 48,
    parameter TABLE_STORE_WIDTH = 16,
    parameter TABLE_LOOP_COUNT = 100,
    parameter TABLE_CONFIG_ENABLE = 1,
    parameter TABLE_REGISTER_STORE_STATE = 1,
    parameter TABLE_INSERTION_INITIAL_FILTER = 1,
    parameter TABLE_INSERTION_INITIAL_STRATEGY = 0,
    parameter TABLE_INSERTION_REALLOCATE_FILTER = 1,
    parameter TABLE_INSERTION_REALLOCATE_STRATEGY = 0,
    parameter TABLE_LFSR_WIDTH = 32,
    parameter TABLE_LFSR_POLY = 128'hc8f698af1dca6d1fedB8832004c11db7,
    parameter TABLE_LFSR_STATE_IN = 32'hffffffff,
    parameter TABLE_LFSR_CONFIG = "GALOIS",
    parameter TABLE_LFSR_FEED_FORWARD = 0,
    parameter TABLE_LFSR_REVERSE = 1,
    parameter TABLE_LFSR_STYLE = "AUTO",

    parameter PORT_GLOBAL_COUNT = 8,
    parameter TRACE_DEPTH = 32768,
    parameter DRAIN_CYCLES = 10000,

    /*
     * AXI-Lite parameters
     */
    parameter AXIL_DATA_WIDTH = 32,
    parameter AXIL_ADDR_WIDTH = 16,
    parameter AXIL_STRB_WIDTH = (AXIL_DATA_WIDTH/8)
)
(
    input  wire                         clk,
    input  wire                         rst,

    /*
     * AXI-Lite slave configuration interface
     */
    input  wire [AXIL_ADDR_WIDTH-1:0]   s_axil_awaddr,
    input  wire [2:0]                   s_axil_awprot,
    input  wire                         s_axil_awvalid,
    output wire                         s_axil_awready,
    input  wire [AXIL_DATA_WIDTH-1:0]   s_axil_wdata,
    input  wire [AXIL_STRB_WIDTH-1:0]   s_axil_wstrb,
    input  wire                         s_axil_wvalid,
    output wire                         s_axil_wready,
    output wire [1:0]                   s_axil_bresp,
    output wire                         s_axil_bvalid,
    input  wire                         s_axil_bready,
    input  wire [AXIL_ADDR_WIDTH-1:0]   s_axil_araddr,
    input  wire [2:0]                   s_axil_arprot,
    input  wire                         s_axil_arvalid,
    output wire                         s_axil_arready,
    output wire [AXIL_DATA_WIDTH-1:0]   s_axil_rdata,
    output wire [1:0]                   s_axil_rresp,
    output wire                         s_axil_rvalid,
    input  wire                         s_axil_rready
);

// Parametros internos de la interfaz AXI-Lite
localparam RB_BASE_ADDR = 0;
localparam REG_ADDR_WIDTH = AXIL_ADDR_WIDTH;
localparam REG_DATA_WIDTH = AXIL_DATA_WIDTH;
localparam REG_STRB_WIDTH = AXIL_STRB_WIDTH;
localparam RBB = RB_BASE_ADDR[REG_ADDR_WIDTH-1:0];

/*
 * Register map
 *
 * 0x00 control write: bit 0 start, bit 1 clear counters/state
 * 0x04 status read:  bit 0 running, bit 1 done
 * 0x10 n_frames_target
 * 0x14 trace_count
 * 0x18 frame_gap_cycles
 * 0x1c reserved 
 * 0x20 reserved 
 * 0x24 reserved
 * 0x40 cycles_total
 * 0x44 frames_generated
 * 0x48 frames_accepted_by_cache
 * 0x4c frames_blocked_by_cache     
 * 0x50 cache_miss_outputs
 * 0x54 frames_forwarded_to_mac
 * 0x58 frames_dropped_by_mac_backpressure
 * 0x5c last_mac_generated_low
 * 0x60 trace_depth
 * 0x64 reserved 
 * 0x68 trace_write_addr
 * 0x6c trace_write_mac_low
 * 0x70 trace_write_mac_high_commit
 * 0x74 trace_read_addr
 * 0x78 trace_read_mac_low
 * 0x7c trace_read_mac_high
 * 0x80 mac_table_write_requests
 * 0x84 mac_table_write_responses
 * 0x88 mac_table_write_success
 * 0x8c mac_table_write_failed
 * 0x90 mac_table_learned_entries
 */

// Senales internas de acceso a registros
wire [REG_ADDR_WIDTH-1:0] ctrl_reg_wr_addr;
wire [REG_DATA_WIDTH-1:0] ctrl_reg_wr_data;
wire [REG_STRB_WIDTH-1:0] ctrl_reg_wr_strb;
wire                      ctrl_reg_wr_en;
wire                      ctrl_reg_wr_wait;
wire                      ctrl_reg_wr_ack;
wire [REG_ADDR_WIDTH-1:0] ctrl_reg_rd_addr;
wire                      ctrl_reg_rd_en;
wire [REG_DATA_WIDTH-1:0] ctrl_reg_rd_data;
wire                      ctrl_reg_rd_wait;
wire                      ctrl_reg_rd_ack;

// Adaptador AXI-Lite a una interfaz simple de registros
axil_reg_if #(
    .DATA_WIDTH(REG_DATA_WIDTH),
    .ADDR_WIDTH(REG_ADDR_WIDTH),
    .STRB_WIDTH(REG_STRB_WIDTH),
    .TIMEOUT(40)
)
axil_reg_if_inst (
    .clk(clk),
    .rst(rst),

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
reg [REG_DATA_WIDTH-1:0] ctrl_reg_rd_data_reg = {REG_DATA_WIDTH{1'b0}};
reg ctrl_reg_rd_ack_reg = 1'b0;

assign ctrl_reg_wr_wait = 1'b0;
assign ctrl_reg_wr_ack = ctrl_reg_wr_ack_reg;
assign ctrl_reg_rd_data = ctrl_reg_rd_data_reg;
assign ctrl_reg_rd_wait = 1'b0;
assign ctrl_reg_rd_ack = ctrl_reg_rd_ack_reg;

// Registros configurables del experimento
reg [31:0] n_frames_target_reg = 32'd1000;
reg [31:0] trace_count_reg = 32'd0;
reg [31:0] frame_gap_cycles_reg = 32'd0;

// Registros de control de ejecucion del test
reg running_reg = 1'b0;
reg done_reg = 1'b0;
reg start_pending_reg = 1'b0;
reg [2:0] dut_reset_count_reg = 3'd0;
reg startup_ready_reg = 1'b0;
reg [31:0] gap_counter_reg = 32'd0;
reg draining_reg = 1'b0;
reg [31:0] drain_counter_reg = 32'd0;

// Registro de trama presentada al modulo bajo prueba
reg [47:0] current_mac_reg = 48'd0;
reg [PORT_GLOBAL_COUNT-1:0] current_port_reg = {{PORT_GLOBAL_COUNT-1{1'b0}}, 1'b1};
reg input_valid_reg = 1'b0;

// Contadores de metricas del experimento
reg [31:0] cycles_total_reg = 32'd0;
reg [31:0] frames_generated_reg = 32'd0;
reg [31:0] frames_accepted_by_cache_reg = 32'd0;
reg [31:0] frames_blocked_by_cache_reg = 32'd0;
reg [31:0] cache_miss_outputs_reg = 32'd0;
reg [31:0] frames_forwarded_to_mac_reg = 32'd0;
reg [31:0] frames_dropped_by_mac_backpressure_reg = 32'd0;
reg [31:0] last_mac_generated_low_reg = 32'd0;

localparam TRACE_ADDR_WIDTH = TRACE_DEPTH > 1 ? $clog2(TRACE_DEPTH) : 1;
localparam [31:0] TRACE_DEPTH_32 = TRACE_DEPTH;

// BRAM de trazas: la MAC de 48 bits se divide en tres bancos de 16 bits
(* ram_style = "block" *)
reg [15:0] trace_mem_low0[0:TRACE_DEPTH-1];

(* ram_style = "block" *)
reg [15:0] trace_mem_low1[0:TRACE_DEPTH-1];

(* ram_style = "block" *)   
reg [15:0] trace_mem_high[0:TRACE_DEPTH-1];

// Registros de escritura, lectura y reproduccion de trazas
reg [31:0] trace_write_addr_reg = 32'd0;
reg [31:0] trace_write_mac_low_reg = 32'd0;
reg [15:0] trace_write_mac_high_reg = 16'd0;
reg [31:0] trace_read_addr_reg = 32'd0;
reg [47:0] trace_read_data_reg = 48'd0;
reg [31:0] trace_playback_index_reg = 32'd0;
reg [47:0] trace_playback_data_reg = 48'd0;
reg trace_playback_valid_reg = 1'b0;

// Senales de conexion con el modulo hdl cache 
wire [47:0] dut_mac_in = current_mac_reg;
wire [PORT_GLOBAL_COUNT-1:0] dut_port_in = current_port_reg;
wire dut_valid_in = input_valid_reg;
wire dut_ready_out;
wire dut_system_ready;

wire [47:0] dut_mac_out;
wire [PORT_GLOBAL_COUNT-1:0] dut_port_out;
wire dut_valid_out;
wire dut_ready_in;
wire dut_reset = rst || (dut_reset_count_reg != 0);
wire [31:0] dut_mac_table_write_requests;
wire [31:0] dut_mac_table_write_responses;
wire [31:0] dut_mac_table_write_success;
wire [31:0] dut_mac_table_write_failed;
wire [31:0] dut_mac_table_learned_entries;
wire dut_learn_request_accepted;
wire dut_learn_request_dropped;

wire input_hs = dut_valid_in && dut_ready_out;
wire output_hs = dut_learn_request_accepted;
wire output_drop = dut_learn_request_dropped;

assign dut_ready_in = 1'b1;

// Instancia del modulo HDL que se prueba desde la FPGA
modulo_hdl_cache #(
    .PORT_GLOBAL_COUNT(PORT_GLOBAL_COUNT),
    .HASH_DEPTH(TABLE_DEPTH),
    .TABLE_COUNT(TABLE_COUNT)
)
modulo_hdl_cache_inst (
    .clk(clk),
    .rst(dut_reset),

    .learn_request_mac_in(dut_mac_in),
    .learn_request_port_in(dut_port_in),
    .learn_request_valid_in(dut_valid_in),
    .learn_request_ready_out(dut_ready_out),

    .learn_request_mac_out(dut_mac_out),
    .learn_request_port_out(dut_port_out),
    .learn_request_valid_out(dut_valid_out),
    .learn_request_ready_in(dut_ready_in),
    .learn_request_accepted_out(dut_learn_request_accepted),
    .learn_request_dropped_out(dut_learn_request_dropped),

    .mac_table_write_requests(dut_mac_table_write_requests),
    .mac_table_write_responses(dut_mac_table_write_responses),
    .mac_table_write_success(dut_mac_table_write_success),
    .mac_table_write_failed(dut_mac_table_write_failed),
    .mac_table_learned_entries(dut_mac_table_learned_entries),
    .system_ready_out(dut_system_ready)
);


wire [31:0] target_frame_count =
    n_frames_target_reg < trace_count_reg ? n_frames_target_reg : trace_count_reg;

wire trace_write_addr_in_range = trace_write_addr_reg < TRACE_DEPTH_32;
wire input_slot_available = !input_valid_reg || input_hs;
wire trace_issue =
    running_reg &&
    !draining_reg &&
    startup_ready_reg &&
    dut_ready_out &&
    input_slot_available &&
    trace_playback_valid_reg &&
    gap_counter_reg == 0 &&
    frames_generated_reg < target_frame_count;
wire [31:0] trace_prefetch_index =
    trace_playback_index_reg + (trace_issue ? 32'd1 : 32'd0);
wire trace_prefetch_addr_in_range = trace_prefetch_index < TRACE_DEPTH_32;
wire [REG_ADDR_WIDTH-1:0] ctrl_reg_wr_word_addr = {ctrl_reg_wr_addr >> 2, 2'b00};
wire trace_wr_commit =
    ctrl_reg_wr_en &&
    !ctrl_reg_wr_ack_reg &&
    ctrl_reg_wr_word_addr == RBB+16'h70 &&
    trace_write_addr_in_range;
wire trace_rd_request =
    ctrl_reg_wr_en &&
    !ctrl_reg_wr_ack_reg &&
    ctrl_reg_wr_word_addr == RBB+16'h74;

// Escritura y lectura de la BRAM 
always @(posedge clk) begin
    if (trace_wr_commit) begin
        trace_mem_low0[trace_write_addr_reg[TRACE_ADDR_WIDTH-1:0]] <= trace_write_mac_low_reg[15:0];
        trace_mem_low1[trace_write_addr_reg[TRACE_ADDR_WIDTH-1:0]] <= trace_write_mac_low_reg[31:16];
        trace_mem_high[trace_write_addr_reg[TRACE_ADDR_WIDTH-1:0]] <= ctrl_reg_wr_data[15:0];
    end

    
    if (running_reg && trace_prefetch_addr_in_range && trace_prefetch_index < target_frame_count) begin
        trace_playback_data_reg <= {
            trace_mem_high[trace_prefetch_index[TRACE_ADDR_WIDTH-1:0]],
            trace_mem_low1[trace_prefetch_index[TRACE_ADDR_WIDTH-1:0]],
            trace_mem_low0[trace_prefetch_index[TRACE_ADDR_WIDTH-1:0]]
        };
        trace_playback_valid_reg <= 1'b1;
    end else begin
        trace_playback_data_reg <= 48'd0;
        trace_playback_valid_reg <= 1'b0;

        if (trace_rd_request && ctrl_reg_wr_data < TRACE_DEPTH_32) begin
            trace_read_data_reg <= {
                trace_mem_high[ctrl_reg_wr_data[TRACE_ADDR_WIDTH-1:0]],
                trace_mem_low1[ctrl_reg_wr_data[TRACE_ADDR_WIDTH-1:0]],
                trace_mem_low0[ctrl_reg_wr_data[TRACE_ADDR_WIDTH-1:0]]
            };
        end else if (trace_rd_request) begin
            trace_read_data_reg <= 48'd0;
        end
    end

    if (rst) begin
        trace_read_data_reg <= 48'd0;
        trace_playback_data_reg <= 48'd0;
        trace_playback_valid_reg <= 1'b0;
    end
end

//Reset  antes de iniciar una prueba
task clear_test_state;
    begin
        running_reg <= 1'b0;
        done_reg <= 1'b0;
        start_pending_reg <= 1'b0;
        dut_reset_count_reg <= 3'd4;
        startup_ready_reg <= 1'b0;
        gap_counter_reg <= 32'd0;
        draining_reg <= 1'b0;
        drain_counter_reg <= 32'd0;
        trace_playback_index_reg <= 32'd0;
        current_mac_reg <= 48'd0;
        current_port_reg <= {{PORT_GLOBAL_COUNT-1{1'b0}}, 1'b1};
        input_valid_reg <= 1'b0;
        cycles_total_reg <= 32'd0;
        frames_generated_reg <= 32'd0;
        frames_accepted_by_cache_reg <= 32'd0;
        frames_blocked_by_cache_reg <= 32'd0;
        cache_miss_outputs_reg <= 32'd0;
        frames_forwarded_to_mac_reg <= 32'd0;
        frames_dropped_by_mac_backpressure_reg <= 32'd0;
        last_mac_generated_low_reg <= 32'd0;
    end
endtask

// Control principal del experimento y acceso a registros AXI-Lite
always @(posedge clk) begin
    ctrl_reg_wr_ack_reg <= 1'b0;
    ctrl_reg_rd_data_reg <= {REG_DATA_WIDTH{1'b0}};
    ctrl_reg_rd_ack_reg <= 1'b0;

    if (dut_reset_count_reg != 0) begin
        dut_reset_count_reg <= dut_reset_count_reg - 1;

        if (dut_reset_count_reg == 1 && start_pending_reg) begin
            running_reg <= 1'b1;
            done_reg <= 1'b0;
            start_pending_reg <= 1'b0;
        end
    end

    if (running_reg) begin
        cycles_total_reg <= cycles_total_reg + 1;

        if (!startup_ready_reg && dut_system_ready) begin
            startup_ready_reg <= 1'b1;
        end

        if (dut_valid_out) begin
            cache_miss_outputs_reg <= cache_miss_outputs_reg + 1;
        end

        if (output_hs) begin
            frames_forwarded_to_mac_reg <= frames_forwarded_to_mac_reg + 1;
        end

        if (output_drop) begin
            frames_dropped_by_mac_backpressure_reg <= frames_dropped_by_mac_backpressure_reg + 1;
        end

        if (input_valid_reg && !dut_ready_out) begin
            frames_blocked_by_cache_reg <= frames_blocked_by_cache_reg + 1;
        end

        if (input_hs) begin
            frames_accepted_by_cache_reg <= frames_accepted_by_cache_reg + 1;
            input_valid_reg <= 1'b0;

            if (frames_accepted_by_cache_reg + 1 >= target_frame_count) begin
                draining_reg <= 1'b1;
                drain_counter_reg <= 32'd0;
            end
        end

        if (trace_issue) begin
            input_valid_reg <= 1'b1;
            current_mac_reg <= trace_playback_data_reg;
            last_mac_generated_low_reg <= trace_playback_data_reg[31:0];
            frames_generated_reg <= frames_generated_reg + 1;
            trace_playback_index_reg <= trace_playback_index_reg + 1;
            gap_counter_reg <= frame_gap_cycles_reg;
        end else if (input_slot_available && gap_counter_reg != 0) begin
            gap_counter_reg <= gap_counter_reg - 1;
        end

        if (target_frame_count == 0) begin
            running_reg <= 1'b0;
            done_reg <= 1'b1;
        end

        if (draining_reg) begin
            drain_counter_reg <= drain_counter_reg + 1;

            if (drain_counter_reg + 1 >= DRAIN_CYCLES) begin
                running_reg <= 1'b0;
                done_reg <= 1'b1;
                draining_reg <= 1'b0;
            end
        end
    end else begin
        input_valid_reg <= 1'b0;
    end

    // Escritura de registros de configuracion y carga de trazas
    if (ctrl_reg_wr_en && !ctrl_reg_wr_ack_reg) begin
        ctrl_reg_wr_ack_reg <= 1'b1;

        case ({ctrl_reg_wr_addr >> 2, 2'b00})
            RBB+16'h00: begin
                if (ctrl_reg_wr_data[1]) begin
                    clear_test_state();
                end

                if (ctrl_reg_wr_data[0]) begin
                    clear_test_state();
                    done_reg <= 1'b0;
                    start_pending_reg <= 1'b1;
                end
            end
            RBB+16'h10: n_frames_target_reg <= ctrl_reg_wr_data;
            RBB+16'h14: trace_count_reg <= ctrl_reg_wr_data > TRACE_DEPTH_32 ? TRACE_DEPTH_32 : ctrl_reg_wr_data;
            RBB+16'h18: frame_gap_cycles_reg <= ctrl_reg_wr_data;
            RBB+16'h1c: begin end
            RBB+16'h20: begin end
            RBB+16'h64: trace_count_reg <= ctrl_reg_wr_data > TRACE_DEPTH_32 ? TRACE_DEPTH_32 : ctrl_reg_wr_data;
            RBB+16'h68: trace_write_addr_reg <= ctrl_reg_wr_data;
            RBB+16'h6c: trace_write_mac_low_reg <= ctrl_reg_wr_data;
            RBB+16'h70: begin
                trace_write_mac_high_reg <= ctrl_reg_wr_data[15:0];

                if (trace_write_addr_in_range) begin
                    if (trace_write_addr_reg + 1 < TRACE_DEPTH_32) begin
                        trace_write_addr_reg <= trace_write_addr_reg + 1;
                    end
                end
            end
            RBB+16'h74: begin
                trace_read_addr_reg <= ctrl_reg_wr_data;
            end
            default: ctrl_reg_wr_ack_reg <= 1'b0;
        endcase
    end

    // Lectura de registros de estado y metricas
    if (ctrl_reg_rd_en && !ctrl_reg_rd_ack_reg) begin
        ctrl_reg_rd_ack_reg <= 1'b1;

        case ({ctrl_reg_rd_addr >> 2, 2'b00})
            RBB+16'h00: ctrl_reg_rd_data_reg <= 32'h54464701;
            RBB+16'h04: ctrl_reg_rd_data_reg <= {30'd0, done_reg, running_reg};
            RBB+16'h10: ctrl_reg_rd_data_reg <= n_frames_target_reg;
            RBB+16'h14: ctrl_reg_rd_data_reg <= trace_count_reg;
            RBB+16'h18: ctrl_reg_rd_data_reg <= frame_gap_cycles_reg;
            RBB+16'h1c: ctrl_reg_rd_data_reg <= 32'd0;
            RBB+16'h20: ctrl_reg_rd_data_reg <= 32'd0;
            RBB+16'h24: ctrl_reg_rd_data_reg <= 32'd0;
            RBB+16'h30: ctrl_reg_rd_data_reg <= TABLE_DEPTH;
            RBB+16'h34: ctrl_reg_rd_data_reg <= TABLE_COUNT;
            RBB+16'h38: ctrl_reg_rd_data_reg <= PORT_GLOBAL_COUNT;
            RBB+16'h40: ctrl_reg_rd_data_reg <= cycles_total_reg;
            RBB+16'h44: ctrl_reg_rd_data_reg <= frames_generated_reg;
            RBB+16'h48: ctrl_reg_rd_data_reg <= frames_accepted_by_cache_reg;
            RBB+16'h4c: ctrl_reg_rd_data_reg <= frames_blocked_by_cache_reg;
            RBB+16'h50: ctrl_reg_rd_data_reg <= cache_miss_outputs_reg;
            RBB+16'h54: ctrl_reg_rd_data_reg <= frames_forwarded_to_mac_reg;
            RBB+16'h58: ctrl_reg_rd_data_reg <= frames_dropped_by_mac_backpressure_reg;
            RBB+16'h5c: ctrl_reg_rd_data_reg <= last_mac_generated_low_reg;
            RBB+16'h60: ctrl_reg_rd_data_reg <= TRACE_DEPTH_32;
            RBB+16'h64: ctrl_reg_rd_data_reg <= trace_count_reg;
            RBB+16'h68: ctrl_reg_rd_data_reg <= trace_write_addr_reg;
            RBB+16'h6c: ctrl_reg_rd_data_reg <= trace_write_mac_low_reg;
            RBB+16'h70: ctrl_reg_rd_data_reg <= {16'd0, trace_write_mac_high_reg};
            RBB+16'h74: ctrl_reg_rd_data_reg <= trace_read_addr_reg;
            RBB+16'h78: ctrl_reg_rd_data_reg <= trace_read_data_reg[31:0];
            RBB+16'h7c: ctrl_reg_rd_data_reg <= {16'd0, trace_read_data_reg[47:32]};
            RBB+16'h80: ctrl_reg_rd_data_reg <= dut_mac_table_write_requests;
            RBB+16'h84: ctrl_reg_rd_data_reg <= dut_mac_table_write_responses;
            RBB+16'h88: ctrl_reg_rd_data_reg <= dut_mac_table_write_success;
            RBB+16'h8c: ctrl_reg_rd_data_reg <= dut_mac_table_write_failed;
            RBB+16'h90: ctrl_reg_rd_data_reg <= dut_mac_table_learned_entries;
            default: ctrl_reg_rd_ack_reg <= 1'b0;
        endcase
    end

    // Reset global de la interfaz de test
    if (rst) begin
        ctrl_reg_wr_ack_reg <= 1'b0;
        ctrl_reg_rd_ack_reg <= 1'b0;
        n_frames_target_reg <= 32'd1000;
        trace_count_reg <= 32'd0;
        frame_gap_cycles_reg <= 32'd0;
        draining_reg <= 1'b0;
        drain_counter_reg <= 32'd0;
        trace_write_addr_reg <= 32'd0;
        trace_write_mac_low_reg <= 32'd0;
        trace_write_mac_high_reg <= 16'd0;
        trace_read_addr_reg <= 32'd0;
        clear_test_state();
        start_pending_reg <= 1'b0;
    end
end

endmodule

`resetall
