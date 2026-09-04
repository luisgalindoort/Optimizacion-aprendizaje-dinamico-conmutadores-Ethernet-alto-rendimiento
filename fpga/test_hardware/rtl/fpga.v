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
module fpga #
(
    // Cuckoo hashing table parameters
    parameter TABLE_DEPTH = 16384,
    parameter TABLE_COUNT = 4,
    parameter PORT_GLOBAL_COUNT = 8,
    parameter TRACE_DEPTH = 32768,
    parameter TABLE_KEY_WIDTH = 48,
    parameter TABLE_STORE_WIDTH = 16,
    parameter TABLE_LOOP_COUNT = 100,
    parameter TABLE_CONFIG_ENABLE = 1,
    parameter TABLE_REGISTER_STORE_STATE = 1,

    // Parameters for selecting insertion method
    // Select filter for initial insert step, 0: all tables; 1: prioritize free tables
    parameter TABLE_INSERTION_INITIAL_FILTER = 1,
    // Select strategy for initial insert step, 0: first table; 1: random; 2: round-robin; 3: minimum load
    parameter TABLE_INSERTION_INITIAL_STRATEGY = 0,
    // Select filter for reallocate step, 0: all tables; 1: prioritize free tables
    parameter TABLE_INSERTION_REALLOCATE_FILTER = 1,
    // Select strategy for reallocate step, 0: first table; 1: random; 2: round-robin; 3: minimum load
    parameter TABLE_INSERTION_REALLOCATE_STRATEGY = 0,

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

    // XFCP parameters
    parameter INTERMEDIATE_FREQUENCY = 100000000,
    parameter BAUD_RATE = 115200
)
(
    /*
     * Clock: 125MHz LVDS
     * Reset: Push button, active low
     */
    input  wire       clk_125mhz_p,
    input  wire       clk_125mhz_n,
    input  wire       reset,
    
    /*
     * GPIO
     */
    input  wire       btnu,
    input  wire       btnl,
    input  wire       btnd,
    input  wire       btnr,
    input  wire       btnc,
    input  wire [7:0] sw,
    output wire [7:0] led,

    /*
     * UART: 115200 bps, 8N1
     */
    input  wire       uart_rxd,
    output wire       uart_txd,
    input  wire       uart_rts,
    output wire       uart_cts

);

// Clock and reset
wire clk_125mhz_ibufg;
wire clk_125mhz_bufg;

// Internal 125 MHz clock
wire clk_125mhz_mmcm_out;
wire clk_125mhz_int;
wire rst_125mhz_int;

// Internal 156.25 MHz clock
wire clk_156mhz_int;
wire rst_156mhz_int;

wire mmcm_rst = reset;
wire mmcm_locked;
wire mmcm_clkfb;

// Intermediate clock
wire clk_core_mmcm_out;
wire clk_core_int;
wire rst_core_int;
wire rst_core;

IBUFGDS #(
   .DIFF_TERM("FALSE"),
   .IBUF_LOW_PWR("FALSE")   
)
clk_125mhz_ibufg_inst (
   .O   (clk_125mhz_ibufg),
   .I   (clk_125mhz_p),
   .IB  (clk_125mhz_n) 
);

BUFG
clk_125mhz_bufg_in_inst (
    .I(clk_125mhz_ibufg),
    .O(clk_125mhz_bufg)
);

