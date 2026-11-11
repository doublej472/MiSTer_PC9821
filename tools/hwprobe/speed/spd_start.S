/* spd_start.S - SPEED.COM's entry into the gate's Dhrystone (src/z486/tests/dhrystone).
 *
 * The gate's startup.S reports through the bench's ports (0xE4 data, 0xE0 verdict) and halts;
 * a real PC-98 has no such ports, so SPEED supplies its own entry instead: it calls the gate's
 * unchanged dhrystone_main and hands its return value (0 = the program's own validation
 * passed, else 0xD00000xx = the first failed check) to SPEED's loader through INT 41h. The two
 * MARK_START/MARK_END port writes inside dhrystone_main (`out 0xE4,eax`, E7 E4) are turned
 * into INT 40h (CD 40) in the linked image by mkblob.py, which refuses an image where it does
 * not find exactly two of them; the C sources and flags are the gate's own.
 */
    .section .text.start, "ax"
    .code32
    .global _start
    .extern dhrystone_main
_start:
    cld
    call dhrystone_main
    int $0x41
1:  jmp 1b
