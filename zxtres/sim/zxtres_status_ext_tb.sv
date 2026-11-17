// zxtres_status_ext beside MiST user_io, on the controller's SPI as the
// firmware drives it (zxtres/firmware/statusword.c): command 1Eh and the
// sixteen bytes of the 128-bit status word, low byte first. Checks that
// user_io takes bits 0-63 and zxtres_status_ext bits 64-127, that other
// commands and a short 1Eh leave bits 64-127 alone, and that transfers right
// after one another, with SPI_SS_IO high for a fraction of a clk_sys
// period, are told apart.
// Run with zxtres/sim/run_status_ext_test.sh.
`timescale 1ns/1ps
module zxtres_status_ext_tb;
    logic clk = 1'b0;
    always #10 clk = !clk;                       // clk_chipset, 50 MHz
    logic spi_clk = 1'b0, spi_ss_io = 1'b1, spi_mosi = 1'b0;
    wire  [63:0] status_lo, status_ext;

    /* verilator lint_off PINCONNECTEMPTY */
    user_io #(.STRLEN(5), .PS2DIV(2000)) u_user_io (
        .conf_str("TEST;"), .conf_addr(), .conf_chr(8'h00),
        .clk_sys(clk), .clk_sd(clk),
        .SPI_CLK(spi_clk), .SPI_SS_IO(spi_ss_io), .SPI_MISO(), .SPI_MOSI(spi_mosi),
        .joystick_0(), .joystick_1(), .joystick_2(), .joystick_3(), .joystick_4(),
        .joystick_analog_0(), .joystick_analog_1(),
        .buttons(), .switches(), .scandoubler_disable(), .ypbpr(), .no_csync(),
        .status(status_lo), .core_mod(), .rtc(),
        .sd_lba(32'd0), .sd_rd(1'b0), .sd_wr(1'b0), .sd_ack(), .sd_ack_conf(), .sd_ack_x(),
        .sd_conf(1'b0), .sd_sdhc(1'b1), .sd_dout(), .sd_dout_strobe(), .sd_din(8'h00),
        .sd_din_strobe(), .sd_buff_addr(), .img_mounted(), .img_size(),
        .ps2_kbd_clk(), .ps2_kbd_data(), .ps2_kbd_clk_i(1'b1), .ps2_kbd_data_i(1'b1),
        .ps2_mouse_clk(), .ps2_mouse_data(), .ps2_mouse_clk_i(1'b1), .ps2_mouse_data_i(1'b1),
        .key_pressed(), .key_extended(), .key_code(), .key_strobe(),
        .kbd_out_data(8'h00), .kbd_out_strobe(1'b0), .leds(),
        .mouse_x(), .mouse_y(), .mouse_z(), .mouse_flags(), .mouse_strobe(), .mouse_idx(),
        .i2c_start(), .i2c_read(), .i2c_addr(), .i2c_subaddr(), .i2c_dout(),
        .i2c_din(8'h00), .i2c_ack(1'b0), .i2c_end(1'b0),
        .serial_data(8'h00), .serial_strobe(1'b0)
    );
    /* verilator lint_on PINCONNECTEMPTY */

    zxtres_status_ext dut (.clk_sys(clk), .SPI_CLK(spi_clk), .SPI_SS_IO(spi_ss_io),
                           .SPI_MOSI(spi_mosi), .status_ext(status_ext));

    // The controller's SPI: about 12.5 MHz, MSB first, data set while the
    // clock is low and sampled on its rising edge.
    task automatic spi_byte(input logic [7:0] b);
        for (int i = 7; i >= 0; i--) begin
            spi_mosi = b[i];
            #40 spi_clk = 1'b1;
            #40 spi_clk = 1'b0;
        end
    endtask
    task automatic transfer(input logic [7:0] cmd, input logic [127:0] data, input int bytes,
                            input int gap_ns = 200);
        spi_ss_io = 1'b0;
        #40;
        spi_byte(cmd);
        for (int i = 0; i < bytes; i++) spi_byte(data[i*8 +: 8]);
        #40 spi_ss_io = 1'b1;
        #(gap_ns);
    endtask
    task automatic expect_status(input string what, input logic [127:0] want);
        repeat (10) @(posedge clk);
        if ({status_ext, status_lo} !== want)
            $fatal(1, "%s: status %h, expected %h", what, {status_ext, status_lo}, want);
    endtask

    logic [127:0] a = 128'h0123456789ABCDEF_FEDCBA9876543210;
    logic [127:0] b = 128'hA5A55A5A_00FF00FF_DEADBEEF_CAFEF00D;

    initial begin
        #200;
        transfer(8'h1E, a, 16);
        expect_status("first word", a);

        // Another command, sixteen bytes long, leaves the status alone.
        transfer(8'h60, b, 16);
        expect_status("joystick command", a);

        // A 64-bit 1Eh (eight bytes, as DeMiSTify's own firmware sends)
        // changes bits 0-63 only.
        transfer(8'h1E, b, 8);
        expect_status("short 1Eh", {a[127:64], b[63:0]});

        // Two words back to back, SPI_SS_IO high for 5 ns between them.
        transfer(8'h1E, a, 16, 5);
        transfer(8'h1E, b, 16, 5);
        expect_status("back to back", b);

        $display("STATUS_EXT_TEST_PASS");
        $finish;
    end
endmodule
