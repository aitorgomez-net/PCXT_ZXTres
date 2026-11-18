// Board-level simulation of the PCXT ZXTRES+ target booting a real BIOS: the
// DeMiSTify controller (GHDL-converted, real firmware) reads PCXT.CFG and
// loads the ROMs from an SD card model, through data_io and the ROM queue
// into the SDRAM model (behind the board's pin timing), the machine runs its
// POST, and frames are captured at the picture's own resolution after the
// line doubler and the OSD. Driven by plusargs:
//
//   +PROMPT=<text>   the POST frame is taken when this text appears in the
//                    colour text buffer (default "BASIC")
//   +POST_MS=<ms>    longest wait for it after the machine starts (default
//                    4000); the POST frame is taken then anyway
//   +KEYS=<hex>      set-2 scan codes, up to 8, pressed one by one after the
//                    POST frame (default none); E0-prefixed codes as E0xx
//   +KEYS_MS=<ms>    wait after the keys before the last frame (300)
//   +OSD             after the POST frame, Win+F12 opens the OSD
//                    (post_osd.ppm), and Win+F12 closes it again
//   +STOP_MS=<ms>    end the run this long after the start
//   +OSD_TOUR        instead of the POST, open the OSD as soon as the machine
//                    runs and save its pages (tour_*.osd, see osd_tour)
//
// CPU writes to B8000-BFFFF are mirrored into a shadow text buffer, which the
// prompt search uses and which is printed with each frame and, when it has
// changed, every 250 ms. The SDRAM model checks the protocol and its timing,
// and the bench counts DQ contention and reads sampled outside the chip's
// data valid window.
//
// Frames: post.ppm, post_osd.ppm, keys.ppm.
//
// Loops in timed processes, and in functions they call, are while loops with
// the step in the body: Verilator 5.020 hoists a for loop's step out of the
// loop when it inlines such a function into a timed process.
`timescale 1ns/1ps
module zxtres_pcxt_bios_tb;
    logic clock_50 = 1'b0;
    always #10 clock_50 = !clock_50;

    logic [7:0] vga_r, vga_g, vga_b;
    logic vga_hs, vga_vs, led;
    logic sd_cs, sd_sck, sd_mosi, sd_miso;
    wire  ps2_kbd_clk, ps2_kbd_dat, ps2_mouse_clk, ps2_mouse_dat;
    pullup (ps2_kbd_clk);
    pullup (ps2_kbd_dat);
    pullup (ps2_mouse_clk);
    pullup (ps2_mouse_dat);

    wire  [15:0] sdram_dq;
    logic [12:0] sdram_a;
    logic [1:0]  sdram_ba;
    logic sdram_clk, sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n;
    logic sdram_dqml, sdram_dqmh;

    wire  [19:0] sram_a;
    wire  [15:0] sram_q;
    wire         sram_we, sram_oe, sram_ub, sram_lb;
    zxtres_sram_model u_sram (.SRAM_A(sram_a), .SRAM_Q(sram_q), .SRAM_WE(sram_we),
                              .SRAM_OE(sram_oe), .SRAM_UB(sram_ub), .SRAM_LB(sram_lb));

    /* verilator lint_off PINCONNECTEMPTY */
    zxtres_pcxt_top dut (
        .CLOCK_50(clock_50), .LED(led),
        .VGA_R(vga_r), .VGA_G(vga_g), .VGA_B(vga_b), .VGA_HS(vga_hs), .VGA_VS(vga_vs),
        .SRAM_A(sram_a), .SRAM_Q(sram_q), .SRAM_WE(sram_we), .SRAM_OE(sram_oe),
        .SRAM_UB(sram_ub), .SRAM_LB(sram_lb),
        .SDRAM_A(sdram_a), .SDRAM_DQ(sdram_dq), .SDRAM_DQML(sdram_dqml), .SDRAM_DQMH(sdram_dqmh),
        .SDRAM_nWE(sdram_we_n), .SDRAM_nCAS(sdram_cas_n), .SDRAM_nRAS(sdram_ras_n),
        .SDRAM_nCS(sdram_cs_n), .SDRAM_BA(sdram_ba), .SDRAM_CLK(sdram_clk), .SDRAM_CKE(sdram_cke),
        .SD_CS(sd_cs), .SD_SCK(sd_sck), .SD_MOSI(sd_mosi), .SD_MISO(sd_miso),
        .PS2_KEYBOARD_CLK(ps2_kbd_clk), .PS2_KEYBOARD_DAT(ps2_kbd_dat),
        .PS2_MOUSE_CLK(ps2_mouse_clk), .PS2_MOUSE_DAT(ps2_mouse_dat),
        .JOY_CLK(), .JOY_LOAD(), .JOY_DATA(1'b1), .JOY_SEL(),
        .AUDIO_L(), .AUDIO_R(), .I2S_BCK(), .I2S_LRCK(), .I2S_DATA()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    sd_card_model #(.IMAGE("sd.img.sparse"), .BLOCKS(16384)) u_sd (
        .sclk(sd_sck), .cs_n(sd_cs), .mosi(sd_mosi), .miso(sd_miso)
    );

    // ------------------------------------------------------------------
    // SDRAM behind the board's pins: the commands, address and write data
    // leave their I/O registers TCO after the controller clock, as does the
    // forwarded SDRAM_CLK (half a period later, from the ODDR), so the chip
    // sees them with the same delay.
    localparam real TCO = 1.0;
    logic       p_cke = 1'b0, p_cs_n = 1'b1, p_ras_n = 1'b1, p_cas_n = 1'b1, p_we_n = 1'b1, p_oe = 1'b0;
    logic [1:0] p_ba = '0, p_dqm = 2'b11;
    logic [12:0] p_a = '0;
    logic [15:0] p_dq = '0;
    logic       p_clk = 1'b0;
    wire        guest_oe = dut.guest.sdram_dq_oe;
    always @(sdram_clk) p_clk <= #(TCO) sdram_clk;
    always @(posedge dut.guest.clk_sdram) begin
        #(TCO);
        {p_cke, p_cs_n, p_ras_n, p_cas_n, p_we_n, p_oe} = {sdram_cke, sdram_cs_n, sdram_ras_n,
                                                          sdram_cas_n, sdram_we_n, guest_oe};
        {p_ba, p_dqm, p_a, p_dq} = {sdram_ba, {sdram_dqmh, sdram_dqml}, sdram_a, dut.guest.sdram_dq_out};
    end
    wire [15:0] chip_dq;
    wire        chip_drive, chip_valid;
    sdram_model #(.TCK(8.730), .CL(3)) u_sdram (
        .clk(p_clk), .cke(p_cke), .cs_n(p_cs_n), .ras_n(p_ras_n), .cas_n(p_cas_n),
        .we_n(p_we_n), .ba(p_ba), .a(p_a), .dqm(p_dqm), .dq_in(p_dq), .dq_in_oe(p_oe),
        .dq_out(chip_dq), .dq_drive(chip_drive), .dq_valid(chip_valid)
    );
    // The chip's data reaches the FPGA's input register TCO after it drives it.
    logic [15:0] dq_back = 16'h0000;
    logic        dq_back_valid = 1'b0, dq_back_drive = 1'b0;
    always @(chip_dq or chip_valid or chip_drive) begin
        dq_back <= #(TCO) chip_dq;
        dq_back_valid <= #(TCO) chip_valid;
        dq_back_drive <= #(TCO) chip_drive;
    end
    assign sdram_dq = dq_back_drive ? dq_back : 16'hzzzz;
    int sdram_contention = 0, sdram_bad_samples = 0;
    always @(posedge dut.guest.clk_sdram) begin
        if (guest_oe && dq_back_drive) sdram_contention++;
        if (dut.guest.u_sdram_ctrl.rdq_v[0] && !dq_back_valid) begin
            sdram_bad_samples++;
            if (sdram_bad_samples <= 5)
                $display("[%0t] SDRAM read sampled outside the valid window", $time);
        end
    end

    // ------------------------------------------------------------------
    // PS/2 keyboard model.
    logic kbd_clk_low = 1'b0, kbd_dat_low = 1'b0;
    assign ps2_kbd_clk = kbd_clk_low ? 1'b0 : 1'bz;
    assign ps2_kbd_dat = kbd_dat_low ? 1'b0 : 1'bz;
    task automatic ps2_send(input logic [7:0] b);
        logic [10:0] frame;
        int bit_index;
        frame = {1'b1, ~^b, b, 1'b0};
        bit_index = 0;
        while (bit_index < 11) begin
            kbd_dat_low = !frame[bit_index];
            #20us kbd_clk_low = 1'b1;
            #40us kbd_clk_low = 1'b0;
            #20us;
            bit_index = bit_index + 1;
        end
        kbd_dat_low = 1'b0;
        #200us;
    endtask
    task automatic key(input logic [15:0] code);
        if (code[15:8] == 8'hE0) ps2_send(8'hE0);
        ps2_send(code[7:0]);
        #5ms;
        if (code[15:8] == 8'hE0) ps2_send(8'hE0);
        ps2_send(8'hF0);
        ps2_send(code[7:0]);
        #20ms;
    endtask
    wire osd_open = dut.guest.u_osd.osd_enable;
    int kbd_bytes = 0;                   // keyboard bytes the core received
    always @(posedge dut.guest.clk_chipset) if (dut.guest.kbd_strobe) kbd_bytes <= kbd_bytes + 1;
    task automatic win_f12;
        ps2_send(8'hE0);
        ps2_send(8'h1F);
        #5ms;
        key(16'h0007);
        ps2_send(8'hE0);
        ps2_send(8'hF0);
        ps2_send(8'h1F);
        #20ms;
    endtask
    task automatic set_osd(input bit open);
        if (osd_open !== open) win_f12;
        #30ms;
        if (osd_open !== open) $display("[%0t] OSD did not %s", $time, open ? "open" : "close");
    endtask

    // ------------------------------------------------------------------
    // +OSD_TOUR: as soon as the machine runs, open the OSD and walk its pages
    // with the cursor keys as a person would, saving each page (tour_*.osd):
    // the box position, then a line per row with the inverse bit, 32
    // characters and 32 colours, which zxtres_osd_tb.sv draws (+ROWS=<file>).
    // Entries are found by their text, so the tour follows the menu as the
    // firmware builds it from the configuration string.
    task automatic tour_key(input logic [15:0] code);
        if (tour_log) $display("[%0t] OSD_TOUR key %h", $time, code);
        key(code);
    endtask
    // While the tour runs, log the keyboard bytes the core receives, the
    // OSD's open state and the cursor row as the firmware draws it.
    bit tour_log = 0;
    always @(posedge dut.guest.clk_chipset)
        if (tour_log && dut.guest.kbd_strobe) $display("[%0t]   kbd byte %h", $time, dut.guest.kbd_byte);
    always @(osd_open) if (tour_log) $display("[%0t]   OSD %s", $time, osd_open ? "open" : "closed");
    initial begin
        int cursor_row, row;
        cursor_row = -1;
        forever begin
            #500us;
            row = osd_selected();
            if (tour_log && row != cursor_row) begin
                cursor_row = row;
                $display("[%0t]   cursor row %0d", $time, row);
            end
        end
    end
    function automatic string osd_row(input int n);
        string s;
        int c;
        s = "";
        c = 0;
        while (c < 32) begin
            if (dut.guest.u_osd.row_buffer[n*33 + 1 + c] >= 8'h20 && dut.guest.u_osd.row_buffer[n*33 + 1 + c] < 8'h7F)
                s = {s, string'(dut.guest.u_osd.row_buffer[n*33 + 1 + c])};
            else
                s = {s, " "};
            c = c + 1;
        end
        return s;
    endfunction
    function automatic bit has_text(input string s, input string what);
        int i;
        i = 0;
        while (i + what.len() <= s.len()) begin
            if (s.substr(i, i + what.len() - 1) == what) return 1;
            i = i + 1;
        end
        return 0;
    endfunction
    function automatic int osd_selected;
        int n;
        n = 0;
        while (n < 16) begin
            if (dut.guest.u_osd.row_attr[n*2]) return n;
            n = n + 1;
        end
        return -1;
    endfunction
    // The whole page as one string, with the cursor row marked.
    function automatic string osd_page;
        string s;
        int n;
        s = "";
        n = 0;
        while (n < 16) begin
            s = {s, dut.guest.u_osd.row_attr[n*2] ? ">" : " ", osd_row(n)};
            n = n + 1;
        end
        return s;
    endfunction
    // Wait until the firmware has finished drawing: the page unchanged for
    // 20 ms (at most 1 s).
    task automatic osd_settle;
        string prev_page;
        int steps;
        steps = 0;
        prev_page = osd_page();
        while (steps < 100) begin
            #20ms;
            if (osd_page() == prev_page) return;
            prev_page = osd_page();
            steps = steps + 2;
        end
        $display("[%0t] OSD_TOUR: page still changing", $time);
    endtask
    // Open the OSD, trying again while the firmware is busy.
    task automatic osd_open_retry;
        int tries;
        tries = 0;
        while (osd_open !== 1'b1 && tries < 10) begin
            win_f12;
            #30ms;
            tries = tries + 1;
        end
        $display("[%0t] OSD_TOUR: OSD %s after %0d Win+F12, %0d key bytes seen by the core",
                 $time, osd_open ? "open" : "STILL CLOSED", tries, kbd_bytes);
    endtask
    // Move the cursor up (the firmware starts it on Exit, the last row) to
    // the entry with this text and press Enter.
    // The match is kept in a variable: Verilator 5.020 does not evaluate
    // again a loop condition that calls these functions in a timed task.
    task automatic osd_choose(input string what);
        int tries, row;
        bit found;
        string line;
        tries = 0;
        found = 0;
        osd_settle();
        while (!found && tries < 34) begin
            row = osd_selected();
            line = row >= 0 ? osd_row(row) : "";
            found = has_text(line, what);
            if (!found) begin
                tour_key(tries < 17 ? 16'hE075 : 16'hE072);   // up, then down
                tries = tries + 1;
            end
        end
        if (!found) begin
            $display("[%0t] OSD_TOUR: \"%s\" not found", $time, what);
            return;
        end
        tour_key(16'h005A);
        #10ms;
    endtask
    task automatic osd_shot(input string name);
        int fd, n, c;
        osd_settle();
        fd = $fopen({name, ".osd"}, "w");
        $fdisplay(fd, "%0d", dut.guest.u_osd.osd_pos);
        n = 0;
        while (n < 18) begin
            $fwrite(fd, "%0d ", n < 16 ? dut.guest.u_osd.row_attr[n*2] : 1'b0);
            c = 0;
            while (c < 32) begin
                $fwrite(fd, "%02x", dut.guest.u_osd.row_buffer[n*33 + 1 + c]);
                c = c + 1;
            end
            $fwrite(fd, " ");
            c = 0;
            while (c < 32) begin
                $fwrite(fd, "%x", dut.guest.u_osd.color_buffer[n*32 + c]);
                c = c + 1;
            end
            $fdisplay(fd, "");
            n = n + 1;
        end
        $fclose(fd);
        $display("[%0t] OSD_TOUR %s", $time, name);
        n = 0;
        while (n < 16) begin
            $display("  %s%s", dut.guest.u_osd.row_attr[n*2] ? ">" : " ", osd_row(n));
            n = n + 1;
        end
        $fflush();
    endtask
    task automatic osd_tour;
        tour_log = 1;
        osd_settle();
        osd_open_retry();
        osd_shot("tour_root");
        osd_choose("Video");
        osd_shot("tour_video");
        osd_choose("Output");
        osd_shot("tour_output");
        osd_choose("Video info");
        osd_shot("tour_vinfo");
        tour_key(16'h0076);                              // ESC: the main page
        osd_choose("Audio");
        osd_shot("tour_audio");
        tour_key(16'h0076);
        osd_choose("Hardware");
        osd_shot("tour_hardware");
        tour_key(16'h0076);
        osd_choose("Settings");
        osd_shot("tour_settings");
        tour_key(16'h0076);
        osd_choose("BIOS");
        osd_shot("tour_bios");
        osd_choose("PCXT BIOS");
        osd_shot("tour_bios_files");
        tour_key(16'h0076);                              // ESC
        osd_shot("tour_after_esc");
    endtask

    // ------------------------------------------------------------------
    // Frame capture at the picture's own size, after the line doubler and
    // the OSD: a frame starts when the vertical blank ends; each run of DE
    // dots on a video_ce is one line.
    wire       clk_video = dut.guest.clk_57_272;
    wire       video_ce  = dut.guest.video_ce;
    wire       video_de  = dut.guest.video_de;
    wire       video_vb  = dut.guest.sd_vb;
    bit        capture_request = 0, capturing = 0;
    string     capture_name;
    logic [23:0] pixels [$];
    int        line_width = 0, width = 0, height = 0;
    logic      de_q = 1'b0, vb_q = 1'b1;
    always @(posedge clk_video) begin
        vb_q <= video_vb;
        if (!capturing && capture_request && vb_q && !video_vb) begin
            capturing = 1;
            pixels.delete();
            width = 0;
            height = 0;
            line_width = 0;
        end else if (capturing && !vb_q && video_vb) begin
            int fd, pixel_index;
            capturing = 0;
            fd = $fopen({capture_name, ".ppm"}, "wb");
            $fwrite(fd, "P6\n%0d %0d\n255\n", width, height);
            pixel_index = 0;
            while (pixel_index < pixels.size()) begin
                $fwrite(fd, "%c%c%c", pixels[pixel_index][23:16], pixels[pixel_index][15:8],
                        pixels[pixel_index][7:0]);
                pixel_index = pixel_index + 1;
            end
            $fclose(fd);
            capture_request = 0;
            $display("[%0t] captured %s (%0dx%0d)", $time, capture_name, width, height);
        end
        if (capturing && video_ce) begin
            de_q <= video_de;
            if (video_de) begin
                pixels.push_back({dut.guest.p57_r, dut.guest.p57_g, dut.guest.p57_b});
                line_width++;
            end else if (de_q) begin
                if (width == 0) width = line_width;
                height++;
                line_width = 0;
            end
        end
    end
    task automatic shot(input string name);
        capture_name = name;
        capture_request = 1;
        wait (!capture_request);
    endtask

    // ------------------------------------------------------------------
    logic download_q = 0;
    always @(posedge clock_50) begin
        download_q <= dut.guest.ioctl_download;
        if (dut.guest.ioctl_download && !download_q)
            $display("[%0t] download start, index %02h", $time, dut.guest.ioctl_index);
        if (!dut.guest.ioctl_download && download_q)
            $display("[%0t] download end", $time);
        if (dut.guest.ioctl_overflow) begin
            $display("[%0t] ROM queue overflow", $time);
            $fatal(1, "ROM queue overflow");
        end
    end

    // ------------------------------------------------------------------
    // Shadow of the colour text buffer from the CPU's memory writes.
    logic [7:0] text_shadow [0:16383];
    initial foreach (text_shadow[i]) text_shadow[i] = 8'h00;
    wire        bus_clk  = dut.guest.clk_chipset;
    wire [19:0] bus_addr = dut.guest.u_CHIPSET.address;
    wire [7:0]  bus_data = dut.guest.u_CHIPSET.internal_data_bus;
    wire        bus_mw_n = dut.guest.u_CHIPSET.memory_write_n;
    logic       mw_q = 1'b1;
    logic [19:0] mw_addr;
    logic [7:0]  mw_data;
    bit          text_changed = 0;
    always @(posedge bus_clk) begin
        mw_q <= bus_mw_n;
        if (!bus_mw_n) begin
            mw_addr <= bus_addr;
            mw_data <= bus_data;
        end
        if (!mw_q && bus_mw_n && mw_addr[19:14] == 6'b101110) begin   // B8000-BBFFF
            text_shadow[mw_addr[13:0]] <= mw_data;
            text_changed <= 1;
        end
    end
    function automatic string screen_line(int row);
        string line;
        int col;
        byte c;
        line = "";
        col = 0;
        while (col < 80) begin
            c = text_shadow[(row * 80 + col) * 2];
            line = {line, $sformatf("%c", (c >= 8'h20 && c < 8'h7f) ? c : 8'h20)};
            col = col + 1;
        end
        return line;
    endfunction
    function automatic bit screen_has(string text);
        int pos, i;
        bit match;
        pos = 0;
        while (pos + text.len() <= 2000) begin
            match = 1;
            i = 0;
            while (i < text.len() && match) begin
                if (text_shadow[(pos + i) * 2] != text[i]) match = 0;
                i = i + 1;
            end
            if (match) return 1;
            pos = pos + 1;
        end
        return 0;
    endfunction
    task automatic dump_screen(input string why);
        int row;
        $display("[%0t] screen (%s):", $time, why);
        row = 0;
        while (row < 25) begin
            $display("  |%s|", screen_line(row));
            row = row + 1;
        end
        $fflush();
    endtask
    initial forever begin
        #250ms;
        if (text_changed) begin
            text_changed = 0;
            dump_screen("changed");
        end
    end

    initial forever begin
        #10ms;
        $display("[heartbeat] %0d ms", $time / 1000000);
        $fflush();
    end
    initial begin
        longint stop_ms;
        if ($value$plusargs("STOP_MS=%d", stop_ms)) begin
            #(stop_ms * 1000000);
            $display("[%0t] STOP_MS reached", $time);
            dump_screen("stop");
            $finish;
        end
    end

    task automatic report;
        $display("SDRAM_SIM errors=%0d reads=%0d writes=%0d contention=%0d bad_samples=%0d",
                 u_sdram.errors, u_sdram.reads, u_sdram.writes, sdram_contention, sdram_bad_samples);
    endtask

    initial begin
        longint post_ms, keys_ms, waited;
        bit found;
        int key_index;
        logic [127:0] keys;
        string prompt;
        if (!$value$plusargs("PROMPT=%s", prompt)) prompt = "BASIC";
        if (!$value$plusargs("POST_MS=%d", post_ms)) post_ms = 4000;
        if (!$value$plusargs("KEYS_MS=%d", keys_ms)) keys_ms = 300;
        if (!$value$plusargs("KEYS=%h", keys)) keys = '0;
        $display("zxtres_pcxt_bios_tb: start");
        wait (dut.guest.pcxt_bios_loaded === 1'b1);
        $display("[%0t] BIOS loaded", $time);
        wait (dut.guest.reset === 1'b0);
        $display("[%0t] machine running", $time);
        $fflush();
        if ($test$plusargs("OSD_TOUR")) begin
            osd_tour();
            report();
            $display("ZXTRES_PCXT_OSD_TOUR_END");
            $finish;
        end
        waited = 0;
        found = screen_has(prompt);
        while (waited < post_ms && !found) begin
            #1ms;
            waited++;
            found = screen_has(prompt);
        end
        if (found) $display("[%0t] prompt \"%s\" on screen", $time, prompt);
        else $display("[%0t] prompt \"%s\" not seen", $time, prompt);
        $fflush();
        shot("post");
        dump_screen("post");
        if ($test$plusargs("OSD")) begin
            set_osd(1);
            $display("[%0t] Win+F12: OSD %s", $time, osd_open ? "open" : "CLOSED (wrong)");
            shot("post_osd");
            set_osd(0);
        end
        if (keys != '0) begin
            key_index = 7;
            while (key_index >= 0) begin
                if (keys[key_index*16 +: 16] != 16'h0000) key(keys[key_index*16 +: 16]);
                key_index = key_index - 1;
            end
            #(keys_ms * 1000000);
            shot("keys");
            dump_screen("keys");
        end
        report();
        $display(found ? "ZXTRES_PCXT_BIOS_SIM_PASS" : "ZXTRES_PCXT_BIOS_SIM_END (prompt not seen)");
        $finish;
    end
endmodule
