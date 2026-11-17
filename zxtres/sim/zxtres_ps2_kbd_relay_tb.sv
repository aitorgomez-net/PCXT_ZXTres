// zxtres_ps2_kbd_relay against the machine's own keyboard converter: the
// relay and KFPS2KB, KFPS2KB_Send_Data and the glue of Peripherals.sv between
// them (the 2-flop input sampling of the guest, the clock held low while a
// code waits, the FFh reset sent when port B bit 6 rises). Checks:
//   - the keyboard reset: FFh from the machine, FAh AAh back, AAh read as the
//     BAT code, as the XT BIOS POST expects it;
//   - make and break codes in XT set 1;
//   - Win+F12 kept from the machine, F12 alone passed (the pause toggles);
//   - the physical keyboard's own replies (AAh, FAh) not passed on;
//   - the Windows keys forgotten when the OSD closes.
// Run with zxtres/sim/run_ps2_kbd_relay_test.sh.
`timescale 1ns/1ps
module zxtres_ps2_kbd_relay_tb;
    logic clk = 1'b0;
    always #10 clk = !clk;                       // clk_chipset, 50 MHz
    logic reset = 1'b1, osd_open = 1'b0;
    logic byte_valid = 1'b0;
    logic [7:0] byte_in = 8'h00;

    // peripheral_ce of XT_CE_Generator: about 2.4 MHz.
    logic peripheral_ce = 1'b0;
    int ce_div = 0;
    always @(posedge clk) begin
        peripheral_ce <= ce_div == 0;
        ce_div <= ce_div == 20 ? 0 : ce_div + 1;
    end

    // Relay
    logic host_clk, host_dat;
    wire  dev_clk, dev_dat;
    zxtres_ps2_kbd_relay dut (
        .clk(clk), .reset(reset), .osd_open(osd_open),
        .byte_valid(byte_valid), .byte_in(byte_in),
        .host_clk(host_clk), .host_dat(host_dat),
        .dev_clk(dev_clk), .dev_dat(dev_dat));

    // The guest's input flip-flops (negedge clk_chipset).
    logic clk_ff = 1'b0, ps2_clock = 1'b0, dat_ff = 1'b0, ps2_data = 1'b0;
    always @(negedge clk) begin
        clk_ff <= dev_clk;  ps2_clock <= clk_ff;
        dat_ff <= dev_dat;  ps2_data  <= dat_ff;
    end

    // Peripherals.sv: KFPS2KB, the reset sender and the clock hold.
    logic port_b6 = 1'b0;                        // ps2_reset_n
    logic clear_keycode = 1'b0;
    logic prev_ps2_reset_n = 1'b0;
    always @(posedge clk) prev_ps2_reset_n <= reset ? 1'b0 : port_b6;
    wire  ps2_send_clock, ps2_data_out, lock_recv_clock;
    wire  irq, pause_core, swap_video;
    wire [7:0] keycode;

    KFPS2KB u_kb (
        .clock(clk), .peripheral_ce(peripheral_ce), .reset(reset),
        .device_clock(ps2_clock | lock_recv_clock), .device_data(ps2_data),
        .irq(irq), .keycode(keycode), .clear_keycode(clear_keycode),
        .pause_core(pause_core), .swap_video(swap_video),
        .video_output(1'b0), .tandy_video(1'b0));

    KFPS2KB_Send_Data u_send (
        .clock(clk), .peripheral_ce(peripheral_ce), .reset(reset),
        .device_clock(ps2_clock), .device_clock_out(ps2_send_clock),
        .device_data_out(ps2_data_out), .sending_data_flag(lock_recv_clock),
        .send_request(~prev_ps2_reset_n & port_b6), .send_data(8'hFF));

    always @(posedge clk)
        host_clk <= reset ? 1'b1 : ~(irq | ~ps2_send_clock | ~port_b6);
    assign host_dat = ps2_data_out;

    // The BIOS side: each code is read and acknowledged (port B bit 7).
    logic [7:0] codes [$];
    always @(posedge clk) begin
        if (irq && !clear_keycode) begin
            codes.push_back(keycode);
            clear_keycode <= 1'b1;
        end else
            clear_keycode <= 1'b0;
    end

    task automatic send(input logic [7:0] value);
        @(negedge clk) begin byte_valid = 1'b1; byte_in = value; end
        @(negedge clk) byte_valid = 1'b0;
        repeat (4) @(negedge clk);
    endtask
    // Long enough for the queued bytes to reach the machine: a byte takes 11
    // PS/2 clocks of 80 us, plus the device's idle wait.
    task automatic settle(input int bytes);
        repeat (bytes * 60000 + 20000) @(posedge clk);
    endtask
    task automatic expect_codes(input string what, input logic [7:0] want [$]);
        if (codes.size() != want.size())
            $fatal(1, "%s: %0d codes, expected %0d", what, codes.size(), want.size());
        foreach (want[i])
            if (codes[i] !== want[i]) $fatal(1, "%s: code %0d is %h, expected %h", what, i, codes[i], want[i]);
        codes.delete();
    endtask

    initial begin
        repeat (5) @(negedge clk);
        reset = 1'b0;
        repeat (100) @(negedge clk);

        // Keyboard reset by the BIOS: bit 6 low, then high.
        port_b6 = 1'b0;
        repeat (20000) @(negedge clk);
        port_b6 = 1'b1;
        settle(4);
        expect_codes("reset", '{8'hAA});

        // A make and a break.
        send(8'h1C);
        settle(1);
        expect_codes("A make", '{8'h1E});
        send(8'hF0); send(8'h1C);
        settle(2);
        expect_codes("A break", '{8'h9E});

        // The physical keyboard's replies are not passed on.
        send(8'hAA); send(8'hFA);
        settle(2);
        expect_codes("keyboard replies", '{});

        // F12 alone reaches the machine: its release toggles the pause.
        if (pause_core) $fatal(1, "paused before F12");
        send(8'h07); send(8'hF0); send(8'h07);
        settle(3);
        if (!pause_core) $fatal(1, "F12 did not pause the machine");
        send(8'h07); send(8'hF0); send(8'h07);
        settle(3);
        if (pause_core) $fatal(1, "second F12 did not resume the machine");
        expect_codes("F12", '{});

        // Win+F12: the Windows key passes, F12 and its release do not.
        send(8'hE0); send(8'h1F);                // left Win down
        send(8'h07); send(8'hF0); send(8'h07);   // F12, the OSD's
        send(8'hE0); send(8'hF0); send(8'h1F);   // left Win up
        settle(5);
        if (pause_core) $fatal(1, "Win+F12 reached the machine");
        // KFPS2KB has no E0 handling: E0 is passed as a code, as on MiSTer.
        expect_codes("Win+F12", '{8'hE0, 8'h5B, 8'hE0, 8'hDB});

        // The OSD opens with Win down and closes before it is released:
        // the next F12 is the machine's.
        send(8'hE0); send(8'h27);                // right Win down
        osd_open = 1'b1;
        repeat (100) @(negedge clk);
        osd_open = 1'b0;
        repeat (100) @(negedge clk);
        send(8'h07); send(8'hF0); send(8'h07);
        settle(5);
        if (!pause_core) $fatal(1, "F12 after the OSD closed did not reach the machine");
        codes.delete();

        $display("PS2_KBD_RELAY_TEST_PASS");
        $finish;
    end

    initial begin
        #200ms;
        $fatal(1, "timeout");
    end
endmodule
