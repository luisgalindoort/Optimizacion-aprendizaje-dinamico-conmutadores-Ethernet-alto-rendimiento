/*

Copyright (c) 2023-2024 Carlos Megías Núñez

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

/*
 * Modified version of Alex Forencich's AXI4-Stream FIFO
 * New FRAME_FIFO mode in read interface
 */
module switch_simple_fifo #
(
    // FIFO depth
    // Rounded up to nearest power of 2 cycles
    parameter DEPTH = 128,
    // Width of the data words in bits
    parameter DATA_WIDTH = $clog2(DEPTH),
    // Fill at initialization
    parameter FILL_INIT = 0,
    // Fill at initialization handle enable - internal processing of wr_init
    // Requires FILL_INIT set
    parameter FILL_INIT_HANDLE = FILL_INIT,
    // Frame FIFO mode - operate on frames instead of cycles in write port
    parameter FRAME_FIFO_WR = 0,
    // Frame FIFO mode - operate on frames instead of cycles in read port
    parameter FRAME_FIFO_RD = 0,
    // Drop frames larger than FIFO
    // Requires FRAME_FIFO set
    parameter DROP_OVERSIZE_FRAME = FRAME_FIFO_RD || FRAME_FIFO_WR,
    // Drop frames marked bad
    // Requires FRAME_FIFO_WR or FRAME_FIFO_RD, and DROP_OVERSIZE_FRAME set
    parameter DROP_BAD_FRAME = 0,
    // Drop incoming frames when full
    // When set, wr_ready or rd_valid is always asserted
    // Requires FRAME_FIFO_WR or FRAME_FIFO_RD, and DROP_OVERSIZE_FRAME set
    parameter DROP_WHEN_FULL = 0,
    // Mark incoming frames as bad frames when full
    // When set, rd_enable should behave as if rd_valid is always asserted
    // Requires FRAME_FIFO_WR and FRAME_FIFO_RD to be clear
    parameter MARK_WHEN_FULL = 0
)
(
    input  wire                   clk,
    input  wire                   rst,
    
    /*
     * Write interface
     */
    input  wire [DATA_WIDTH-1:0]  wr_data,
    input  wire                   wr_enable,
    output wire                   wr_ready,
    input  wire                   wr_sof,
    input  wire                   wr_eof,
    input  wire                   wr_drop,
    output wire                   wr_init,

    /*
     * Read interface
     */
    output wire [DATA_WIDTH-1:0]  rd_data,
    output wire                   rd_valid,
    output wire                   rd_ready,
    input  wire                   rd_enable,
    input  wire                   rd_sof,
    input  wire                   rd_eof,
    input  wire                   rd_drop,
    output wire                   rd_mark,

    /*
     * Status output
     */
    output wire                   empty,
    output wire                   full,
    output wire [$clog2(DEPTH):0] status_depth,
    output wire [$clog2(DEPTH):0] status_depth_commit,
    output wire                   status_overflow,
    output wire                   status_bad_frame,
    output wire                   status_good_frame,
    output wire                   status_mark_frame
);

// Width of the address (write and read pointers) bus in width
parameter ADDR_WIDTH = $clog2(DEPTH);

// check configuration
initial begin
    if (FRAME_FIFO_WR && FRAME_FIFO_RD) begin
        $error("Error: FRAME_FIFO_WR and FRAME_FIFO_RD are not compatible (instance %m)");
        $finish;
    end

    if (FILL_INIT_HANDLE && !FILL_INIT) begin
        $error("Error: FILL_INIT_HANDLE set requires FILL_INIT set (instance %m)");
        $finish;
    end

    if (FRAME_FIFO_WR && FILL_INIT) begin
        $error("Error: FRAME_FIFO_WR and FILL_INIT are not compatible (instance %m)");
        $finish;
    end

    if (DROP_OVERSIZE_FRAME && !(FRAME_FIFO_WR || FRAME_FIFO_RD)) begin
        $error("Error: DROP_OVERSIZE_FRAME set requires FRAME_FIFO_WR or FRAME_FIFO_RD set (instance %m)");
        $finish;
    end

    if (DROP_BAD_FRAME && !((FRAME_FIFO_WR || FRAME_FIFO_RD) && DROP_OVERSIZE_FRAME)) begin
        $error("Error: DROP_BAD_FRAME set requires FRAME_FIFO_WR or FRAME_FIFO_RD and DROP_OVERSIZE_FRAME set (instance %m)");
        $finish;
    end

    if (DROP_WHEN_FULL && !((FRAME_FIFO_WR || FRAME_FIFO_RD) && DROP_OVERSIZE_FRAME)) begin
        $error("Error: DROP_WHEN_FULL set requires FRAME_FIFO_WR or FRAME_FIFO_RD and DROP_OVERSIZE_FRAME set (instance %m)");
        $finish;
    end

    if (MARK_WHEN_FULL && (FRAME_FIFO_WR || FRAME_FIFO_RD)) begin
        $error("Error: MARK_WHEN_FULL is not compatible with FRAME_FIFO (instance %m)");
        $finish;
    end
