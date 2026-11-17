// A queue between MiST data_io and the PC/XT ROM loader.
//
// data_io sends a ROM file word by word at the rate of the controller's SPI
// and has no wait input; the machine's rom_loader (rtl/mem/rom_loader.sv)
// raises ioctl_wait until the CPU has given up the bus and while each word is
// written to the SDRAM, as MiSTer's hps_io allows. The words go through this
// queue: the download seen by the loader begins with data_io's and ends when
// its last word has been taken, and a word is offered only while the loader
// does not wait. One word, never two in consecutive clocks: the loader's wait
// is registered.
//
// The firmware loads the ROMs one after the other. Each word carries the
// parity of its download, so that when data_io starts the next file before
// the loader has taken the last words of the previous one, those words still
// go out under the previous index; the next download is seen by the loader
// once that one has ended and out_download has been low for a few clocks,
// so the loader is back in its idle state.
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

    // An entry: download parity, file offset, data.
    logic [35:0] mem [0:DEPTH-1];
    logic [DEPTH_BITS:0] wptr = '0, rptr = '0;
    wire  empty = wptr == rptr;
    wire  full  = (wptr[DEPTH_BITS] != rptr[DEPTH_BITS]) &&
                  (wptr[DEPTH_BITS-1:0] == rptr[DEPTH_BITS-1:0]);

    wire [18:0] in_offset = (in_addr[26:18] != 9'd0) ? 19'h7FFFF : {1'b0, in_addr[17:0]};

    logic in_gen;                       // parity of data_io's current download
    always_ff @(posedge clk) begin
        if (in_wr && !full)
            mem[wptr[DEPTH_BITS-1:0]] <= {in_gen, in_offset, in_data};
    end

    logic [35:0] head;
    logic        head_valid;            // head holds the entry at rptr - 1
    logic        gap;                   // the clock after a word: the wait is not seen yet
    logic        in_download_q;
    logic        start_pending;         // data_io began a download not yet passed on
    logic [7:0]  pending_index;
    logic        pending_gen;
    logic        out_gen;               // parity of the download the loader sees
    logic [1:0]  dl_age;                // clocks since out_download rose, to 3: the
                                        // loader has registered it and its wait
    logic [1:0]  low_age;               // clocks since out_download fell, to 3

    wire head_ours = head_valid && head[35] == out_gen;
    // data_io has finished the download the loader sees: it has ended, or a
    // later one has begun.
    wire in_done = (!in_download && !in_download_q && !start_pending) ||
                   (start_pending && pending_gen != out_gen);
    // No word of the current download is left in the queue: the queue is
    // empty or its next word belongs to the next download.
    wire drained = !head_ours && (head_valid || empty);

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
            out_gen <= 1'b0;
            in_gen <= 1'b0;
            in_download_q <= 1'b0;
            start_pending <= 1'b0;
            dl_age <= 2'd0;
            low_age <= 2'd3;
        end else begin
            if (!out_download)
                dl_age <= 2'd0;
            else if (dl_age != 2'd3)
                dl_age <= dl_age + 2'd1;
            if (out_download)
                low_age <= 2'd0;
            else if (low_age != 2'd3)
                low_age <= low_age + 2'd1;

            in_download_q <= in_download;
            if (in_download && !in_download_q) begin
                in_gen <= !in_gen;
                pending_gen <= !in_gen;
                pending_index <= in_index;
                start_pending <= 1'b1;
            end
            if (in_wr) begin
                if (full) overflow <= 1'b1;
                else wptr <= wptr + 1'b1;
            end

            // Pass a download on once the loader is idle again.
            if (start_pending && !out_download && low_age == 2'd3 &&
                !(in_download && !in_download_q)) begin
                out_download <= 1'b1;
                out_index <= pending_index;
                out_gen <= pending_gen;
                start_pending <= 1'b0;
            end

            // Read a new head from the memory.
            if (!head_valid && !empty) begin
                head <= mem[rptr[DEPTH_BITS-1:0]];
                rptr <= rptr + 1'b1;
                head_valid <= 1'b1;
            end

            gap <= 1'b0;
            if (head_ours && out_download && dl_age == 2'd3 && !out_wait && !gap && !out_wr) begin
                out_wr <= 1'b1;
                out_addr <= (head[34:16] == 19'h7FFFF) ? 25'h1FFFFFF : {6'd0, head[34:16]};
                out_data <= head[15:0];
                head_valid <= 1'b0;
                gap <= 1'b1;
            end

            // The download ends once data_io has finished it and every one
            // of its words is taken.
            if (out_download && in_done && drained && !out_wr && !gap && !out_wait)
                out_download <= 1'b0;
        end
    end
endmodule
