// A queue between MiST data_io and the PC/XT ROM loader.
//
// data_io sends a ROM file word by word at the rate of the controller's SPI
// and has no wait input; the machine's rom_loader (rtl/mem/rom_loader.sv)
// raises ioctl_wait until the CPU has given up the bus and while each word is
// written to the SDRAM, as MiSTer's hps_io allows. The words go through this
// queue: the download seen by the loader begins with data_io's and ends when
// the last word has been taken, and a word is offered only while the loader
// does not wait. One word, never two in consecutive clocks: the loader's wait
// is registered.
//
// 512 entries (one block RAM): the file offset is kept in 19 bits, enough
// for every slot of the loader (64 KiB plus the 512-byte cartridge header);
// a later offset is passed as one outside every slot.
`timescale 1ns/1ps
module zxtres_ioctl_fifo #(
    parameter int unsigned DEPTH_BITS = 9
) (
    input  logic        clk,
    input  logic        reset,

    // from data_io
    input  logic        in_download,
    input  logic [7:0]  in_index,
    input  logic        in_wr,
    input  logic [26:0] in_addr,
    input  logic [15:0] in_data,
    output logic        overflow,      // a word was lost (sticky until reset)

    // to the ROM loader
    output logic        out_download,
    output logic [7:0]  out_index,
    output logic        out_wr,
    output logic [24:0] out_addr,
    output logic [15:0] out_data,
    input  logic        out_wait
);
    localparam int unsigned DEPTH = 1 << DEPTH_BITS;

    logic [34:0] mem [0:DEPTH-1];
    logic [DEPTH_BITS:0] wptr = '0, rptr = '0;
    wire  empty = wptr == rptr;
    wire  full  = (wptr[DEPTH_BITS] != rptr[DEPTH_BITS]) &&
                  (wptr[DEPTH_BITS-1:0] == rptr[DEPTH_BITS-1:0]);

    wire [18:0] in_offset = (in_addr[26:18] != 9'd0) ? 19'h7FFFF : {1'b0, in_addr[17:0]};

    always_ff @(posedge clk) begin
        if (in_wr && !full)
            mem[wptr[DEPTH_BITS-1:0]] <= {in_offset, in_data};
    end

    logic [34:0] head;
    logic        head_valid;            // head holds the entry at rptr - 1
    logic        gap;                   // the clock after a word: the wait is not seen yet
    logic        in_download_q;
    logic [1:0]  dl_age;                // clocks since out_download rose, to 3: the
                                        // loader has registered it and its wait

    always_ff @(posedge clk) begin
        out_wr <= 1'b0;
        if (reset) begin
            wptr <= '0;
            rptr <= '0;
            head_valid <= 1'b0;
            gap <= 1'b0;
            overflow <= 1'b0;
            out_download <= 1'b0;
            out_index <= 8'h00;
            in_download_q <= 1'b0;
            dl_age <= 2'd0;
        end else begin
            if (!out_download)
                dl_age <= 2'd0;
            else if (dl_age != 2'd3)
                dl_age <= dl_age + 2'd1;
            in_download_q <= in_download;
            if (in_download && !in_download_q) begin
                out_index <= in_index;
                out_download <= 1'b1;
            end
            if (in_wr) begin
                if (full) overflow <= 1'b1;
                else wptr <= wptr + 1'b1;
            end

            // Read a new head from the memory.
            if (!head_valid && !empty) begin
                head <= mem[rptr[DEPTH_BITS-1:0]];
                rptr <= rptr + 1'b1;
                head_valid <= 1'b1;
            end

            gap <= 1'b0;
            if (head_valid && out_download && dl_age == 2'd3 && !out_wait && !gap && !out_wr) begin
                out_wr <= 1'b1;
                out_addr <= (head[34:16] == 19'h7FFFF) ? 25'h1FFFFFF : {6'd0, head[34:16]};
                out_data <= head[15:0];
                head_valid <= 1'b0;
                gap <= 1'b1;
            end

            // The download ends once data_io's has and every word is taken.
            if (out_download && !in_download && !in_download_q && empty &&
                !head_valid && !out_wr && !gap && !out_wait)
                out_download <= 1'b0;
        end
    end
endmodule