// MMCM instance
// 125 MHz in, 125 MHz out
// PFD range: 10 MHz to 500 MHz
// VCO range: 800 MHz to 1600 MHz
// M = 8, D = 1 sets Fvco = 1000 MHz (in range)
// CLKOUT0 divides by 8 to get 125 MHz
// CLKOUT1 divides by 10 to get the 100 MHz core clock
MMCME4_BASE #(
    .BANDWIDTH("OPTIMIZED"),
    .CLKOUT0_DIVIDE_F(8),
    .CLKOUT0_DUTY_CYCLE(0.5),
    .CLKOUT0_PHASE(0),
    .CLKOUT1_DIVIDE(10),
    .CLKOUT1_DUTY_CYCLE(0.5),
    .CLKOUT1_PHASE(0),
    .CLKOUT2_DIVIDE(1),
    .CLKOUT2_DUTY_CYCLE(0.5),
    .CLKOUT2_PHASE(0),
    .CLKOUT3_DIVIDE(1),
    .CLKOUT3_DUTY_CYCLE(0.5),
    .CLKOUT3_PHASE(0),
    .CLKOUT4_DIVIDE(1),
    .CLKOUT4_DUTY_CYCLE(0.5),
    .CLKOUT4_PHASE(0),
    .CLKOUT5_DIVIDE(1),
    .CLKOUT5_DUTY_CYCLE(0.5),
    .CLKOUT5_PHASE(0),
    .CLKOUT6_DIVIDE(1),
    .CLKOUT6_DUTY_CYCLE(0.5),
    .CLKOUT6_PHASE(0),
    .CLKFBOUT_MULT_F(8),
    .CLKFBOUT_PHASE(0),
    .DIVCLK_DIVIDE(1),
    .REF_JITTER1(0.010),
    .CLKIN1_PERIOD(8.0),
    .STARTUP_WAIT("FALSE"),
    .CLKOUT4_CASCADE("FALSE")
)
clk_mmcm_inst (
    .CLKIN1(clk_125mhz_bufg),
    .CLKFBIN(mmcm_clkfb),
    .RST(mmcm_rst),
    .PWRDWN(1'b0),
    .CLKOUT0(clk_125mhz_mmcm_out),
    .CLKOUT0B(),
    .CLKOUT1(clk_core_mmcm_out),
    .CLKOUT1B(),
    .CLKOUT2(),
    .CLKOUT2B(),
    .CLKOUT3(),
    .CLKOUT3B(),
    .CLKOUT4(),
    .CLKOUT5(),
    .CLKOUT6(),
    .CLKFBOUT(mmcm_clkfb),
    .CLKFBOUTB(),
    .LOCKED(mmcm_locked)
);

BUFG
clk_125mhz_bufg_inst (
    .I(clk_125mhz_mmcm_out),
    .O(clk_125mhz_int)
);

sync_reset #(
    .N(4)
)
sync_reset_125mhz_inst (
    .clk(clk_125mhz_int),
    .rst(~mmcm_locked),
    .out(rst_125mhz_int)
);

// acconditionate clock and reset
BUFG
clk_core_bufg_inst (
    .I(clk_core_mmcm_out),
    .O(clk_core_int)
);

sync_reset #(
    .N(4)
)
sync_reset_core_inst (
    .clk(clk_core_int),
    .rst(~mmcm_locked),
    .out(rst_core_int)
);

// extra registers for rst_core signal
(* shreg_extract = "no" *)
reg rst_core_reg_1 = 1'b1;
(* shreg_extract = "no" *)
reg rst_core_reg_2 = 1'b1;
(* shreg_extract = "no" *)
reg rst_core_reg_3 = 1'b1;

always @(posedge clk_core_int) begin
    rst_core_reg_1 <= rst_core_int;
    rst_core_reg_2 <= rst_core_reg_1;
    rst_core_reg_3 <= rst_core_reg_2;
end

assign rst_core = rst_core_reg_3;

// uart synchronization with if clock
wire uart_rxd_int;
wire uart_rts_int;

sync_signal #(
    .WIDTH(2),
    .N(2)
)
sync_signal_inst (
    .clk(clk_core_int),
    .in({uart_rxd, uart_rts}),
    .out({uart_rxd_int, uart_rts_int})
);

// Configuration interface handling: from UART bus to AXIL interface using XFCP protocol
localparam AXIL_DATA_WIDTH = 32;
localparam AXIL_ADDR_WIDTH = 16;
localparam AXIL_STRB_WIDTH = (AXIL_DATA_WIDTH/8);

// Interface UART
wire [7:0] xfcp_uart_interface_down_tdata;
wire xfcp_uart_interface_down_tvalid;
wire xfcp_uart_interface_down_tready;
wire xfcp_uart_interface_down_tlast;
wire xfcp_uart_interface_down_tuser;

