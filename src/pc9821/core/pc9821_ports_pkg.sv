// Shared pc9821 I/O fabric decode constants.
//
// The 110 one-hot `hit[]` decode indices and the iobus access-FSM states were
// module `localparam`s in pc9821_iobus.sv. Module localparams are not reachable
// through the instance hierarchy, so white-box benches had to hardcode raw
// integers (`dut.hit[182]`, `dut.state == 3'd1`); those go stale the moment a
// lane inserts a decode entry (the hit[181] -> hit[182] shift fixed in
// tb_pc9821_mouse.sv). They live here so benches name them instead.
//
// hit[] is the SYSTEM-port set only. The device ports (0x0000-0xA46E and the
// MPU-PC98II's 0xE0D0/0xE0D2) are not in it: pc9821_device_select owns that claim
// (dev_bus_cs) and pc9821_iobus instantiates it.
package pc9821_ports_pkg;
  // The iobus access FSM states.
  localparam [2:0] S_IDLE    = 3'd0;
  localparam [2:0] S_BYTE    = 3'd1;
  localparam [2:0] S_FLUSH   = 3'd2;
  localparam [2:0] S_REPLY   = 3'd3;
  localparam [2:0] S_HOLD    = 3'd4;
  localparam [2:0] S_DEVWAIT = 3'd5;
  localparam [2:0] S_IOWAIT  = 3'd6;

  // hit[] one-hot decode indices: system ports ascending in hit[0..109].
  localparam int HX_0001 = 0, HX_0003 = 1, HX_0005 = 2;
  localparam int HX_0007 = 3, HX_0009 = 4, HX_000B = 5, HX_000D = 6, HX_000F = 7, HX_0011 = 8, HX_0019 = 9, HX_001B = 10;
  localparam int HX_0021 = 11, HX_0023 = 12, HX_0025 = 13, HX_0027 = 14, HX_0029 = 15, HX_0031 = 16, HX_0032 = 17, HX_0033 = 18;
  localparam int HX_0035 = 19, HX_0037 = 20, HX_0040 = 21, HX_0042 = 22, HX_0044 = 23, HX_005C = 24, HX_005D = 25, HX_005E = 26;
  localparam int HX_005F = 27, HX_006C = 28, HX_0090 = 29, HX_0092 = 30, HX_0094 = 31, HX_00A7 = 32, HX_00BE = 33, HX_00BF = 34;
  localparam int HX_00C8 = 35, HX_00CA = 36, HX_00CC = 37, HX_00F0 = 38, HX_00F1 = 39, HX_00F2 = 40, HX_00F4 = 41, HX_00F6 = 42;
  localparam int HX_0134 = 43, HX_0149 = 44, HX_0434 = 45, HX_0436 = 46, HX_0439 = 47, HX_043B = 48, HX_043D = 49, HX_043F = 50;
  localparam int HX_0461 = 51, HX_0463 = 52, HX_04A0 = 53, HX_04A1 = 54, HX_04A2 = 55, HX_04A3 = 56, HX_04A4 = 57, HX_04A5 = 58;
  localparam int HX_04A6 = 59, HX_04A7 = 60, HX_04A8 = 61, HX_04A9 = 62, HX_04AA = 63, HX_04AB = 64, HX_04AC = 65, HX_04AD = 66;
  localparam int HX_04AE = 67, HX_04AF = 68, HX_04BE = 69, HX_0530 = 70, HX_0531 = 71, HX_0534 = 72, HX_053D = 73, HX_053E = 74;
  localparam int HX_0567 = 75, HX_0610 = 76, HX_0611 = 77, HX_063C = 78, HX_063D = 79, HX_063E = 80, HX_063F = 81, HX_09A0 = 82;
  localparam int HX_09A8 = 83, HX_09AE = 84, HX_0E00 = 85, HX_0E02 = 86, HX_0E05 = 87, HX_0E07 = 88, HX_0E09 = 89, HX_0E0B = 90;
  localparam int HX_0E0F = 91, HX_0EE0 = 92, HX_0FAA = 93, HX_0FAB = 94, HX_0FAC = 95, HX_18F0 = 96, HX_18F1 = 97, HX_18F2 = 98;
  localparam int HX_18F3 = 99, HX_1E8E = 100, HX_7FD9 = 101, HX_7FDB = 102, HX_7FDD = 103, HX_7FDF = 104, HX_9892 = 105, HX_9894 = 106;
  localparam int HX_98D7 = 107, HX_A460 = 108, HX_BFDB = 109;
endpackage
