// zxtres_ioctl_fifo between a data_io model and a model of the machine's
// rom_loader, whose wait is registered and random. Checks:
//   - every word reaches the loader once, in order, with its index, offset
//     and data, and an offset past 256 KiB as one outside every slot;
//   - no word while the loader waits, and never two in consecutive clocks;
//   - the loader's download begins after data_io's, with the wait already
//     up during the bus hold, and drops between files, also when data_io
//     starts the next file before the loader has taken the last words of
//     the previous one;
//   - no overflow at the controller's rate.
// Run with zxtres/sim/run_ioctl_fifo_test.sh.
`timescale 1ns/1ps
module zxtres_ioctl_fifo_tb;
    logic clk = 1'b0;
    always #10 clk = !clk;
    logic reset = 1'b1;

    logic        in_download = 1'b0, in_wr = 1'b0;
    logic [7:0]  in_index = 8'h00;
    logic [26:0] in_addr = '0;
    logic [15:0] in_data = '0;
    wire         overflow, out_download, out_wr;
    wire  [7:0]  out_index;
    wire  [24:0] out_addr;
    wire  [15:0] out_data;
    logic        out_wait = 1'b1;

    zxtres_ioctl_fifo dut (
        .clk(clk), .reset(reset),
        .in_download(in_download), .in_index(in_index), .in_wr(in_wr),
        .in_addr(in_addr), .in_data(in_data), .overflow(overflow),
        .out_download(out_download), .out_index(out_index), .out_wr(out_wr),
        .out_addr(out_addr), .out_data(out_data), .out_wait(out_wait));

    // What the loader must see, in order.
    typedef struct packed { logic [7:0] index; logic [24:0] addr; logic [15:0] data; } word_t;
    word_t expected [$];
    int received = 0, downloads_seen = 0;

    // Loader model: wait while the bus hold is being granted at the start of
    // each download, and for a few clocks after each word (the SDRAM write);
    // the wait is a register, as in rom_loader.
    int hold_left = 0, busy_left = 0;
    bit slow = 0;                      // a slower SDRAM write, to let words queue up
    logic out_download_q = 1'b0, out_wr_q = 1'b0;
    always @(posedge clk) begin
        out_download_q <= out_download;
        out_wr_q <= out_wr;
        if (!out_download) begin
            out_wait <= 1'b0;
            hold_left <= 0;
        end else if (!out_download_q) begin
            out_wait <= 1'b1;
            hold_left <= 20 + $urandom_range(0, 400);
            downloads_seen <= downloads_seen + 1;
        end else if (hold_left > 0) begin
            hold_left <= hold_left - 1;
            out_wait <= 1'b1;
        end else if (out_wr) begin
            out_wait <= 1'b1;
            busy_left <= slow ? 20 + $urandom_range(0, 10) : 2 + $urandom_range(0, 12);
        end else if (busy_left > 0) begin
            busy_left <= busy_left - 1;
            out_wait <= busy_left > 1;
        end else
            out_wait <= 1'b0;
    end

    always @(posedge clk) if (!reset) begin
        if (out_wr && out_wait)   $fatal(1, "word while the loader waits");
        if (out_wr && out_wr_q)   $fatal(1, "two words in consecutive clocks");
        if (out_wr && !out_download) $fatal(1, "word outside a download");
        if (overflow) $fatal(1, "overflow");
        if (out_wr) begin
            word_t want;
            if (expected.size() == 0) $fatal(1, "unexpected word %h", out_data);
            want = expected.pop_front();
            if (out_index !== want.index || out_addr !== want.addr || out_data !== want.data)
                $fatal(1, "word %0d: index %h addr %h data %h, expected %h %h %h", received,
                       out_index, out_addr, out_data, want.index, want.addr, want.data);
            received++;
        end
    end

    // data_io model: a file of WORDS words at one every PERIOD clocks.
    task automatic download(input logic [7:0] index, input int words, input int period,
                            input int first_word = 0);
        @(negedge clk) begin in_download = 1'b1; in_index = index; end
        repeat (10) @(negedge clk);
        for (int i = 0; i < words; i++) begin
            logic [26:0] addr = 27'(2 * (first_word + i));
            logic [15:0] data = 16'($urandom);
            word_t want;
            want.index = index;
            want.addr = addr[26:18] != 0 ? 25'h1FFFFFF : addr[24:0];
            want.data = data;
            expected.push_back(want);
            @(negedge clk) begin in_wr = 1'b1; in_addr = addr; in_data = data; end
            @(negedge clk) in_wr = 1'b0;
            repeat (period - 2) @(negedge clk);
        end
        @(negedge clk) in_download = 1'b0;
    endtask

    task automatic drain;
        int guard = 0;
        while ((expected.size() != 0 || out_download) && guard < 2000000) begin
            @(posedge clk);
            guard++;
        end
        if (expected.size() != 0) $fatal(1, "%0d words never arrived", expected.size());
    endtask

    initial begin
        repeat (5) @(negedge clk);
        reset = 1'b0;
        repeat (5) @(negedge clk);

        // One ROM at a typical controller rate, then the next after a pause.
        download(8'd0, 4096, 40);
        drain();
        if (downloads_seen != 1) $fatal(1, "%0d downloads seen, expected 1", downloads_seen);
        download(8'd3, 2048, 40);
        drain();
        if (downloads_seen != 2) $fatal(1, "%0d downloads seen, expected 2", downloads_seen);

        // Files back to back, sent faster than the slowed loader takes them:
        // the next one starts with words of this one still queued.
        slow = 1;
        download(8'd1, 300, 16);
        if (expected.size() < 50) $fatal(1, "only %0d words queued: no overlap tested", expected.size());
        download(8'd2, 300, 16);
        download(8'd4, 200, 16);
        drain();
        slow = 0;
        if (downloads_seen != 5) $fatal(1, "%0d downloads seen, expected 5", downloads_seen);

        // An offset past the slots (the end of a long file).
        download(8'd5, 4, 40, (27'h40000 >> 1) - 2);
        drain();

        $display("IOCTL_FIFO_TEST_PASS (%0d words)", received);
        $finish;
    end

    initial begin
        #500ms;
        $fatal(1, "timeout");
    end
endmodule