wire [7:0] xfcp_uart_interface_up_tdata;
wire xfcp_uart_interface_up_tvalid;
wire xfcp_uart_interface_up_tready;
wire xfcp_uart_interface_up_tlast;
wire xfcp_uart_interface_up_tuser;

assign uart_cts = 1'b1;

xfcp_interface_uart
xfcp_interface_uart_inst (
    .clk(clk_core_int),
    .rst(rst_core),
    .uart_rxd(uart_rxd_int),
    .uart_txd(uart_txd),
    .down_xfcp_in_tdata(xfcp_uart_interface_up_tdata),
    .down_xfcp_in_tvalid(xfcp_uart_interface_up_tvalid),
    .down_xfcp_in_tready(xfcp_uart_interface_up_tready),
    .down_xfcp_in_tlast(xfcp_uart_interface_up_tlast),
    .down_xfcp_in_tuser(xfcp_uart_interface_up_tuser),
    .down_xfcp_out_tdata(xfcp_uart_interface_down_tdata),
    .down_xfcp_out_tvalid(xfcp_uart_interface_down_tvalid),
    .down_xfcp_out_tready(xfcp_uart_interface_down_tready),
    .down_xfcp_out_tlast(xfcp_uart_interface_down_tlast),
    .down_xfcp_out_tuser(xfcp_uart_interface_down_tuser),
    .prescale(INTERMEDIATE_FREQUENCY/(BAUD_RATE*8))
);

// AXIL master coming from XFCP
wire [AXIL_ADDR_WIDTH-1:0] axil_xfcp_awaddr;
wire [2:0]                 axil_xfcp_awprot;
wire                       axil_xfcp_awvalid;
wire                       axil_xfcp_awready;
wire [AXIL_DATA_WIDTH-1:0] axil_xfcp_wdata;
wire [4-1:0]               axil_xfcp_wstrb;
wire                       axil_xfcp_wvalid;
wire                       axil_xfcp_wready;
wire [1:0]                 axil_xfcp_bresp;
wire                       axil_xfcp_bvalid;
wire                       axil_xfcp_bready;
wire [AXIL_ADDR_WIDTH-1:0] axil_xfcp_araddr;
wire [2:0]                 axil_xfcp_arprot;
wire                       axil_xfcp_arvalid;
wire                       axil_xfcp_arready;
wire [AXIL_DATA_WIDTH-1:0] axil_xfcp_rdata;
wire [1:0]                 axil_xfcp_rresp;
wire                       axil_xfcp_rvalid;
wire                       axil_xfcp_rready;

xfcp_mod_axil #(
    .XFCP_ID_STR("XFCP AXIL Master"),
    .COUNT_SIZE(16),
    .DATA_WIDTH(AXIL_DATA_WIDTH),
    .ADDR_WIDTH(AXIL_ADDR_WIDTH),
    .STRB_WIDTH(4)
)
xfcp_mod_axil_inst (
    .clk(clk_core_int),
    .rst(rst_core),
    .up_xfcp_in_tdata(xfcp_uart_interface_down_tdata),
    .up_xfcp_in_tvalid(xfcp_uart_interface_down_tvalid),
    .up_xfcp_in_tready(xfcp_uart_interface_down_tready),
    .up_xfcp_in_tlast(xfcp_uart_interface_down_tlast),
    .up_xfcp_in_tuser(xfcp_uart_interface_down_tuser),
    .up_xfcp_out_tdata(xfcp_uart_interface_up_tdata),
    .up_xfcp_out_tvalid(xfcp_uart_interface_up_tvalid),
    .up_xfcp_out_tready(xfcp_uart_interface_up_tready),
    .up_xfcp_out_tlast(xfcp_uart_interface_up_tlast),
    .up_xfcp_out_tuser(xfcp_uart_interface_up_tuser),
    .m_axil_awaddr(axil_xfcp_awaddr),
    .m_axil_awprot(axil_xfcp_awprot),
    .m_axil_awvalid(axil_xfcp_awvalid),
    .m_axil_awready(axil_xfcp_awready),
    .m_axil_wdata(axil_xfcp_wdata),
    .m_axil_wstrb(axil_xfcp_wstrb),
    .m_axil_wvalid(axil_xfcp_wvalid),
    .m_axil_wready(axil_xfcp_wready),
    .m_axil_bresp(axil_xfcp_bresp),
    .m_axil_bvalid(axil_xfcp_bvalid),
    .m_axil_bready(axil_xfcp_bready),
    .m_axil_araddr(axil_xfcp_araddr),
    .m_axil_arprot(axil_xfcp_arprot),
    .m_axil_arvalid(axil_xfcp_arvalid),
    .m_axil_arready(axil_xfcp_arready),
    .m_axil_rdata(axil_xfcp_rdata),
    .m_axil_rresp(axil_xfcp_rresp),
    .m_axil_rvalid(axil_xfcp_rvalid),
    .m_axil_rready(axil_xfcp_rready)
);

