# The Xe10 BIOS SETUP menu: where each item is stored and what it drives

The PC-9821Xe10's SETUP menu (entered with HELP held at power-up) is code in the user's ROM bank 3 (`BANK3.BIN` 0x2000-0x7FFF,
run as `lcall 0xFA00:0x0000` from the ITF, `BANK4@0x254C`). This page decodes the Xe10 dump's
item table and its accessors, and says, per item, what the ITF does with the value at the next
POST and what this core does with it. It closes part (a) of item 99. The core does not use
SETUP: the OSD's DIP Switch page carries the items that have an effect here (see "The OSD owns
the configuration" below), and every reset re-seeds the stores SETUP would write. Addresses are file offsets
in the 32 KiB bank dumps (`BANK3@0x2EE0` is offset 0x2EE0 of `BANK3.BIN`; the CPU sees a bank at
0xF8000). Facts about the machine below come from the firmware's own code unless a capture or a
reference is named; the "core" column is what this core's RTL does, never evidence of the
machine.

## How SETUP stores a setting

Each item writes up to three places, through the accessor table at `BANK3@0x20A5-0x2321`:

- **The configuration record** in the battery-backed CG RAM, addressed as code 0x5620 row n by
  the helper at `BANK3@0x2322` (A1 = 0x20 + (n >> 4), A3 = 0x56, A5 = n & 0xF): rows 0..0xD are
  CG code 0x2056 rows 0..0xD, rows 0x13/0x14 are code 0x2156 rows 3/4. Rows 1-4 are stored
  INVERTED (the accessors `not al` on both sides) and every write of rows 1-4 re-sums rows 1..9
  into row 0xA (`BANK3@0x21CB`). The ITF validates rows 8/9 = AA55 and the sum before it trusts
  the record (`BANK4@0x4677-0x46B5`).
- **A software-DIP byte** (`0x841E`..`0x8F1E`, bank A unless noted) with its parity bit
  recomputed by the writer (bit 0 for 0x841E, bit 4 for 0x851E, bit 7 for the rest).
- **The software-DIP mirror** in CG RAM (code 0x0156 rows 0x00-0x0B for bank A, 0x20-0x2B for
  bank B), written by the same accessor as the port. The ITF copies the mirror into the ports
  at POST (`BANK4@0x4439-0x4489`).

"Hidden" items have no title and are never drawn; their setters either refuse (`stc`) or keep
the stored bit. The values in the table are the item's value numbers as the getter returns them;
"factory" is what HOME CLR installs (`BANK3@0x09F0-0x0AA0`: record rows 1-9 `c1 8c 81 cd ff 00 00
aa 55`, row 0xC 0x8A, row 0x13 0xB0, row 0x14 0x80, bank A `7c 73 76 3e dc 7f ff 7f 7f 7f 49 98`,
bank B `8f 80 80 ...`).

## The items

### Operating environment (動作環境の設定)

| item | values | stored in | what the ITF does at POST | on this core |
|---|---|---|---|---|
| 16MB system space (１６ＭＢシステム空間) | 0 use (factory), 1 detach | record row 4 bit 3; 0x8F1E bit 0 | `BANK4@0x148A`, `@0x244E`: 0x8F1E bit 0 set -> `out 0x043B, 0x04` (the 15-16 MiB space is RAM); also the memory-size tables (`@0x1DCF`) | 0x043B bit 2 is modelled (`sys16m_en`; its polarity is item 98). Not an OSD field: what it would do rests on the unmeasured polarity. The store holds the factory "use" |
| Sound (サウンド) | 0 not used, 2 used (factory); value 1 "BIOS detached" is a string the Xe10 does not offer | record row 4 bit 1 (stored 1 = off); 0x841E bit 1 (BIOS detach); 0x881E bit 5 (1 = off) | `BANK4@0x293B-0x2A71`: programs the built-in PCM's decoder table through 0x0C24/0x0C2B/0x0C2D (0x0F40, 0xA460, 0x0F48), the codec at 0x0F40/0x0F44/0x0F45/0x0F48 and two chipset registers at 0x0B00/0x0B02; ON with the codec answering its register 0x19: `out 0xA460, 0x73` and 0x0C24 <- C2/C1/C0; OFF: no 0xA460 write and 0x0C24 <- 42/41/40 | not an OSD field: the record, 0x881E and its mirror say "not used" (record row 4 0xCF, 0x881E 0x7C), the Xe10 as found; no codec, so the ITF's codec check fails and it skips the rest (see "The built-in sound"); the -86 board is unaffected |
| Sound interrupt channel (サウンド割り込みチャネル) | 0 INT0, 1 INT1, 2 INT41, 3 INT5 (factory) | record row 0x13 bits 5:4 | the codec's IRQ select in the 0x0F40 write; chipset register 0x5C bit 7 unless INT5 | no codec: no effect. It is not the -86 board's interrupt |
| Microphone volume (マイクボリューム) | 0 OFF (factory), 1-15 | record row 0x13 bits 3:0 | codec registers 4/5 through 0x0F44/0x0F45 (table `BANK3@0x6227`: 0x88 = mute, then 0x12 down to 0x04); SETUP also writes them at once | no codec: no effect |
| ROM BASIC (ＲＯＭ　ＢＡＳＩＣ) | 0 not used, 1 used | record row 4 bit 7; 0x8F1E bit 5 | no reader found in the ITF | not traced |
| 2nd CCU (２ｎｄ　ＣＣＵ) | 0 not used, 1 used; refused while the sound interrupt is INT1 (`BANK3@0x206F`) | record row 0xC bit 3 | not traced (the second serial controller) | no serial port: no effect |
| hidden | 2 each | record row 0x13 bits 6 and 7 | SETUP writes chip register 0x41 bits 1/2 through 0xAC6C/0xAC6E (index 0x5433) | not decoded (open bus) |

