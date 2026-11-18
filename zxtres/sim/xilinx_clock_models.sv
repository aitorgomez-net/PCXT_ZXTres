// Behavioural stand-ins for the Xilinx clock primitives the ZXTRES
// designs use, for fast simulation (the unisim MMCM model is very slow in
// xsim). Only the parameters and outputs the designs use are modelled:
// CLKOUT0, CLKOUT1 and CLKOUT2 at CLKIN1 * CLKFBOUT_MULT_F / DIVIDE, LOCKED
// after 1 us. The outputs start together, so outputs of one VCO whose half
// periods are whole picoseconds stay in phase (the video MMCM's 114.5, 57.3
// and 28.6 MHz); other phase relationships are not modelled.
`timescale 1ns/1ps
module MMCME2_BASE #(
    parameter real CLKIN1_PERIOD = 10.0,
    parameter int  DIVCLK_DIVIDE = 1,
    parameter real CLKFBOUT_MULT_F = 5.0,
    parameter real CLKOUT0_DIVIDE_F = 1.0,
    parameter int  CLKOUT1_DIVIDE = 1,
    parameter int  CLKOUT2_DIVIDE = 1
) (
    input  wire CLKIN1, CLKFBIN, PWRDWN, RST,
    output wire CLKFBOUT, CLKFBOUTB,
    output reg  CLKOUT0 = 1'b0,
    output wire CLKOUT0B,
    output reg  CLKOUT1 = 1'b0,
    output reg  CLKOUT2 = 1'b0,
    output wire CLKOUT1B, CLKOUT2B, CLKOUT3, CLKOUT3B, CLKOUT4, CLKOUT5, CLKOUT6,
    output reg  LOCKED = 1'b0
);
    localparam real VCO_PERIOD = CLKIN1_PERIOD * DIVCLK_DIVIDE / CLKFBOUT_MULT_F;
    localparam real HALF0 = VCO_PERIOD * CLKOUT0_DIVIDE_F / 2.0;
    localparam real HALF1 = VCO_PERIOD * CLKOUT1_DIVIDE / 2.0;
    localparam real HALF2 = VCO_PERIOD * CLKOUT2_DIVIDE / 2.0;

    initial begin
        #1000 LOCKED = 1'b1;
    end
    always #(HALF0) CLKOUT0 = !CLKOUT0;
    always #(HALF1) CLKOUT1 = !CLKOUT1;
    always #(HALF2) CLKOUT2 = !CLKOUT2;

    assign CLKFBOUT = CLKIN1;
    assign {CLKFBOUTB, CLKOUT0B, CLKOUT1B, CLKOUT2B, CLKOUT3, CLKOUT3B,
            CLKOUT4, CLKOUT5, CLKOUT6} = '0;
endmodule

module BUFG (input wire I, output wire O);
    assign O = I;
endmodule

// ODDR as used for forwarded clocks: SAME_EDGE, D1 on the rising edge and
// D2 on the falling edge of C.
module ODDR #(
    parameter DDR_CLK_EDGE = "SAME_EDGE",
    parameter INIT = 1'b0,
    parameter SRTYPE = "SYNC"
) (
    output reg  Q = INIT,
    input  wire C, CE, D1, D2, R, S
);
    always @(posedge C) if (CE) Q <= D1;
    always @(negedge C) if (CE) Q <= D2;
endmodule

// ICAPE2 as the multiboot logic uses it: 32-bit writes only. The words are
// bit-reversed within each byte on I, as on the device, and are put back
// here. The model follows the configuration packets far enough to see the
// warm boot: the sync word, a write of WBSTAR and the IPROG command (CMD
// register, value 0Fh). `iprog` and `wbstar` tell the testbench what
// happened; the reconfiguration itself is not modelled.
module ICAPE2 #(
    parameter ICAP_WIDTH = "X32",
    parameter DEVICE_ID = 32'h0,
    parameter SIM_CFG_FILE_NAME = "NONE"
) (
    output wire [31:0] O,
    input  wire        CLK, CSIB, RDWRB,
    input  wire [31:0] I
);
    assign O = '0;
    bit        synced = 0, iprog = 0;
    bit [31:0] wbstar = '1;
    bit [4:0]  reg_addr;     // register of the pending type 1 write
    bit        pending = 0;
    function automatic [31:0] unswap(input [31:0] v);
        for (int i = 0; i < 32; i++) unswap[(i / 8) * 8 + 7 - i % 8] = v[i];
    endfunction
    always @(posedge CLK) if (!CSIB && !RDWRB) begin
        automatic bit [31:0] w = unswap(I);
        if (!synced) begin
            if (w == 32'hAA995566) synced <= 1;
        end else if (pending) begin
            pending <= 0;
            if (reg_addr == 5'h10) wbstar <= w;
            if (reg_addr == 5'h04 && w[4:0] == 5'h0F && !iprog) begin
                iprog <= 1;
                $display("[ICAPE2] IPROG, warm boot from WBSTAR %08h", wbstar);
            end
        end else if (w[31:29] == 3'b001 && w[28:27] == 2'b10 && w[10:0] == 11'd1) begin
            reg_addr <= w[17:13];   // type 1 write of one word
            pending  <= 1;
        end
    end
endmodule
