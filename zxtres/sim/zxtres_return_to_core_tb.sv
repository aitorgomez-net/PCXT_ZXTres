// The return to the Spectrum core (OSD "Reload ZX core"): DeMiSTify's
// zx3w/return_to_core1.v as the board top uses it, at clk50, against the
// ICAPE2 model of xilinx_clock_models.sv. Nothing reaches ICAP before the
// request; after one clock of request the warm boot (IPROG) is sent with
// WBSTAR 0, the flash address of the Spectrum core.
//
//   zxtres/sim/run_return_to_core_test.sh
`timescale 1ns/1ps
module zxtres_return_to_core_tb;
    reg clk = 1'b0, boot = 1'b0;
    always #10 clk = ~clk;   // 50 MHz
    return_to_core1 dut (.clk(clk), .boot_core(boot));

    initial begin
        #5us;
        if (dut.el_icap.ICAP_i.synced || dut.el_icap.ICAP_i.iprog) begin
            $display("RETURN_TO_CORE_TEST_FAIL: ICAP written before the request");
            $finish;
        end
        @(posedge clk) boot <= 1'b1;
        @(posedge clk) boot <= 1'b0;
        #20us;
        if (dut.el_icap.ICAP_i.iprog && dut.el_icap.ICAP_i.wbstar == 32'h0)
            $display("RETURN_TO_CORE_TEST_PASS");
        else
            $display("RETURN_TO_CORE_TEST_FAIL: synced %0d iprog %0d wbstar %08h",
                     dut.el_icap.ICAP_i.synced, dut.el_icap.ICAP_i.iprog, dut.el_icap.ICAP_i.wbstar);
        $finish;
    end
endmodule