### DIP switch 1 (ディップスイッチ１): record row 1, 0x841E

| item | values | bit | the machine's reader | on this core |
|---|---|---|---|---|
| hidden | - | 0, 1 | bit 1 is also the sound BIOS detach | - |
| Plasma display (プラズマディスプレイ), "normally fixed at not used" | 0 used, 1 not used (factory) | 2 | NP2kai `io/printif.c` `prt_i42`: port 0x42 bit 4; the measured 0x841E 0x7C has bit 2 set and 0x42 reads 0x94 (bit 4 set) | 0x42 is a constant: no effect |
| Floppy drive numbering (フロッピィディスク番号) | 0 external first, 1 internal first (factory) | 3 | NP2kai `io/fdc.c` (`dipsw[0] & 8` -> status bit 2, "内蔵優先"); measured bit 3 set and 0x94 = 0x44 | constant: no effect (the core has internal drives only). Not an OSD field |
| Serial transfer mode (シリアル伝送モード) | 0 BCI sync, 1 ST2 sync, 2 sync clock, 3 async (factory); the port byte swaps 1 and 2 | 5:4 | the RS-232C clocking (NP2kai `io/pit.c`); NP2kai `io/mouseif.c` also shows ~bits 5:4 at 0x7FDD bits 1:0 | no serial port; the 0x7FDD bits do follow the byte |
| hidden, fixed 1 | - | 6 | - | - |
| Graphics mode (グラフィックモード) | 0 extended, 16 of 4096 colours (factory), 1 basic, 8 colours | 7 | NP2kai `prt_i42`: port 0x42 bit 3; measured bit 7 clear, 0x42 bit 3 clear | constant: no effect |

### DIP switch 2 (ディップスイッチ２): record row 2, 0x851E

The ITF writes the inverted record row 2 to port 0x31 during its record check
(`BANK4@0x46A9 xor al,0xFF / out 0x31,al`), then merges port 0x31 back into 0x851E
(`BANK4@0x46CC`). With the factory record that byte is 0x73 (5 MHz GDC); qemu-pc98
(`hw/misc/pc98-sys.c` `pc98_sysppi_a_write`) stores that write, NP2kai derives port 0x31 from
the software-DIP bytes instead (`io/dipsw.c`). The machine, measured with XE10CFG
(`docs/probes/XE10CFG-XE10-*.TXT`):

