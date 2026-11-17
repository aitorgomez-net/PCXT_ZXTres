// The physical PS/2 keyboard of the ZXTRES+ to the PC/XT machine's keyboard
// port, which expects the PS/2 device that MiSTer's hps_io emulates.
//
// The machine's keyboard converter (KFPS2KB) takes the wires of a PS/2
// keyboard: it holds the clock low while a scan code waits to be read and
// sends a reset (FFh) when the BIOS releases the keyboard. On MiSTer these
// wires come from hps_io's ps2_device, fed by the HPS. Here the bytes of the
// real keyboard (zxtres_ps2_rx) go through a filter into the same kind of
// device, which talks to the machine on its own lines:
//
//   - Win+F12 opens the OSD (the controller watches the same keyboard), so an
//     F12 pressed while either Windows key is down is not passed on, nor is
//     its release, as MiSTer's F12KEYMOD does: F12 alone stays with the
//     machine, which pauses on it. The prefixes of a code (E0, F0) are held
//     until the code itself arrives, so a dropped F12 leaves no stray F0.
//   - The keyboard's own replies (BAT AAh, ACK FAh, echo, resend, errors) are
//     not passed on: the commands of the machine are answered here, FAh for
//     each byte and FAh AAh for a reset, as the HPS answers them on MiSTer.
//     The physical keyboard keeps the settings of the controller.
//   - The keyboard is hidden from the machine while the OSD is open
//     (osd_open), so whatever the Windows keys did meanwhile is unknown: when
//     the OSD closes they count as up again.
//
// The device logic is MiSTer's ps2_device (sys/hps_io.sv, Sorgelig, GPL v3),
// clocked at about 12.5 kHz as hps_io does with PS2DIV 2000 on 50 MHz.
`timescale 1ns/1ps
module zxtres_ps2_kbd_relay #(
    parameter int unsigned PS2DIV = 2000,
    parameter int unsigned FIFO_BITS = 5
) (
    input  logic       clk,
    input  logic       reset,
    input  logic       osd_open,
    input  logic       byte_valid,     // a byte from the physical keyboard
    input  logic [7:0] byte_in,

    input  logic       host_clk,       // the machine's drive of the clock line (0: low)
    input  logic       host_dat,       // and of the data line
    output logic       dev_clk,        // the keyboard lines the machine reads
    output logic       dev_dat
);
    // ------------------------------------------------------------------
    // Filter: whole codes, with their prefixes, into the queue.
    logic       ext_q, brk_q;
    logic [2:0] skip_q;                 // bytes of an E1 sequence still to pass
    logic       lwin_q, rwin_q;
    logic       menu_f12_q;
    logic       osd_open_q;

    // Up to three bytes of one code to push: E0, F0, code.
    logic [7:0] push_byte [0:2];
    logic [1:0] push_count, push_index;
    logic       pushing;

    wire is_f12  = !ext_q && byte_in == 8'h07;
    wire is_lwin = ext_q && byte_in == 8'h1F;
    wire is_rwin = ext_q && byte_in == 8'h27;

    // Responses to the machine's commands, pushed after the codes.
    logic       resp_pending;
    logic [7:0] resp_byte [0:2];
    logic [1:0] resp_count, resp_index;

    // ps2_device interface
    logic [7:0] wdata;
    logic       we;
    wire  [8:0] rdata;
    logic       rd;

    always_ff @(posedge clk) begin
        osd_open_q <= osd_open;
        we <= 1'b0;
        rd <= 1'b0;
        if (reset) begin
            ext_q <= 1'b0;
            brk_q <= 1'b0;
            skip_q <= '0;
            lwin_q <= 1'b0;
            rwin_q <= 1'b0;
            menu_f12_q <= 1'b0;
            pushing <= 1'b0;
            resp_pending <= 1'b0;
        end else begin
            if (osd_open_q && !osd_open) begin
                lwin_q <= 1'b0;
                rwin_q <= 1'b0;
                menu_f12_q <= 1'b0;
                ext_q <= 1'b0;
                brk_q <= 1'b0;
            end else if (byte_valid && !pushing) begin
                if (skip_q != '0) begin
                    skip_q <= skip_q - 3'd1;
                    push_byte[0] <= byte_in;
                    push_count <= 2'd1;
                    push_index <= 2'd0;
                    pushing <= 1'b1;
                end else begin
                    case (byte_in)
                        8'hE0: ext_q <= 1'b1;
                        8'hF0: brk_q <= 1'b1;
                        8'hE1: begin                 // E1 14 77 E1 F0 14 F0 77
                            skip_q <= 3'd7;
                            push_byte[0] <= 8'hE1;
                            push_count <= 2'd1;
                            push_index <= 2'd0;
                            pushing <= 1'b1;
                        end
                        8'h00, 8'hAA, 8'hEE, 8'hFA, 8'hFC, 8'hFD, 8'hFE, 8'hFF: ;
                        default: begin
                            if (is_lwin) lwin_q <= !brk_q;
                            if (is_rwin) rwin_q <= !brk_q;
                            if (is_f12 && !brk_q && (lwin_q || rwin_q))
                                menu_f12_q <= 1'b1;          // Win+F12: the OSD's
                            else if (is_f12 && brk_q && menu_f12_q)
                                menu_f12_q <= 1'b0;
                            else begin
                                // E0 first, then F0, then the code
                                if (ext_q && brk_q) begin
                                    push_byte[0] <= 8'hE0;
                                    push_byte[1] <= 8'hF0;
                                    push_byte[2] <= byte_in;
                                    push_count <= 2'd3;
                                end else if (ext_q || brk_q) begin
                                    push_byte[0] <= ext_q ? 8'hE0 : 8'hF0;
                                    push_byte[1] <= byte_in;
                                    push_count <= 2'd2;
                                end else begin
                                    push_byte[0] <= byte_in;
                                    push_count <= 2'd1;
                                end
                                push_index <= 2'd0;
                                pushing <= 1'b1;
                            end
                            ext_q <= 1'b0;
                            brk_q <= 1'b0;
                        end
                    endcase
                end
            end

            // A command from the machine: take it and queue the answer.
            if (rdata[8] && !rd && !resp_pending) begin
                rd <= 1'b1;
                resp_pending <= 1'b1;
                resp_index <= 2'd0;
                case (rdata[7:0])
                    8'hFF: begin                     // reset: ACK, BAT passed
                        resp_byte[0] <= 8'hFA;
                        resp_byte[1] <= 8'hAA;
                        resp_count <= 2'd2;
                    end
                    8'hF2: begin                     // read ID: ACK, MF2 keyboard
                        resp_byte[0] <= 8'hFA;
                        resp_byte[1] <= 8'hAB;
                        resp_byte[2] <= 8'h83;
                        resp_count <= 2'd3;
                    end
                    8'hEE: begin                     // echo
                        resp_byte[0] <= 8'hEE;
                        resp_count <= 2'd1;
                    end
                    default: begin
                        resp_byte[0] <= 8'hFA;
                        resp_count <= 2'd1;
                    end
                endcase
            end else if (resp_pending && !rdata[8] && !rd && !we) begin
                // The device takes a byte only while it holds no command.
                wdata <= resp_byte[resp_index];
                we <= 1'b1;
                if (resp_index + 2'd1 == resp_count)
                    resp_pending <= 1'b0;
                resp_index <= resp_index + 2'd1;
            end else if (pushing && !resp_pending && !rdata[8] && !we) begin
                wdata <= push_byte[push_index];
                we <= 1'b1;
                if (push_index + 2'd1 == push_count)
                    pushing <= 1'b0;
                push_index <= push_index + 2'd1;
            end
        end
    end

    // ------------------------------------------------------------------
    // The PS/2 clock of the device: it toggles every PS2DIV clocks, as in
    // hps_io (12.5 kHz from 50 MHz).
    logic [$clog2(PS2DIV+1)-1:0] div_q = '0;
    logic                        clk_ps2 = 1'b0;
    always_ff @(posedge clk) begin
        if (div_q == PS2DIV[$bits(div_q)-1:0] - 1) begin
            div_q <= '0;
            clk_ps2 <= !clk_ps2;
        end else begin
            div_q <= div_q + 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // ps2_device of MiSTer's hps_io.sv.
    logic [7:0] fifo [0:(1<<FIFO_BITS)-1];
    logic [FIFO_BITS-1:0] wptr = '0, rptr = '0;
    logic [2:0] rx_state = '0;
    logic [3:0] tx_state = '0;
    logic       has_data = 1'b0;
    logic [7:0] data;
    assign rdata = {has_data, data};

    logic [7:0] tx_byte;
    logic       parity;
    logic       old_clk;
    logic [1:0] timeout;
    logic [3:0] rx_cnt;
    logic       c1, c2, d1;

    always_ff @(posedge clk) begin
        if (we && !has_data) begin
            fifo[wptr] <= wdata;
            wptr <= wptr + 1'd1;
        end

        if (rd) has_data <= 1'b0;

        c1 <= host_clk;
        c2 <= c1;
        d1 <= host_dat;
        if (rx_state == 3'd0 && tx_state == 4'd0 && !c2 && c1 && !d1) begin
            rx_state <= rx_state + 1'b1;
            dev_dat <= 1'b1;
        end

        old_clk <= clk_ps2;
        if (!old_clk && clk_ps2) begin
            if (rx_state != 3'd0) begin
                case (rx_state)
                    3'd1: begin
                        rx_state <= rx_state + 1'b1;
                        rx_cnt <= 4'd0;
                    end
                    3'd2: begin
                        if (rx_cnt <= 4'd7) data <= {d1, data[7:1]};
                        else rx_state <= rx_state + 1'b1;
                        rx_cnt <= rx_cnt + 1'b1;
                    end
                    3'd3: if (d1) begin
                        rx_state <= rx_state + 1'b1;
                        dev_dat <= 1'b0;
                    end
                    3'd4: begin
                        dev_dat <= 1'b1;
                        has_data <= 1'b1;
                        rx_state <= 3'd0;
                        rptr <= '0;
                        wptr <= '0;
                    end
                    default: rx_state <= 3'd0;
                endcase
            end else begin
                if (tx_state == 4'd0) begin
                    if (c2 && c1 && d1 && wptr != rptr) begin
                        timeout <= timeout - 1'd1;
                        if (timeout == 2'd0) begin
                            tx_byte <= fifo[rptr];
                            rptr <= rptr + 1'd1;
                            parity <= 1'b1;
                            tx_state <= 4'd1;
                            dev_dat <= 1'b0;             // start bit
                        end
                    end
                end else begin
                    if (tx_state >= 4'd1 && tx_state < 4'd9) begin
                        dev_dat <= tx_byte[0];
                        tx_byte[6:0] <= tx_byte[7:1];
                        if (tx_byte[0])
                            parity <= !parity;
                    end
                    if (tx_state == 4'd9) dev_dat <= parity;
                    if (tx_state == 4'd10) dev_dat <= 1'b1;   // stop bit
                    if (tx_state < 4'd11) tx_state <= tx_state + 1'd1;
                    else tx_state <= 4'd0;
                end
            end
        end

        if (!old_clk && clk_ps2) dev_clk <= 1'b1;
        if (old_clk && !clk_ps2) dev_clk <= (tx_state == 4'd0) && (rx_state < 3'd2);

        if (reset) begin
            rx_state <= '0;
            tx_state <= '0;
            has_data <= 1'b0;
            wptr <= '0;
            rptr <= '0;
            dev_clk <= 1'b1;
            dev_dat <= 1'b1;
        end
    end
endmodule