end

// instantiate RAM for FIFO
(* ramstyle = "no_rw_check" *)
reg [DATA_WIDTH-1:0] mem[(2**ADDR_WIDTH)-1:0];

// auxiliar registers and wires
reg [DATA_WIDTH-1:0] rd_data_reg;
reg [DATA_WIDTH-1:0] rd_data_commit_reg;

// register for reading shortcircuit
reg rd_valid_reg = 1'b0;

reg  [ADDR_WIDTH:0] wr_ptr_reg = 0;
reg  [ADDR_WIDTH:0] wr_ptr_commit_reg = 0;
reg  [ADDR_WIDTH:0] rd_ptr_reg = 0;
wire [ADDR_WIDTH:0] rd_ptr_adjust_reg = $unsigned(rd_ptr_reg-rd_valid_reg);
reg  [ADDR_WIDTH:0] rd_ptr_commit_reg = 0;
wire [ADDR_WIDTH:0] rd_ptr_commit_adjust_reg =  $unsigned(rd_ptr_commit_reg-1);

reg fill = 1'b1;

// full when first MSB different but rest same
assign full = wr_ptr_reg == (rd_ptr_commit_reg ^ {1'b1, {ADDR_WIDTH{1'b0}}});
// empty when pointers match exactly
assign empty = (wr_ptr_commit_reg == rd_ptr_reg) ? !rd_valid_reg : 1'b0;
// empty signal for DEPTH buffer (without +1 extra read register)
wire empty_buffer = wr_ptr_commit_reg == rd_ptr_reg;
// overflow within packet
wire empty_rd = rd_ptr_reg == (rd_ptr_commit_adjust_reg ^ {1'b1, {ADDR_WIDTH{1'b0}}});
wire full_wr = wr_ptr_reg == (wr_ptr_commit_reg ^ {1'b1, {ADDR_WIDTH{1'b0}}});

reg drop_frame_reg = 1'b0;
reg mark_frame_reg = 1'b0;
reg send_frame_reg = 1'b0;
reg [ADDR_WIDTH:0] depth_reg = 0;
reg [ADDR_WIDTH:0] depth_commit_reg = 0;
reg overflow_reg = 1'b0;
reg bad_frame_reg = 1'b0;
reg good_frame_reg = 1'b0;

assign wr_ready = FRAME_FIFO_WR ? (!full || (full_wr && DROP_OVERSIZE_FRAME) || DROP_WHEN_FULL) : (FILL_INIT ? !fill && !full : !full);

// indicate if fill has been completed
assign wr_init = FILL_INIT ? !fill: 1'b1;

