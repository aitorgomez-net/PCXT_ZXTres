// Testbench for zxtres_linedouble: a CGA-like 912x262 picture (200 lines
// active) at a fourth of the clock, +HSync/-VSync as the core makes them,
// and a 350-line picture at the 16.257 MHz dot rate (3-4 clocks per dot).
// Reports the line period and the lines per frame at the output.
`timescale 1ns/1ps

module zxtres_linedouble_tb;
    integer lines = 200;
    integer period = 4;       // clocks per dot
    integer off = 0;          // +OFF=1: scandoubler off
    integer vslines = 2;      // +VSLINES=n: the input's VSync, in lines (16 for a CGA's 6845)
    initial begin
        if ($value$plusargs("LINES=%d", lines)) ;
        if ($value$plusargs("PERIOD=%d", period)) ;
        if ($value$plusargs("OFF=%d", off)) ;
        if ($value$plusargs("VSLINES=%d", vslines)) ;
    end

    logic clk = 0;
    always #5 clk = ~clk;
    logic reset = 1;
    initial #200 reset = 0;

    integer phase = 0;
    logic ce;
    always_ff @(posedge clk) begin
        ce <= (phase == 0);
        phase <= phase == period - 1 ? 0 : phase + 1;
    end

    integer h = 0, v = 0, frames = 0;
    logic [5:0] r, g, b;
    logic hb = 1, vb = 1, hs = 0, vs = 1;
    always_ff @(posedge clk) if (ce) begin
        r <= h[5:0] ^ v[5:0]; g <= h[6:1]; b <= v[5:0];
        hb <= h >= 640;
        hs <= h >= 700 && h < 780;
        vb <= v >= lines;
        vs <= !(v >= lines + 10 && v < lines + 10 + vslines);
        if (h == 911) begin
            h <= 0;
            if (v == lines + 61) begin v <= 0; frames <= frames + 1; end
            else v <= v + 1;
        end else h <= h + 1;
    end

    wire [5:0] ro, go, bo;
    wire hbo, vbo, hso, vso, ceo, dbl, hsp, vsp;
    zxtres_linedouble dut (
        .clk(clk), .reset(reset), .ce_in(ce), .off(off[0]),
        .r_in(r), .g_in(g), .b_in(b), .hb_in(hb), .vb_in(vb), .hs_in(hs), .vs_in(vs),
        .r_out(ro), .g_out(go), .b_out(bo), .hb_out(hbo), .vb_out(vbo),
        .hs_out(hso), .vs_out(vso), .ce_out(ceo), .double(dbl), .hs_pin(hsp), .vs_pin(vsp)
    );

    // Measure the output: clocks between HSync pulses, active lines and
    // active dots per frame, and the polarity of the pins.
    integer last_hs = 0, hs_period = 0, now = 0;
    integer out_lines = 0, out_dots = 0, max_dots = 0, lines_frame = 0;
    logic hbo_q = 1, vbo_q = 1, hsp_q = 0;
    // The VSync pulse at the pins, in clocks: the level that is not the one of the picture.
    logic vs_idle_m = 1;
    integer vs_edge = 0, vs_width = 0;
    logic vsp_q = 1;
    always_ff @(posedge clk) begin
        now <= now + 1;
        hsp_q <= hsp;
        vsp_q <= vsp;
        if (ceo && !hbo && !vbo) vs_idle_m <= vsp;
        if (frames >= 3 && frames < 5 && vsp != vsp_q) begin
            if (vsp == vs_idle_m) vs_width <= now - vs_edge;
            else vs_edge <= now;
        end
        if (frames >= 3 && frames < 5) begin
            if (hsp_q != hsp && !hsp) begin hs_period <= now - last_hs; last_hs <= now; end
            if (ceo && !hbo && !vbo) out_dots <= out_dots + 1;
            hbo_q <= hbo; vbo_q <= vbo;
            if (hbo && !hbo_q && !vbo) begin
                lines_frame <= lines_frame + 1;
                if (out_dots > max_dots) max_dots <= out_dots;
                out_dots <= 0;
            end
        end
    end

    initial begin
        wait (frames == 5);
        $display("LINEDOUBLE_TB lines=%0d period=%0d double=%b hs_period_clk=%0d active_lines_in_2_frames=%0d max_dots_per_line=%0d hs_pin_idle=%b vs_pin_idle=%b vs_pin_lines_x10=%0d",
                 lines, period, dbl, hs_period, lines_frame, max_dots, hsp, vsp,
                 hs_period ? vs_width * 10 / hs_period : 0);
        $finish;
    end
endmodule
