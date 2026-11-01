# MiSTer SDRAM DQM wiring

How the byte mask reaches the SDRAM on the MiSTer module, and the per-command contract the
controller (`src/memory/sdram.v`) honours. The PEGC packed-store path relies on it for masked byte
writes (trade candidate T23).

## 1. The module

The MiSTer 128 MB SDRAM add-on (the "XSDS" board and compatible boards) is **2 x AS4C32M16SB**,
two x16 chips of 64 MB each:

| property | value |
|---|---|
| per chip | 4 banks x 8192 rows x 1024 columns x 16 bits |
| bus width | 16 bits (DQ[15:0]) |
| CKE | tied to VCC on the board (no power-down or self-refresh) |
| CS | one connector line `CS1`; `CS2 = ~CS1` through an on-board inverter |

Sources: the official schematic (`MiSTer-devel/Hardware_MiSTer`, `releases/sdram_xsds_3.0.pdf`),
whose net labels connect both chips' `DQML`/`DQMH` to `A11`/`A12` at the connector;
`birdybro/SDRAMsim_MiSTer`'s `CONTROLLER_GUIDE.md` and its model
`xsds_128mbyte_sdram_model.sv` (`wire chip_ldqm = Addr[11]; wire chip_udqm = Addr[12];`); and
JTFRAME's `jtframe_sdram_bank_core.v`, whose `ADQM` mode is the same scheme
(`assign {sdram_dqmh, sdram_dqml} = ADQM ? sdram_a[12:11] : dqm;`, selected under `MISTER`).

## 2. DQM is carried on A[11]/A[12]

There is no separate DQM pin: a controller masks bytes by putting the mask on `A[12:11]` during the
command. `sdram.v` drives `SDRAM_DQML`/`DQMH` from `dqm_a`, a register twin of `a[12:11]` (a
simulation assertion holds the two equal every cycle).

## 3. The per-command A[12:11] contract

| command | A[12:11] carries | notes |
|---|---|---|
| ACT | row bits A12/A11 | DQM is don't-care (no data transfer) |
| READ | `00` | DQM has a 2-clock output-mask latency; this core never masks reads |
| WRITE | byte mask `{UDQM, LDQM}` | active high (1 = mask); captured with the write data |
| PRE | don't-care | A10 = all banks |
| MRS | `00` | per the datasheet |

## 4. The controller as built

The top level builds the controller with `ADQM = 1` (`z486_mister.sv`, `.ADQM(1'b1)`): a partial
store is ONE masked WRITE, and the same-row gather sessions carry each slot's mask the same way.
With `ADQM = 0` (the parameter's default, for a module without the tie) a partial write takes
`RMW_READ -> RMW_ACT -> WRITE`, a read and a re-activated merge write. The core supports 128 MB
modules with the standard tie only.

## 5. Verification

- `tests/pc9821/sdram_chip_model.sv` ties `LDQM = A[11]`, `UDQM = A[12]` and applies the mask on
  the WRITE command edge, so a masked-write bench is not vacuous.
- `tb_pc9821_sdram_adqm`: a masked WRITE changes exactly the enabled bytes for every byte-enable
  pattern, and the mask on `A[12:11]` does not alias a row.
