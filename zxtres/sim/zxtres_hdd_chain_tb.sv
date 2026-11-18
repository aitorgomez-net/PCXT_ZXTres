// The hard disk path of the PCXT guest from the machine's IDE device to the
// DeMiSTify firmware, without the CPU: rtl/common/ide.v, zxtres_ide_store,
// zxtres_fdd_store, zxtres_sd_arb and the MiST user_io wired as in
// pcxt_zxtres_guest.sv, and a model of the firmware that speaks the user_io
// SPI protocol the way DeMiSTify/firmware/diskimg.c does (mount with
// UIO_SET_SDINFO and UIO_SET_SDSTAT; poll UIO_GET_SDSTAT, then UIO_SD_ACK and
// UIO_SECTOR_RD with the sector). The images are files:
//
//   +HDD0=<file>  hard disk 0 (required)    +HDD1=<file>  hard disk 1
//   +FDA=<file>   floppy A, mounted first, as on the board
//
// The machine side does what the XT-IDE BIOS does to boot: reset, IDENTIFY,
// then READ SECTORS of sector 0 (CHS 0/0/1) and of the first sector of the
// partition the MBR names, and checks every word against the file.
//
// Loops in timed processes are while loops (Verilator 5.020).
`timescale 1ns/1ps
module zxtres_hdd_chain_tb;
    logic clk = 1'b0;
    always #10 clk = !clk;                    // clk_chipset, 50 MHz
    logic reset = 1'b1;

    // ------------------------------------------------------------ images
    byte unsigned hdd0[], hdd1[], fda[];
    string hdd0_file, hdd1_file, fda_file;

    function automatic void load(input string fn, ref byte unsigned img[]);
        int fd, n;
        fd = $fopen(fn, "rb");
        if (fd == 0) $fatal(1, "cannot open %s", fn);
        void'($fseek(fd, 0, 2));
        n = $ftell(fd);
        void'($fseek(fd, 0, 0));
        img = new[n];
        for (int i = 0; i < n; i++) img[i] = 8'($fgetc(fd));   // $fread cannot fill a dynamic array in Verilator
        $fclose(fd);
        $display("loaded %s: %0d bytes, %0d sectors", fn, n, n / 512);
    endfunction

    // ------------------------------------------------------------ SPI
    logic spi_sck = 1'b0, spi_ss_io = 1'b1, spi_mosi = 1'b0;
    wire  spi_miso;

    // ------------------------------------------------------------ guest
    wire [4:0]  arb_sd_rd, arb_sd_wr;
    wire [31:0] arb_sd_lba;
    wire [7:0]  arb_sd_din;
    wire [4:0]  sd_ack_x;
    wire [7:0]  sd_dout;
    wire        sd_dout_strobe;
    wire [8:0]  sd_buff_addr;
    wire [4:0]  img_mounted;
    wire [63:0] img_size;

    /* verilator lint_off PINCONNECTEMPTY */
    user_io #(.STRLEN(8), .PS2DIV(2000), .SD_IMAGES(5)) u_user_io (
        .conf_str("MENU;;;;"), .conf_addr(), .conf_chr(8'h00),
        .clk_sys(clk), .clk_sd(clk),
        .SPI_CLK(spi_sck), .SPI_SS_IO(spi_ss_io), .SPI_MISO(spi_miso), .SPI_MOSI(spi_mosi),
        .joystick_0(), .joystick_1(), .joystick_2(), .joystick_3(),
        .joystick_4(), .joystick_analog_0(), .joystick_analog_1(),
        .buttons(), .switches(), .scandoubler_disable(), .ypbpr(), .no_csync(),
        .status(), .core_mod(), .rtc(),
        .sd_lba(arb_sd_lba), .sd_rd(arb_sd_rd), .sd_wr(arb_sd_wr),
        .sd_ack(), .sd_ack_conf(), .sd_ack_x(sd_ack_x), .sd_conf(1'b0), .sd_sdhc(1'b1),
        .sd_dout(sd_dout), .sd_dout_strobe(sd_dout_strobe), .sd_din(arb_sd_din),
        .sd_din_strobe(), .sd_buff_addr(sd_buff_addr),
        .img_mounted(img_mounted), .img_size(img_size),
        .ps2_kbd_clk(), .ps2_kbd_data(), .ps2_kbd_clk_i(1'b1), .ps2_kbd_data_i(1'b1),
        .ps2_mouse_clk(), .ps2_mouse_data(), .ps2_mouse_clk_i(1'b1), .ps2_mouse_data_i(1'b1),
        .key_pressed(), .key_extended(), .key_code(), .key_strobe(),
        .kbd_out_data(8'h00), .kbd_out_strobe(1'b0), .leds(),
        .mouse_x(), .mouse_y(), .mouse_z(), .mouse_flags(), .mouse_strobe(), .mouse_idx(),
        .i2c_start(), .i2c_read(), .i2c_addr(), .i2c_subaddr(), .i2c_dout(),
        .i2c_din(8'h00), .i2c_ack(1'b0), .i2c_end(1'b0),
        .serial_data(8'h00), .serial_strobe(1'b0)
    );

    // IDE device of the machine (Peripherals.sv), driven here directly
    logic [3:0]  io_address = '0;
    logic        io_read = 1'b0, io_write = 1'b0;
    logic [31:0] io_writedata = '0;
    wire  [31:0] io_readdata;
    wire  [7:0]  mgmt_req;
    wire  [15:0] mgmt_addr, mgmt_dout, mgmt_ide_readdata;
    wire         mgmt_wr, mgmt_rd;
    wire         mgmt_ide_cs = (mgmt_addr[15:8] == 8'hF0);
    assign mgmt_req[5:3] = 3'b000;
    assign mgmt_req[7:6] = 2'b00;             // the floppy controller stays idle

    ide u_ide (
        .clk(clk), .rst_n(!reset), .irq(), .drq(), .use_fast(1'b0), .no_data(),
        .drive_en(), .io_address(io_address), .io_read(io_read), .io_readdata(io_readdata),
        .io_write(io_write), .io_writedata(io_writedata), .io_32(1'b0), .io_wait(),
        .request(mgmt_req[2:0]),
        .mgmt_address(mgmt_addr[3:0]), .mgmt_write(mgmt_wr && mgmt_ide_cs),
        .mgmt_writedata(mgmt_dout), .mgmt_read(mgmt_rd && mgmt_ide_cs),
        .mgmt_readdata(mgmt_ide_readdata),
        .primary_only(1'b0), .secondary_only(1'b0), .ignore_access()
    );
    wire [15:0] mgmt_din = mgmt_ide_cs ? mgmt_ide_readdata : 16'h0000;

    // The stores and the arbiter, as in pcxt_zxtres_guest.sv
    wire [1:0]  ide_sd_rd, ide_sd_wr, fdd_sd_rd, fdd_sd_wr;
    wire [31:0] ide_sd_lba, fdd_sd_lba;
    wire [7:0]  ide_sd_din, fdd_sd_din;
    wire [15:0] ide_mgmt_address, ide_mgmt_dout, fdd_mgmt_address, fdd_mgmt_dout;
    wire        ide_mgmt_write, ide_mgmt_read, ide_bus_req, ide_bus_use;
    wire        fdd_mgmt_write, fdd_mgmt_read, fdd_bus_req, fdd_bus_use;
    wire [15:0] ide_commands, fdd_sectors;
    assign mgmt_addr = ide_bus_use ? ide_mgmt_address : fdd_mgmt_address;
    assign mgmt_dout = ide_bus_use ? ide_mgmt_dout    : fdd_mgmt_dout;
    assign mgmt_wr   = ide_bus_use ? ide_mgmt_write   : (fdd_bus_use && fdd_mgmt_write);
    assign mgmt_rd   = ide_bus_use ? ide_mgmt_read    : (fdd_bus_use && fdd_mgmt_read);

    zxtres_ide_store u_ide_store (
        .clk(clk), .reset(reset),
        .img_mounted(img_mounted[1:0]), .img_size(img_size),
        .sd_rd(ide_sd_rd), .sd_wr(ide_sd_wr), .sd_lba(ide_sd_lba),
        .sd_ack(sd_ack_x[1:0]), .sd_buff_addr(sd_buff_addr),
        .sd_dout(sd_dout), .sd_dout_strobe(sd_dout_strobe), .sd_din(ide_sd_din),
        .bus_req(ide_bus_req), .bus_grant(!fdd_bus_use), .bus_use(ide_bus_use),
        .mgmt_address(ide_mgmt_address), .mgmt_writedata(ide_mgmt_dout),
        .mgmt_write(ide_mgmt_write), .mgmt_read(ide_mgmt_read),
        .mgmt_readdata(mgmt_din), .ide_request(mgmt_req[2:0]),
        .command_count(ide_commands)
    );
    zxtres_fdd_store u_fdd_store (
        .clk(clk), .reset(reset),
        .img_mounted(img_mounted[4:3]), .img_size(img_size),
        .sd_rd(fdd_sd_rd), .sd_wr(fdd_sd_wr), .sd_lba(fdd_sd_lba),
        .sd_ack(sd_ack_x[4:3]), .sd_buff_addr(sd_buff_addr),
        .sd_dout(sd_dout), .sd_dout_strobe(sd_dout_strobe), .sd_din(fdd_sd_din),
        .bus_req(fdd_bus_req), .bus_grant(!ide_bus_req), .bus_use(fdd_bus_use),
        .mgmt_address(fdd_mgmt_address), .mgmt_writedata(fdd_mgmt_dout),
        .mgmt_write(fdd_mgmt_write), .mgmt_read(fdd_mgmt_read),
        .mgmt_readdata(mgmt_din), .floppy_request(mgmt_req[7:6]),
        .sector_count(fdd_sectors)
    );
    zxtres_sd_arb u_sd_arb (
        .clk(clk), .reset(reset),
        .a_rd(ide_sd_rd), .a_wr(ide_sd_wr), .a_lba(ide_sd_lba), .a_din(ide_sd_din),
        .b_rd(1'b0), .b_wr(1'b0), .b_din(8'h00),
        .c_rd(fdd_sd_rd), .c_wr(fdd_sd_wr), .c_lba(fdd_sd_lba), .c_din(fdd_sd_din),
        .sd_ack_x(sd_ack_x),
        .sd_rd(arb_sd_rd), .sd_wr(arb_sd_wr), .sd_lba(arb_sd_lba), .sd_din(arb_sd_din)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ------------------------------------------------- firmware model
    // SPI mode 0 at about 12.5 MHz: MOSI set while SCK is low, both sides
    // sample on the rising edge, user_io changes MISO on the falling edge.
    semaphore spi_lock = new(1);

    task automatic spi_byte(input byte unsigned out, output byte unsigned in);
        in = 0;
        for (int b = 7; b >= 0; b--) begin
            spi_mosi = out[b];
            #40 spi_sck = 1'b1;
            in[b] = (spi_miso === 1'b1);
            #40 spi_sck = 1'b0;
        end
    endtask

    task automatic enable_io();  #100 spi_ss_io = 1'b0; #100; endtask
    task automatic disable_io(); #100 spi_ss_io = 1'b1; #400; endtask

    task automatic cmd8(input byte unsigned cmd, input byte unsigned arg);
        byte unsigned d;
        enable_io(); spi_byte(cmd, d); spi_byte(arg, d); disable_io();
    endtask

    // diskimg_mount(): the size, then the mount event of the unit
    task automatic mount(input int unit, input longint unsigned size);
        byte unsigned d;
        spi_lock.get(1);
        enable_io();
        spi_byte(8'h1D, d);
        for (int i = 0; i < 8; i++) spi_byte(8'(size >> (8 * i)), d);
        for (int i = 0; i < 8; i++) spi_byte(8'h00, d);
        disable_io();
        cmd8(8'h1C, 8'(unit));
        spi_lock.put(1);
        $display("[%0t] firmware: unit %0d mounted, %0d bytes", $time, unit, size);
    endtask

    function automatic byte unsigned img_byte(input int unit, input longint unsigned off);
        case (unit)
            0: img_byte = (off < hdd0.size()) ? hdd0[off] : 8'h00;
            1: img_byte = (off < hdd1.size()) ? hdd1[off] : 8'h00;
            3: img_byte = (off < fda.size()) ? fda[off] : 8'h00;
            default: img_byte = 8'h00;
        endcase
    endfunction

    int fw_reads = 0;
    bit fw_run = 1'b0;
    // diskimg_poll(), called by the main loop
    initial begin
        byte unsigned c, idx, d;
        logic [31:0] lba;
        wait (fw_run);
        forever begin
            spi_lock.get(1);
            enable_io();
            spi_byte(8'h16, d);
            spi_byte(8'hFF, c);
            idx = 0;
            if ((c & 8'hF0) == 8'h60) begin
                spi_byte(8'hFF, idx);
                idx = idx & 8'h03;               // as diskimg.c masks it
            end
            lba = 0;
            for (int i = 0; i < 4; i++) begin
                spi_byte(8'hFF, d);
                lba = {lba[23:0], d};
            end
            disable_io();
            if (((c & 8'hF0) == 8'h50 || (c & 8'hF0) == 8'h60) && (c & 8'h03) == 8'h01) begin
                $display("[%0t] firmware: read unit %0d lba %0d (status %02h)", $time, idx, lba, c);
                // the file seek and SD read take a while on the board
                #20000;
                cmd8(8'h23, idx);
                enable_io();
                spi_byte(8'h17, d);
                for (int i = 0; i < 512; i++)
                    spi_byte(img_byte(int'(idx), longint'(lba) * 512 + i), d);
                disable_io();
                fw_reads++;
            end else if ((c & 8'h03) == 8'h02) begin
                $display("[%0t] firmware: write request unit %0d lba %0d (not modelled)", $time, idx, lba);
            end
            spi_lock.put(1);
            #5000;                               // the rest of the main loop
        end
    end

    // trace of the request and acknowledge lines (+TRACE)
    bit trace = 1'b0;
    initial trace = $test$plusargs("TRACE");
    always @(arb_sd_rd or sd_ack_x or mgmt_req[2:0])
        if (trace) $display("[%0t] trace: sd_rd %b ack %b ide_request %0d store state %0d",
                            $time, arb_sd_rd, sd_ack_x, mgmt_req[2:0], u_ide_store.state_q);

    // ------------------------------------------------------- machine side
    task automatic check(input bit condition, input string message);
        if (!condition) $fatal(1, "CHECK_FAIL: %s", message);
    endtask

    task automatic ide_write(input logic [3:0] address, input logic [7:0] value);
        @(negedge clk);
        io_address = address; io_writedata = {24'd0, value}; io_write = 1'b1;
        @(negedge clk);
        io_write = 1'b0;
        repeat (2) @(negedge clk);
    endtask

    task automatic ide_read(input logic [3:0] address, output logic [15:0] value);
        @(negedge clk);
        io_address = address; io_read = 1'b1;
        @(negedge clk);
        value = io_readdata[15:0];
        io_read = 1'b0;
        repeat (2) @(negedge clk);
    endtask

    // status until not busy (and DRQ as wanted); XT-IDE gives a drive some
    // seconds, here 3 s of simulated time
    task automatic wait_status(input bit want_drq, output logic [7:0] status, output bit ok);
        logic [15:0] v;
        longint t0;
        t0 = $time;
        ok = 1'b0;
        status = 8'hFF;
        while (!ok && ($time - t0) < 64'd3000000000) begin
            ide_read(4'd14, v);
            status = v[7:0];
            if (!status[7] && status != 8'hFF && (status[3] == want_drq || status[0])) ok = 1'b1;
        end
    endtask

    // READ SECTORS of n sectors from lba (or CHS c/h/s), each block checked
    // against the file
    task automatic read_sectors(input logic unit, input int lba, input int n, input bit chs,
                                input int c, input int h, input int s, input string what);
        logic [15:0] w, err;
        logic [7:0] st;
        bit ok;
        int bad;
        ide_write(4'd2, 8'(n));
        if (chs) begin
            ide_write(4'd3, 8'(s)); ide_write(4'd4, 8'(c)); ide_write(4'd5, 8'(c >> 8));
            ide_write(4'd6, {3'b101, unit, 4'(h)});
        end else begin
            ide_write(4'd3, 8'(lba)); ide_write(4'd4, 8'(lba >> 8)); ide_write(4'd5, 8'(lba >> 16));
            ide_write(4'd6, {3'b111, unit, 4'(lba >> 24)});
        end
        ide_write(4'd7, 8'h20);
        for (int k = 0; k < n; k++) begin
            wait_status(1'b1, st, ok);
            if (!ok || st[0]) begin
                ide_read(4'd1, err);
                $display("[%0t] %s: block %0d FAILED, status %02h error %02h (timed out: %0d)",
                         $time, what, k, st, err[7:0], !ok);
                $fatal(1, "CHECK_FAIL: %s", what);
            end
            bad = 0;
            for (int i = 0; i < 256; i++) begin
                byte unsigned lo, hi;
                longint off;
                off = longint'(lba + k) * 512 + 2 * i;
                ide_read(4'd0, w);
                lo = img_byte(int'(unit), off);
                hi = img_byte(int'(unit), off + 1);
                if (w != {hi, lo}) begin
                    if (bad < 8) $display("  %s sector %0d word %0d: got %04h, file has %02h%02h",
                                          what, lba + k, i, w, hi, lo);
                    bad++;
                end
            end
            check(bad == 0, $sformatf("%s sector %0d", what, lba + k));
        end
        wait_status(1'b0, st, ok);
        check(ok && !st[0] && !st[3], $sformatf("%s final status %02h", what, st));
        $display("[%0t] %s: %0d sectors from %0d read, final status %02h", $time, what, n, lba, st);
    endtask

    task automatic read_sector(input logic unit, input int lba, input bit chs,
                               input int c, input int h, input int s, input string what);
        read_sectors(unit, lba, 1, chs, c, h, s, what);
    endtask

    // Software reset through the device control register, as XT-IDE's AH=00h
    task automatic soft_reset();
        logic [7:0] st;
        bit ok;
        ide_write(4'd14, 8'h06);                 // SRST, nIEN
        repeat (300) @(negedge clk);             // 6 us
        ide_write(4'd14, 8'h02);
        wait_status(1'b0, st, ok);
        check(ok, "soft reset");
        $display("[%0t] soft reset: status %02h", $time, st);
    endtask

    initial begin
        logic [15:0] w;
        logic [7:0] st;
        bit ok;
        int cyl, heads, spt, plba;
        if (!$value$plusargs("HDD0=%s", hdd0_file)) $fatal(1, "+HDD0= is required");
        load(hdd0_file, hdd0);
        if ($value$plusargs("HDD1=%s", hdd1_file)) load(hdd1_file, hdd1);
        if ($value$plusargs("FDA=%s", fda_file)) load(fda_file, fda);

        repeat (8) @(negedge clk);
        reset = 1'b0;
        repeat (100) @(negedge clk);

        // The firmware boots: units dismounted then mounted, as loadimage()
        // does for each (floppy A first when there is one), then its main
        // loop starts polling.
        if (fda.size() != 0) begin mount(3, 0); mount(3, fda.size()); end
        mount(0, 0); mount(0, hdd0.size());
        mount(1, 0);
        if (hdd1.size() != 0) mount(1, hdd1.size());
        fw_run = 1'b1;

        // XT-IDE: wait for the drive, then IDENTIFY
        wait_status(1'b0, st, ok);
        $display("[%0t] after mount: status %02h (ok %0d)", $time, st, ok);
        ide_write(4'd6, 8'hA0);
        ide_write(4'd7, 8'hEC);
        wait_status(1'b1, st, ok);
        check(ok && !st[0], $sformatf("IDENTIFY status %02h", st));
        for (int i = 0; i < 256; i++) begin
            ide_read(4'd0, w);
            if (i == 1) cyl = w;
            if (i == 3) heads = w;
            if (i == 6) spt = w;
        end
        $display("[%0t] IDENTIFY: %0d cylinders, %0d heads, %0d sectors", $time, cyl, heads, spt);

        // INIT DEVICE PARAMETERS with the same geometry, as XT-IDE does
        ide_write(4'd2, 8'(spt));
        ide_write(4'd6, {4'b1010, 4'(heads - 1)});
        ide_write(4'd7, 8'h91);
        wait_status(1'b0, st, ok);
        $display("[%0t] INIT DEVICE PARAMETERS: status %02h", $time, st);

        // SET MULTIPLE MODE must be refused (no block mode, IDENTIFY word 47
        // is 0): the XT-IDE BIOS then reads with READ SECTORS, not with READ
        // MULTIPLE, which the store does not have
        ide_write(4'd2, 8'd128);
        ide_write(4'd6, 8'hA0);
        ide_write(4'd7, 8'hC6);
        wait_status(1'b0, st, ok);
        ide_read(4'd1, w);
        check(ok && st[0] && w[7:0] == 8'h04, $sformatf("SET MULTIPLE status %02h error %02h", st, w[7:0]));
        $display("[%0t] SET MULTIPLE: refused (status %02h error %02h)", $time, st, w[7:0]);

        // Boot: sector 0 in CHS and in LBA, then the partition's first sector
        read_sector(1'b0, 0, 1'b1, 0, 0, 1, "MBR (CHS 0/0/1)");
        read_sector(1'b0, 0, 1'b0, 0, 0, 0, "MBR (LBA 0)");
        plba = hdd0[454] | (hdd0[455] << 8) | (hdd0[456] << 16) | (hdd0[457] << 24);
        if (plba != 0 && plba < hdd0.size() / 512)
            read_sector(1'b0, plba, 1'b0, 0, 0, 0, "partition boot sector");
        soft_reset();
        ide_write(4'd2, 8'(spt));
        ide_write(4'd6, {4'b1010, 4'(heads - 1)});
        ide_write(4'd7, 8'h91);
        wait_status(1'b0, st, ok);
        read_sector(1'b0, 0, 1'b1, 0, 0, 1, "MBR after soft reset");
        read_sectors(1'b0, plba, 4, 1'b1, 0, 1, 1, "4 sectors (CHS 0/1/1)");
        read_sectors(1'b0, 60, 8, 1'b0, 0, 0, 0, "8 sectors across a track");
        $display("ZXTRES_HDD_CHAIN_PASS reads=%0d commands=%0d", fw_reads, ide_commands);
        $finish;
    end

    initial begin
        repeat (20) #1_000_000_000;
        $fatal(1, "watchdog");
    end
endmodule