- a write to port 0x31 does not land (`RT 0031 was=F3 wrote=0C got=F3`);
- port 0x31 bit 4 follows a bank-A 0x871E write's bit 5 (`RT 871E ... wrote=1E ... p31=E3 back=3E
  p31=F3`), as NP2kai's 0x871E arm does, but with no parity gate (0x1E is even);
- a bank-A 0x851E write stores only its bit 4 and puts its other bits on port 0x31 (`RT 851E
  was=02 wrote=12 got=12 p31=12 back=02 p31=12`); so after the ITF's merge writes E3 at boot,
  0x851E reads 02 and port 0x31 F3 (`CFG0`), and the store's bits 7:5/3:0 read 02 whatever SETUP
  holds (`CFGS1B`: 02 with port 0x31 = 6B);
- after a reboot or a SETUP change port 0x31 is SETUP's setting again: F3 after the 0x534 reboot
  although a 0x851E write had moved it to 12 (`CFGRB`), 6B after SETUP saved GDC 5 MHz, 20 lines
  and memory switch keep (`CFGS1B`).

The core does the same: port 0x31 starts from the OSD's switches (GDC Clock, Text lines, Memory
switch, Boot order) at every reset and 0x534 reboot and then follows 0x871E bit 5 and 0x851E
writes (`pc9821_iobus.sv`, P31; `tb_pc9821_msw_hold`). Because port 0x31 follows 0x851E, the
DIP mirror's 0x851E cell (CG code 0x0156 row 1) matters too: the ITF's POST copy writes it to
0x851E (`BANK4@0x4439-0x4465`), and the IDE ROM then reads port 0x31 bit 5 as the internal hard
disk switch (`BANK3@0x2F5`; clear, it masks the drives out of 0:055D at `BANK3@0x324` and the
BIOS asks for a system disk). The firmware's writers store port 0x31's image in that cell, with
bit 4 the odd-parity bit (`BANK4@0x4839-0x4849`, `BANK3@0x220B-0x221D`), and the Xa7C9W cell is
such an image (qemu-pc98 `memsw.inc` code 0x01 line 0x01 = 0x73); so the core's restore writes
the OSD's port-0x31 byte there (E3 at the defaults) rather than the port's read-back 02
(`pc9821_cg.sv` CG_MIRROR_BYTES; `tb_pc9821_setup_record`). Where the machine keeps the setting
between boots (the record row 2, as far as the code shows) is not measured: XE10CFG's `0xA9`
reads of code 0x2056 return 00 (item 172).

| item | values | bit | on this core |
|---|---|---|---|
| hidden | - | 0, 2, 6 | - |
| Terminal mode (ターミナルモード指定) | 0 terminal, 1 BASIC (factory) | 1 | port 0x31 bit 1 is fixed at 1. Not an OSD field: no reader of bit 1 in the ITF, the BIOS or the IDE ROM (the one whole-byte reader, `BIOS.ROM@0x50`, stores it at 0:05C0) |
| Text lines (テキスト画面行数) | 0 25 lines (factory), 1 20 lines | 3 | OSD **Text lines**: port 0x31 bit 3 (the BIOS's POST CRT-mode call `BANK7@0x5952-0x5968` and the ITF's `BANK4@0x2695` read it) and record row 2 bit 3 |
| Memory switch (メモリスイッチ) | 0 keep, 1 initialise (factory) | 4; also written to 0x871E bit 5, not to 0x851E (`BANK3@0x1581`, `@0x15F7`) | OSD **Memory switch** (and **Boot order** other than Auto, which needs the hold): port 0x31 bit 4, 0x871E bit 5 and record row 2 bit 4 |
| Internal hard disk (内蔵固定ディスク) | 0 detach, 1 use (factory) | 5 | port 0x31 bit 5 is fixed at 1. Not an OSD field: NP2kai disconnects IDE units 2/3 on "detach" (`pccore.c`), a drive-layout change the core's fixed layout does not offer, and the IDE ROM's reader (`BANK3@0x2F5`) is not decoded |
| GDC clock (ＧＤＣクロック) | 0 5 MHz (factory), 1 2.5 MHz | 7 | OSD **GDC Clock**: port 0x31 bit 7 and record row 2 bit 7 (0x0C at the default 2.5 MHz, the factory 0x8C at 5 MHz). SETUP's getter for the item reads the record (`BANK3@0x37A3`: `call 0x20db / shr al,0x7`), so the Xe10 as found, which SETUP shows at 2.5 MHz, holds bit 7 clear; the ITF's `out 0x31` of the row (`BANK4@0x46A9`, `@0x4AE3`) is ignored by the core |

### DIP switch 3 (ディップスイッチ３): record row 3, 0x861E

| item | values | bit | what the ITF does | on this core |
|---|---|---|---|---|
| Floppy disk mode (フロッピィディスクモード) | 0 640K, 1 auto (640K), 2 1M (factory), 3 auto (1M) | 1:0 | `BANK4@0x1B55`: `out 0xBE, (0xBE & 1) \| 4 \| (0x861E & 2)`; bit 1 also picks the BIOS floppy tables (`@0x1E32`, `@0x1EB5`, `@0x1EFF`). The BIOS's floppy set-up then takes the interface from port 0xBE bit 3 (`BANK7@0x5982-0x598A`: `out 0xBE,0` when it reads 0, 3 when 1) unless the memory switch's boot nibble names one (`@0x5991-0x59A9`). On the machine 0xBE bit 3 is 0x861E bit 1 and bit 2 is NOT 0x861E bit 0 (MAME `fdc_mode_r` reads the same two bits from DSW3), so the item survives POST: 0x861E 76 / F7 / 75 / F4 and 0x00BE FF (FD with a disk in drive 0) / FB / F0 / F4 for 1M / auto (1M) / auto (640K) / 640K, and the two 640K modes put the drives on the 640 KB interface and equip them as 640 KB units (0x500 03 -> 05, 0x55C/0x55D 03/01 -> 00/31, 0x0C8 FF -> 80; `docs/probes/XE10CFG-XE10-CFG*.TXT`, `FDMODE-XE10-FDM*.TXT`) | OSD **Floppy mode**: 0x861E bits 1:0 (the four captured bytes), record row 3 bits 1:0 and the mirror; port 0x00BE bits 3:2 read it back, so POST programs the interface from it as on the machine. Bit 2 is the fixed/auto choice: the fixed modes (1M, 640K) leave the other interface unset at POST (`BANK7@0x7CAE`), as on the machine as found. The OSD's default is auto (1M) (0x861E F7, 0x00BE FB), not the factory and measured 1M: some 2DD boot disks use the other interface and stay black at 1M, and a default is the value that runs the most software ([policies](policies.md#fixed-design-decisions)). The field replaced the earlier FDD mode switch (status[38], 0x00BE bit 2 alone), whose default Auto also read FB. Before this field the core's bit 3 was NP2kai's constant 1, so a core run at 640K read `out 0xBE,04` from the ITF and `out 0xBE,03` from the BIOS |
| hidden | - | 2 | - | - |
| Floppy motor control (フロッピィモータ制御) | 0 off, 1 on (factory; stop after 15 s) | 3 (the port bit is inverted) | the BIOS's motor timer | no motor: no effect |
| DMA clock (ＤＭＡクロック) | 0 fast, 1 compatible (factory) | 4 | `BANK4@0x4B54`: `out 0xF4, 4` (compatible) or 5 (fast) | 0xF4 is read-only: no effect |
| hidden | - | 5 | `BANK4@0x4AA4`: port 0x7FDB bit 6 (the mouse interface mode, item 99(b)) | 0x7FDB ignores it |
| hidden, fixed 1 | - | 6 | - | - |
| CPU mode (ＣＰＵモード) | 0 High (factory), 2 Low | record row 0x14 bits 7/2; 0x8E1E bit 4 cleared; 0x8F1E bit 2 (Low) | `BANK4@0x1610`: Low clears port 0x063F bit 7; `@0x1632`, `@0x1A7C`, `@0x235A` | 0x063F is latched only: no effect (the OSD's CPU Speed slows the CPU instead) |

### Power saving (省電力の設定)

| item | values | stored in | on this core |
|---|---|---|---|
| Internal hard disk motor control (内蔵固定ディスク制御) | 15-60 minutes, or not set (factory) | record row 5 bits 7:4; bank-B 0x841E bits 3:0 | the disk image has no motor: no effect |
| hidden | 16 values | record row 5 bits 3:0; 0x8B1E bits 5:2 | - |

### I/O devices (入出力デバイスの設定)

| item | values | stored in | on this core |
|---|---|---|---|
| Window accelerator (ｳｨﾝﾄﾞｳｱｸｾﾗﾚｰﾀの設定), "only for machines with a window accelerator" | F00, F20, F40, F60 | record row 6 bits 1:0 | no window accelerator: no effect |
| hidden | 2 each | record row 4 bits 2/4 with 0x8F1E bits 6/1, row 6 bit 2, row 0 bit 2, code 0x3056 row 0 bit 5 | - |

## The built-in sound

Measured on the Xe10 (`docs/probes/XE10CFG-XE10-CFGSND.TXT`, `-CFGSNX.TXT`): with Sound "used"
a codec answers at 0x0F40-0x0F48 (`20 FF FF 04 13 08 CC 7F A2`), 0xA460 reads 0x73 and 0x0C24
0xDC, whether the PC-9801-86 board is installed or not; the -86 board's OPNA at 0x188/0x18A then
reads FF and `sndtest` heard nothing (`SNDTEST-XE10-SND.TXT`, the owner's listening check). With
Sound "not used" (the machine as found) 0xA460 reads the -86 board's 0x40 and its OPNA plays. So
this core, which has the -86 board and no codec, is the machine with Sound "not used".

The SETUP item "Sound" is the built-in PCM sound of the PC-9821 line, not the -86 board: its
POST code (`BANK4@0x293B`) programs a WSS-type codec at 0x0F40 (NP2kai models the same decoder
ports as `cbus/cs4231io.c` `csctrl_oc24`/`oc2b`/`oc2d`, its "Mate-X PCM"), and its help text says
to set it to "not used" when a sound board is installed (`BANK3@0x6061`, `@0x60DF`). The
measured Xe10 has it OFF: 0x881E reads 0x7C (`docs/probes/PORTS.TXT`), which is the factory
0xDC with bit 5 (off) and the parity bit flipped, and 0x0F40-0x0F4F read 0xFF. Its -86 board
answers all the same: 0xA460 reads 0x40 and the OPNA at 0x188 works (`docs/probes/OPNA.TXT`,
`docs/probes/XE10T-XE10-OPNA3.TXT`). So switching the item off does not remove the -86 board.

This core has the -86 board and no codec, which is the measured machine's configuration, and
its default configuration says so: the record's row 4 is the factory 0xCD with bit 1 set, 0xCF
(row A, the sum byte, 0xE6 at the defaults: GDC 2.5 MHz and auto (1M); 0x65 for the Xe10 and 0x66 for the Xe at the factory 5 MHz with each table's row 3), and 0x881E and its CG mirror cell
are the measured 0x7C. Only the record bit is read at POST: the ITF reads row 4 through 0xA9
(`BANK4@0x2963-0x2971`: `in al,0xA9 / and al,0x2 / test al,0x2 / jnz`; the Xe's ITF has the same
code at `bios/xe/BANK4.BIN@0x4B78`). With the bit set it skips the read of the interrupt channel
(record row 0x13) and its chipset write, and gives the codec 0 at 0x0F40 (no IRQ select). Both
branches then check for the codec: the ITF reads codec register 0x19 through 0x0F44/0x0F45 and,
when the low three bits are not 0 (`BANK4@0x29C4-0x29D0`), sets two chipset bits and returns
without the `out 0xA460, 0x73` or the final 0x0C24 writes. On the core 0x0F45 reads open bus 0xFF,
so that is the path taken with the item either way, and 0xA460 keeps 0x40, as the machine reads
at the DOS prompt with Sound "not used". Cold-boot I/O logs of `tb_pc9821_userdisk` show both:
with the factory record, `in 0xA9 = CD`, the row 0x13 read (`00` on the core), `out 0xB00,0x5C`
and `out 0xF40,0x08`; with the "not used" record, `in 0xA9 = CF` and `out 0xF40,0x00` with no
row 0x13 read or 0x0B00 write between. From there both are the same: `in 0xF45 = FF` after
`out 0xF44, 0x19`, then only 0x0B00/0x0B02 accesses and no 0xA460 write. The core does not decode 0x0C24/0x0C2B/0x0C2D (writes are ignored and reads
answer open bus 0xFF), where the machine reads 0x5C/0x40/0x0F with Sound "not used"
(`XE10CFG-XE10-CFG0.TXT`); the -86 board's ports do not depend on them. The codec is the Xe10's own: it
answers with the -86 board removed too (`XE10CFG-XE10-CFGSNX.TXT`).

## The Xe10 as found

The owner's machine, photographed in SETUP before the 2026-11-04 session (every page; values as
the menu highlights them):

| page | item | as found |
|---|---|---|
| Operating environment | 16MB system space | use |
| | Sound | not used |
| | Sound interrupt channel | INT5 |
| | Microphone volume | OFF |
| | ROM BASIC | not used |
| | 2nd CCU | used |
| DIP switch 1 | Plasma display | not used |
| | Floppy drive numbering | internal #1, #2 / external #3, #4 |
| | Serial transfer mode | async (調歩同期) |
| | Graphics mode | extended |
| DIP switch 2 | Terminal mode | BASIC mode |
| | Text lines | 25 |
| | Memory switch | initialise |
| | Internal hard disk | use |
| | GDC clock | 2.5 MHz |
| DIP switch 3 | Floppy disk mode | 1M |
| | Floppy motor control | on |
| | DMA clock | compatible |
| | CPU mode | High |
| Power saving | Internal hard disk motor control | not set |
| I/O devices | Window accelerator | F00 |

Every item is the factory value except the GDC clock (factory 5 MHz) and Sound (factory
"used"; 0x881E reads 0x7C, the factory 0xDC with bit 5 and the parity bit flipped). The SETUP changes of the
same session and what each moved are in `docs/probes/README.md` and item 172. With text lines =
20 the DOS prompt still showed 25 lines (owner's observation); the POST screen was not
photographed.

## The OSD owns the configuration

SETUP is not used on this core. The items that have an effect here are fields of the OSD's
DIP Switch page. Each position 0 is the value that runs the most software
([policies](policies.md#fixed-design-decisions)): the measured Xe10's for GDC clock (2.5 MHz,
where SETUP's factory value is 5 MHz), Text lines and Memory switch, and auto (1M) for the
floppy disk mode, where the measured Xe10 and SETUP's factory value are 1M (Sound, which has no
OSD field, is fixed at the Xe10's as-found "not used": see "The built-in sound"):

| SETUP item | OSD field (status bit) | what the field drives |
|---|---|---|
| GDC clock | GDC Clock (32) | port 0x31 bit 7; record row 2 bit 7 |
| Text lines | Text lines (68) | port 0x31 bit 3; record row 2 bit 3 |
| Memory switch | Memory switch (69), and Boot order other than Auto | port 0x31 bit 4; 0x871E bit 5; record row 2 bit 4 |
| Floppy disk mode | Floppy mode (72:71) | 0x861E bits 1:0; record row 3 bits 1:0 (the Xe10 record); 0x00BE bits 3:2 |

The other items are not offered: the built-in sound, its interrupt and the microphone (no
codec), the serial transfer mode and the 2nd CCU (no serial port), the window accelerator, the
power-saving timer and floppy motor control (no such hardware), CPU mode (port 0x063F is latched
only; the OSD's CPU Speed slows the CPU instead), DMA clock (port 0xF4 is read-only), ROM BASIC
(no reader found), the plasma display and graphics mode (port 0x42 is a constant on the core and
their BIOS use is not traced), floppy drive numbering (internal drives only), terminal mode (no
reader), the internal hard disk (the drive layout is fixed) and the 16MB system space (item 98).

The fields are latched at the machine reset (the OSD Reset, a hard-disk mount or eject, a core
load). pc9821_iobus builds the software-DIP seed and port 0x31 from those latches and passes
them to pc9821_cg (`setup_cfg`), whose configuration record and software-DIP mirror are built from
the same bytes. The store and the mirror are re-written, and the record's write echo cleared:

- at the machine-reset assertion, and again if a field changes while the reset is held (a core
  load's saved config arrives after the assertion);
- at the guest's reboot, the 0x534 soft reset - SETUP's exit (`BANK4@0x2574`) and the BIOS reset
  entry's reboot (`BANK7@0xFD81F`). A warm CPU reset that resumes a program (`out 0xF0`, a triple
  fault) re-writes nothing, so a program's own writes survive it.

So whatever SETUP or another program writes into the record, the store or the mirror lasts until
the next reset and is then the OSD's configuration again; on the machine these are battery-backed
and keep it. The record is read through the static view (`pc9821_cg.sv`), which a CPU reset's
echo clear returns to the OSD's rows. A mid-run OSD change applies at the next machine reset, not
at a guest reboot. tb_pc9821_setup_osd and tb_pc9821_setup_record pin all of this.

The same walk also clears the length word of the port table the ITF saves in CG RAM. The ITF
writes that table from code 0x5610 up (`BANK4@0x2136`) and keeps it while the length is non-zero
(`BANK4@0x1D34`). Every POST's KANJI CG-RAM test zeroes the part of the table past code 0x5620
(`BANK4@0x0076`). With the length kept, the next boot failed the table check and installed the
factory DIP image (`BANK4@0x47B2`) on every second reset. That gave the 1 MB floppy interface,
port 0x31 = 73 and Sound "used" whatever the OSD said (item 181).