cache_core #(
    .TABLE_DEPTH(TABLE_DEPTH),
    .TABLE_COUNT(TABLE_COUNT),
    .PORT_GLOBAL_COUNT(PORT_GLOBAL_COUNT),
    .TRACE_DEPTH(TRACE_DEPTH),
    .TABLE_LOOP_COUNT(TABLE_LOOP_COUNT),
    .TABLE_CONFIG_ENABLE(TABLE_CONFIG_ENABLE),
    .TABLE_REGISTER_STORE_STATE(TABLE_REGISTER_STORE_STATE),
    .TABLE_INSERTION_INITIAL_FILTER(TABLE_INSERTION_INITIAL_FILTER),
    .TABLE_INSERTION_INITIAL_STRATEGY(TABLE_INSERTION_INITIAL_STRATEGY),
    .TABLE_INSERTION_REALLOCATE_FILTER(TABLE_INSERTION_REALLOCATE_FILTER),
    .TABLE_INSERTION_REALLOCATE_STRATEGY(TABLE_INSERTION_REALLOCATE_STRATEGY),
    .TABLE_LFSR_WIDTH(TABLE_LFSR_WIDTH),
    .TABLE_LFSR_POLY(TABLE_LFSR_POLY),
    .TABLE_LFSR_STATE_IN(TABLE_LFSR_STATE_IN),
    .TABLE_LFSR_CONFIG(TABLE_LFSR_CONFIG),
    .TABLE_LFSR_FEED_FORWARD(TABLE_LFSR_FEED_FORWARD),
    .TABLE_LFSR_REVERSE(TABLE_LFSR_REVERSE),
    .TABLE_LFSR_STYLE(TABLE_LFSR_STYLE),
    .AXIL_DATA_WIDTH(AXIL_DATA_WIDTH),
    .AXIL_ADDR_WIDTH(AXIL_ADDR_WIDTH),
    .AXIL_STRB_WIDTH(AXIL_STRB_WIDTH)
)
core_inst (
    /*
     * Clock: core
     * Synchronous reset
     */
    .clk(clk_core_int),
    .rst(rst_core),

    /*
     * AXI-Lite slave interface
     */
    .s_axil_awaddr(axil_xfcp_awaddr),
    .s_axil_awprot(axil_xfcp_awprot),
    .s_axil_awvalid(axil_xfcp_awvalid),
    .s_axil_awready(axil_xfcp_awready),
    .s_axil_wdata(axil_xfcp_wdata),
    .s_axil_wstrb(axil_xfcp_wstrb),
    .s_axil_wvalid(axil_xfcp_wvalid),
    .s_axil_wready(axil_xfcp_wready),
    .s_axil_bresp(axil_xfcp_bresp),
    .s_axil_bvalid(axil_xfcp_bvalid),
    .s_axil_bready(axil_xfcp_bready),
    .s_axil_araddr(axil_xfcp_araddr),
    .s_axil_arprot(axil_xfcp_arprot),
    .s_axil_arvalid(axil_xfcp_arvalid),
    .s_axil_arready(axil_xfcp_arready),
    .s_axil_rdata(axil_xfcp_rdata),
    .s_axil_rresp(axil_xfcp_rresp),
    .s_axil_rvalid(axil_xfcp_rvalid),
    .s_axil_rready(axil_xfcp_rready)
);
endmodule

`resetall