// map output read
assign rd_data = rd_data_reg;
// mark signal for dropping
// assign rd_mark = MARK_WHEN_FULL ? mark_frame_reg : 1'b0;
assign rd_mark = MARK_WHEN_FULL ? (((rd_eof && rd_enable) || (!rd_enable && !drop_frame_reg)) && rd_valid && mark_frame_reg) : (FRAME_FIFO_RD ? rd_enable && rd_eof && drop_frame_reg : 1'b0);
// assign rd_mark = MARK_WHEN_FULL ? (((rd_eof && rd_enable) || (!rd_enable && !drop_frame_reg)) && rd_valid && mark_frame_reg) : (FRAME_FIFO_RD ? rd_enable && rd_eof && ((empty_rd && DROP_OVERSIZE_FRAME) || drop_frame_reg) : 1'b0);
// assign rd_mark = MARK_WHEN_FULL ? (((rd_eof && rd_enable) || (!rd_enable && !drop_frame_reg)) && rd_valid && mark_frame_reg) : (FRAME_FIFO_RD ? rd_enable && (rd_valid != rd_ready) : 1'b0);

// valid data
generate
    if (FRAME_FIFO_RD) begin
        assign rd_valid = FILL_INIT_HANDLE ? rd_valid_reg && !drop_frame_reg && wr_init : rd_valid_reg && !drop_frame_reg;
        // assign rd_valid = FILL_INIT_HANDLE ? ((!empty && rd_valid_reg) || (empty_rd && DROP_OVERSIZE_FRAME)) && wr_init : rd_valid_reg && !drop_frame_reg;
        // assign rd_valid = FILL_INIT_HANDLE ? ((!empty && rd_valid_reg) || (empty_rd && DROP_OVERSIZE_FRAME)) && wr_init : rd_valid_reg && !(empty_rd && DROP_OVERSIZE_FRAME);
    end else if (MARK_WHEN_FULL) begin
        assign rd_valid = FILL_INIT_HANDLE ? rd_valid_reg && wr_init && ((!mark_frame_reg && !drop_frame_reg) || (rd_eof && mark_frame_reg) || (!rd_enable && mark_frame_reg && !drop_frame_reg)) : rd_valid_reg && ((!mark_frame_reg && !drop_frame_reg) || (rd_eof && mark_frame_reg) || (!rd_enable && mark_frame_reg && !drop_frame_reg));
    end else begin
        assign rd_valid = FILL_INIT_HANDLE ? rd_valid_reg && wr_init : rd_valid_reg;
    end
endgenerate

assign rd_ready = FRAME_FIFO_RD ? rd_valid || (empty_rd && DROP_OVERSIZE_FRAME) || DROP_WHEN_FULL : (rd_valid || MARK_WHEN_FULL);

// status depth signal
assign status_depth = depth_reg;
assign status_depth_commit = depth_commit_reg;
assign status_overflow = overflow_reg;
assign status_bad_frame = bad_frame_reg;
assign status_good_frame = good_frame_reg;
assign status_mark_frame = mark_frame_reg;

generate
    if (FILL_INIT) begin
        // Write logic
        always @(posedge clk) begin
            if (fill == 1'b0) begin
                // check if something to write
                if (wr_ready && wr_enable) begin
                    // store data
                    mem[wr_ptr_reg[ADDR_WIDTH-1:0]] <= wr_data;
                    wr_ptr_reg <= wr_ptr_reg + 1;
                    wr_ptr_commit_reg <= wr_ptr_reg + 1;
                end else begin
                    wr_ptr_reg <= wr_ptr_reg;
                    wr_ptr_commit_reg <= wr_ptr_commit_reg;
                end

            end else begin
                if (wr_ptr_reg < 2**ADDR_WIDTH) begin
                    mem[wr_ptr_reg[ADDR_WIDTH-1:0]] <= wr_ptr_reg;
                    wr_ptr_reg <= wr_ptr_reg + 1;
                    wr_ptr_commit_reg <= wr_ptr_reg + 1;                    
                end else begin
                    // wr_ptr_reg <= wr_ptr_reg + 1;
                    fill <= 1'b0;
                end
            end

            if (rst) begin
                fill <= 1'b1;
                wr_ptr_reg <= 0;
                wr_ptr_commit_reg <= 0;
            end
        end
    end else begin
        // Write logic
        always @(posedge clk) begin
            if (FRAME_FIFO_WR) begin
                overflow_reg <= 1'b0;
                bad_frame_reg <= 1'b0;
                good_frame_reg <= 1'b0;

                // frame FIFO mode
                if (wr_ready && wr_enable) begin
                    // transfer in
                    if ((full && DROP_WHEN_FULL) || (full_wr && DROP_OVERSIZE_FRAME) || drop_frame_reg) begin
                        // packet overflow, or currently dropping frame
                        // drop frame
                        drop_frame_reg <= 1'b1;
                        if (wr_eof) begin
                            wr_ptr_reg <= wr_ptr_commit_reg;
                            drop_frame_reg <= 1'b0;
                            overflow_reg <= 1'b1;
                        end
                    end else begin
                        mem[wr_ptr_reg[ADDR_WIDTH-1:0]] <= wr_data;
                        wr_ptr_reg <= wr_ptr_reg + 1;
                        if (wr_eof || (!DROP_OVERSIZE_FRAME && (full_wr || send_frame_reg))) begin
                            // end of frame or send frame
                            send_frame_reg <= !wr_eof;
                            if (wr_eof && DROP_BAD_FRAME && wr_drop) begin
                                // bad packet, reset write pointer
                                wr_ptr_reg <= wr_ptr_commit_reg;
                                bad_frame_reg <= 1'b1;
                            end else begin
                                // good packet or packet overflow, update write pointer
                                wr_ptr_commit_reg <= wr_ptr_reg + 1;
                                good_frame_reg <= wr_eof;
                            end
                        end
                    end
                end else if (full_wr && !DROP_OVERSIZE_FRAME) begin
                // end else if (wr_enable && full_wr && !DROP_OVERSIZE_FRAME) begin
                    // data valid with packet overflow
                    // update write pointer
                    send_frame_reg <= 1'b1;
                    wr_ptr_commit_reg <= wr_ptr_reg;
                end

            end else begin
                // normal FIFO mode
                if (wr_ready && wr_enable) begin
                    // store data
                    mem[wr_ptr_reg[ADDR_WIDTH-1:0]] <= wr_data;
                    wr_ptr_reg <= wr_ptr_reg + 1;
                    wr_ptr_commit_reg <= wr_ptr_reg + 1;
                end else begin
                    wr_ptr_reg <= wr_ptr_reg;
                    wr_ptr_commit_reg <= wr_ptr_commit_reg;
                end
            end

            if (!(FRAME_FIFO_RD || MARK_WHEN_FULL)) begin
                if (rst) begin
                    drop_frame_reg <= 1'b0;
                    send_frame_reg <= 1'b0;
                    overflow_reg <= 1'b0;
                    bad_frame_reg <= 1'b0;
                    good_frame_reg <= 1'b0;
                end
            end

            if (rst) begin
                wr_ptr_reg <= 0;
                wr_ptr_commit_reg <= 0;
            end
        end
    end
endgenerate

// Status
always @(posedge clk) begin
    depth_reg <= wr_ptr_reg - rd_ptr_reg;
    if (FRAME_FIFO_WR) begin 
        depth_commit_reg <= wr_ptr_commit_reg - rd_ptr_reg;
    end else begin
        depth_commit_reg <= wr_ptr_reg - rd_ptr_commit_reg;
    end
end

reg rd_data_commit_valid_reg = 1'b0;

// Read logic
always @(posedge clk) begin
    if (FRAME_FIFO_RD) begin
        overflow_reg <= 1'b0;
        bad_frame_reg <= 1'b0;
        good_frame_reg <= 1'b0;

        if (!rd_valid_reg && !empty_buffer) begin
            // read whenever it can: if nothing valid in read register and not empty buffer
            rd_valid_reg <= 1'b1;
            rd_data_reg <= mem[rd_ptr_reg[ADDR_WIDTH-1:0]];
            rd_ptr_reg <= rd_ptr_reg + 1;

            if (!rd_data_commit_valid_reg) begin
                // update commit pointer and data with current at starting new frame if previous frame was valid
                rd_data_commit_valid_reg <= 1'b1;
                rd_data_commit_reg <= mem[rd_ptr_reg[ADDR_WIDTH-1:0]];
                rd_ptr_commit_reg <= rd_ptr_reg + 1;
            end
        end

        // frame FIFO mode
        if (rd_enable && rd_ready) begin
            if ((empty && DROP_WHEN_FULL) || (empty_rd && DROP_OVERSIZE_FRAME) || drop_frame_reg || !rd_valid) begin
                // current not valid, dropping frame or empty conditions
                // set rd_valid_reg to 0
                rd_valid_reg <= 1'b0;

                // packet overflow, or currently dropping frame
                // drop frame
                drop_frame_reg <= 1'b1;

                if (rd_eof) begin
                    rd_valid_reg <= rd_data_commit_valid_reg;
                    rd_data_reg <= rd_data_commit_reg;
                    rd_ptr_reg <= rd_ptr_commit_reg;
                    drop_frame_reg <= 1'b0;
                    overflow_reg <= 1'b1;
                end
            end else if (rd_valid) begin
                // read if possible
                if (!empty_buffer) begin
                    rd_valid_reg <= 1'b1;
                    rd_data_reg <= mem[rd_ptr_reg[ADDR_WIDTH-1:0]];
                    rd_ptr_reg <= rd_ptr_reg + 1;
                end else begin
                    rd_valid_reg <= 1'b0;
                end

                if (rd_eof || (!DROP_OVERSIZE_FRAME && (empty_rd || send_frame_reg))) begin
                    // end of frame or send frame
                    send_frame_reg <= !rd_eof;
                    if (rd_eof && DROP_BAD_FRAME && rd_drop) begin
                        // bad frame, reset read pointer, reset data
                        rd_valid_reg <= 1'b1;
                        rd_data_reg <= rd_data_commit_reg;
                        rd_ptr_reg <= rd_ptr_commit_reg;

                        bad_frame_reg <= 1'b1;
                    end else begin
                        // good packet or packet overflow, update read pointer
                        if (!empty_buffer) begin
                            rd_data_commit_valid_reg <= 1'b1;
                            rd_data_commit_reg <= mem[rd_ptr_reg[ADDR_WIDTH-1:0]];
                            rd_ptr_commit_reg <= rd_ptr_reg + 1;
                        end else begin
                            rd_data_commit_valid_reg <= 1'b0;
                            rd_data_commit_reg <= rd_data_reg;
                            rd_ptr_commit_reg <= rd_ptr_reg;
                        end

                        good_frame_reg <= rd_eof;
                    end
                end
            end        
        end else if (rd_enable && empty_rd && !DROP_OVERSIZE_FRAME) begin
            // data valid with packet overflow
            // update read pointer
            send_frame_reg <= 1'b1;
            rd_ptr_commit_reg <= rd_ptr_reg;
            rd_data_commit_reg <= rd_data_reg;
        end
    end else begin
        if ((!rd_valid_reg || (rd_enable && rd_valid)) && !empty_buffer) begin
            // read whenever it can: if nothing valid in read register and not empty buffer
            rd_valid_reg <= 1'b1;
            rd_data_reg <= mem[rd_ptr_reg[ADDR_WIDTH-1:0]];
            rd_ptr_reg <= rd_ptr_reg + 1;
            rd_ptr_commit_reg <= rd_ptr_reg + 1;
        end else if (rd_enable && rd_valid && empty_buffer) begin
            rd_valid_reg <= 1'b0;
        end
    
        // normal FIFO mode
        if (MARK_WHEN_FULL) begin
            overflow_reg <= 1'b0;
            bad_frame_reg <= 1'b0;
            good_frame_reg <= 1'b0;

            if (rd_enable) begin
                if (drop_frame_reg) begin
                    // currently dropping frame
                    if (rd_eof) begin
                        // end of frame
                        if (rd_valid) begin
                            // terminate marked frame
                            mark_frame_reg <= 1'b0;
                        end
                        // end of frame, clear drop flag
                        drop_frame_reg <= 1'b0;
                        overflow_reg <= 1'b1;
                    end
                end else if (!rd_valid || mark_frame_reg) begin
                    // empty or marking frame
                    // drop frame; mark frame
                    drop_frame_reg <= 1'b1;
                    mark_frame_reg <= mark_frame_reg || !rd_sof;
                    if ((rd_eof && rd_valid) || (rd_eof && rd_sof && !mark_frame_reg)) begin
                        mark_frame_reg <= 1'b0;
                        drop_frame_reg <= 1'b0;
                        overflow_reg <= 1'b1;
                    end

                    if (rd_eof) begin
                        drop_frame_reg <= 1'b0;
                        overflow_reg <= 1'b1;
                    end
                end
            end else if (rd_valid && !drop_frame_reg && mark_frame_reg) begin
                // terminate marked frame
                mark_frame_reg <= 1'b0;

                // read current pointer (used for marking the frame)
                if (!empty_buffer) begin
                    rd_valid_reg <= 1'b1;
                    rd_data_reg <= mem[rd_ptr_reg[ADDR_WIDTH-1:0]];
                    rd_ptr_reg <= rd_ptr_reg + 1;
                    rd_ptr_commit_reg <= rd_ptr_reg + 1;
                end else begin
                    rd_valid_reg <= 1'b0;
                end
            end
        end
    end

    if (FRAME_FIFO_RD || MARK_WHEN_FULL) begin
        if (rst) begin
            drop_frame_reg <= 1'b0;
            mark_frame_reg <= 1'b0;
            send_frame_reg <= 1'b0;
            overflow_reg <= 1'b0;
            bad_frame_reg <= 1'b0;
            good_frame_reg <= 1'b0;
        end
    end
    if (rst) begin
        rd_ptr_reg <= {ADDR_WIDTH+1{1'b0}};
        rd_ptr_commit_reg <= {ADDR_WIDTH+1{1'b0}};
        rd_valid_reg <= 1'b0;
        rd_data_commit_valid_reg <= 1'b0;
    end
end

endmodule