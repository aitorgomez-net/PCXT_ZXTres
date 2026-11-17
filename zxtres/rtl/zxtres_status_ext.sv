// Status bits 64-127 from the controller, beside MiST user_io's 0-63.
//
// The firmware (zxtres/firmware/statusword.c) sends the whole 128-bit
// status word with user_io's command 1Eh, sixteen bytes, low byte first.
// user_io keeps the first eight (its status output, bits 0-63) and ignores
// the rest; this module listens to the same SPI transfer and keeps bytes 9
// to 16 as bits 64-127. It reads the bus as user_io does: SPI_SS_IO low for
// a transfer, MOSI sampled on the rising edge of SPI_CLK, most significant
// bit first, the first byte the command.
//
// The bytes are counted, and the command kept, in the SPI clock domain,
// where SPI_SS_IO resets them at once, so transfers may follow each other
// closely. Each byte of 9 to 16 of a 1Eh transfer goes to clk_sys with its
// position, through a toggle; the next byte takes eight SPI clocks, long
// enough for clk_sys to take this one.
`timescale 1ns/1ps
module zxtres_status_ext (
    input  logic        clk_sys,
    input  logic        SPI_CLK,
    input  logic        SPI_SS_IO,
    input  logic        SPI_MOSI,
    output logic [63:0] status_ext = '0
);
    // SPI clock domain.
    logic [2:0] bit_cnt = '0;
    logic [4:0] byte_cnt = '0;          // bytes of this transfer so far
    logic [6:0] sbuf;
    logic [7:0] cmd;
    logic [7:0] ext_byte;               // a byte of bits 64-127
    logic [2:0] ext_slot;               // its position, 0 for bits 64-71
    logic       ext_toggle = 1'b0;

    wire  [7:0] byte_now = {sbuf, SPI_MOSI};

    always_ff @(posedge SPI_CLK or posedge SPI_SS_IO) begin
        if (SPI_SS_IO) begin
            bit_cnt <= '0;
            byte_cnt <= '0;
        end else begin
            bit_cnt <= bit_cnt + 3'd1;
            if (bit_cnt != 3'd7)
                sbuf <= {sbuf[5:0], SPI_MOSI};
            else begin
                if (byte_cnt != 5'd31)
                    byte_cnt <= byte_cnt + 5'd1;
                if (byte_cnt == 5'd0)
                    cmd <= byte_now;
                else if (cmd == 8'h1E && byte_cnt >= 5'd9 && byte_cnt <= 5'd16) begin
                    ext_byte <= byte_now;
                    ext_slot <= 3'(byte_cnt - 5'd9);
                    ext_toggle <= !ext_toggle;
                end
            end
        end
    end

    // clk_sys domain.
    logic [2:0] toggle_sync = '0;
    always_ff @(posedge clk_sys) begin
        toggle_sync <= {toggle_sync[1:0], ext_toggle};
        if (toggle_sync[2] != toggle_sync[1])
            status_ext[ext_slot * 8 +: 8] <= ext_byte;
    end
endmodule
