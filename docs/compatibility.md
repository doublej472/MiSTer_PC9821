# Compatibility

What has been run on the core, and what it needed. Every title and program here was started on
real MiSTer hardware (or, for a few noted ones, in simulation) and judged from screenshots; audio
was judged only where a row says so. A title that was never run is not listed.

## How to read it

- **Firmware:** all results are for the NEC Xe10 firmware set. The Xe set does not run yet.
- **Build:** the list was last checked against the core build of 2026-10-31. Most titles were
  run in the 2026-10-20 to 2026-10-28 sweeps on earlier builds; the release run on the
  2026-10-31 build, on a DE10-Nano card and a MiSTer Pi card, re-ran a sample of the titles and
  added a further set. Titles outside that sample were not re-run on it. A "fixed" note gives
  the date the fix landed.
- **Status:**
  - **works**: reached the title, menu or game and it looked right.
  - **works with notes**: runs, but needs a specific driver, memory-manager setup, key or extra disk
    (shown in the note). Disk and key prompts are the title's own and are normal.
  - **partial**: reached something, but stopped short or was not taken further.
  - **fails**: does not run. The note says whether it is an open core bug or not.
  - **not a core bug**: the title does not start for a reason outside the core: a data disk that
    is not bootable, a title that fails the same way on other emulators or on a 286+ CPU, or a
    set that was not complete.
- **Media:** *HDD image* is a hard-disk image booted on the core; *CD* is a CD image mounted in
  the CD slot with a hard-disk image to boot from (MSCDEX plus a CD driver); *CD + boot floppy*
  boots from the title's own CD boot disk instead; *Floppy* is one or
  more floppy images (D88/HDM). Most hard-disk images must be converted first (see the README).
- Many floppy titles ask for another disk during play; mount it from the OSD (FDD1/FDD2).
- A non-bootable data floppy left in a drive at boot stops the boot with the floppy's own
  "cannot boot from this disk" message, as on a real PC-98. Mount data disks after DOS starts.

## Summary

| Section | Entries | works | works with notes | partial | fails | not a core bug |
|---|---|---|---|---|---|---|
| HDD-installed games | 123 | 84 | 33 | 5 | 0 | 1 |
| CD-ROM titles | 47 | 28 | 16 | 2 | 0 | 1 |
| Floppy titles | 160 | 106 | 40 | 2 | 2 | 10 |

## Open, cause unknown

- **Xanadu Scenario II** (floppy) asks for a mounted disk again; unexplained, not established as a core bug.
- **Star Cruiser 2** (CD) stops on its first intro text with no CD audio and no response to keys; unexplained, not established as a core bug.
- **Policenauts** (CD) skips the montage music after the opening song; NP2kai behaves the same, so not established as a core bug.
- **Rusty** (HDD) runs its C-Lab logo intro fast at full CPU speed and cuts the voice short; the guest timers all measure correct, so the cause is open.

## HDD-installed games

| Title | Media | Status | Notes |
|---|---|---|---|
| 3x3 Eyes - Sanjiyan Henjou | HDD image | works with notes | Setup menu waits for a mouse click |
| 46 Okunen Monogatari - The Shinkaron | HDD image | works |  |
| A Ressha de Ikou IV | HDD image | works |  |
| AD&D Eye of the Beholder II - The Legend of Darkmoon | HDD image | works |  |
| alchem | HDD image | works |  |
| Alice no Yakata III | HDD image | works with notes | 256 colours; the doubled, garbled picture seen before 2026-10-20 is fixed |
| Battle Skin Panic 9821 | HDD image | works with notes | The name entry takes mouse clicks only (a kana, then 終わり to finish); Enter does nothing there. Then the opening, title and a classroom scene with the entered name |
| Brandish 2 - The Planet Buster | HDD image | works with notes | Mouse-driven launcher: click Game Start |
| Brandish 3 - Spirit of Balcan | HDD image | works with notes | Mouse-driven launcher: click to continue |
| Brandish VT | HDD image | works |  |
| Branmarker 2 | HDD image | works |  |
| Classic Road 4 | HDD image | works |  |
| Crusher Joe - Kanraku Wakusei no Inbou | HDD image | works |  |
| Cybernetic Hi-School IV | HDD image | works with notes | Asks for the system disk in drive 1 |
| Daikoukai Jidai II | HDD image | partial | Opening logo and art, then ends in a red DISK ERROR bar; same end state on every build tested, cause not investigated |
| Dalk | HDD image | works |  |
| Dawn Patrol - Yoake no Pilot | HDD image | works with notes | Use plain VEM486 /U. The NP2kai-specific option /U=A5-A7,D1-DF,E8-F4 in the image's CONFIG.SYS makes VEM486 stop with a general protection error |
| Dead of the Brain 2 | HDD image | works | Music-board select, name prompt, title menu and a story scene with text |
| Devil Force Trilogy | HDD image | works with notes | Boot menu: press 1 (then pick 1-4 in the launcher) |
| Disc Station Vol. 09-10-11 | HDD image | works |  |
| DOOM (installed on the hard disk) | HDD image | works with notes | HIMEM only: no EMM386 (its DX386 extender refuses V86 mode with "already running in virtual-86 mode"). Under EMM386 /UMB it stops with that message |
| Doukyuusei | HDD image | works |  |
| Doukyuusei 2 | HDD image | works with notes | Boot menu: press 1 (Enter alone does not pick) |
| Dr. Brain - Puzzle no Shiro | HDD image | works |  |
| Dr. Stop! | HDD image | works |  |
| Dracula Hakushaku | HDD image | works | Opens on the sound-source select menu, whose cursor moves; the test did not pick a source, so not played further |
| Dragon Knight II | HDD image | works |  |
| Dragon Knight III | HDD image | works |  |
| Dragon Slayer - The Legend of Heroes (Eiyuu Densetsu) II | HDD image | works |  |
| Dragon Wars | HDD image | works |  |
| Dungeon Master II - Skullkeep | HDD image | works with notes | Asks for the Disk B key disk in drive 2 (key disk prompt is normal) |
| Edge | HDD image | works | Title menu, intro narration and dialogue scenes with portraits |
| Eisei Meijin II | HDD image | works |  |
| Eve Burst Error | HDD image | works |  |
| Final Breaker | HDD image | works |  |
| First Queen III | HDD image | works | Save-slot list, battle scenes and town dialogue |
| Flame Zapper Kotsujin | HDD image | works with notes | Use EMM386.EXE /UMB. With NEC's 1989 EMM.SYS as the EMS driver the intro runs slowly with uncleared sprites, or the screen stays black |
| Flashback | HDD image | works |  |
| Foxy 2 | HDD image | works |  |
| Fushigi no Umi no Nadia | HDD image | works with notes | Display selector needs a mouse click; not played further |
| G.R. - Gravity Response | HDD image | works |  |
| Gaias Lord | HDD image | works |  |
| Genpei Kassen | HDD image | works with notes | Needs EMS: VEM486 + VEMEMM.SYS enabled in CONFIG.SYS. Then asks for a key disk (disk prompt is normal). Without EMS: "not enough free memory" |
| Gensei Kitan - Disc Saga III | HDD image | works |  |
| Giten Megami Tensei - Tokyo Mokushiroku | HDD image | works |  |
| Hal | HDD image | works |  |
| J. League Professional Soccer 1995 | HDD image | partial | Boots to the DOS prompt; the game itself was not started in testing |
| Janou Touryuumon II | HDD image | works |  |
| Jinn - Eternal Hero | HDD image | works |  |
| Kakyuusei | HDD image | works with notes | Boot menu: press 1 (Enter alone does not pick) |
| King's Quest V | HDD image | works |  |
| Kizuato | HDD image | works |  |
| Kono Yo no Hate de Koi o Utau Shoujo YU-NO | HDD image | works |  |
| Konpeki no Kantai | HDD image | not a core bug | Install-time "hardware was changed, reinstall" check (a hardware-ID test in the title), not a render fault |
| Lemmings | HDD image | works with notes | Title, level info and levels play. The view can scroll past the edge of a level into an all-black area while the timer runs on; the minimap shows where the view is |
| Lunatic Dawn | HDD image | works |  |
| Madou Monogatari A.R.S | HDD image | works |  |
| Mahjong Fantasia (Mahjong Gensoukyoku) II | HDD image | works |  |
| Mahjong Fantasia the 3rd Stage (Mahjong Gensoukyoku III) | HDD image | works |  |
| Makyouden | HDD image | works with notes | Asks for Disk B in drive 2 |
| Microsoft Flight Simulator Version 5.0a | HDD image | works |  |
| Microsoft Space Simulator - 42-oku Kounen no Fantasy | HDD image | works |  |
| Might and Magic - World of Xeen | HDD image | works |  |
| Might and Magic III | HDD image | works with notes | Black screen fixed 2026-10-28 (interrupt fix); intro and title now play. Before that it stayed black on every build |
| Might and Magic IV - Clouds of Xeen | HDD image | works |  |
| Mouryou Senki Madara | HDD image | works with notes | Launch from the DOS prompt; asks for Game disk 1 |
| Necronomicon | HDD image | works | Runs from the hard disk with no CD driver loaded (tested with its CD mounted; enabling the image's CD driver lines gives the same result). Sound select, credits and a story scene with text |
| New 3D Golf Simulation | HDD image | works |  |
| Nobunaga no Yabou - Haouden | HDD image | works |  |
| Nobunaga no Yabou - Tenshouki | HDD image | works with notes | Needs EMS: VEM486 + VEMEMM.SYS enabled in CONFIG.SYS; reaches its menu. Without EMS: "not enough free memory" |
| Otome Senki | HDD image | works |  |
| Phantasie IV | HDD image | works |  |
| Pia Carrot e Youkoso!! | HDD image | works | Title, then the name-entry panel, where typed text appears; a name was not completed in testing, so not played further |
| Police Quest II | HDD image | works |  |
| Popful Mail | HDD image | works |  |
| Possessioner | HDD image | works | Start menu, city intro with narration and story scenes |
| Power Dolls 2 | HDD image | works with notes | Launch from the DOS prompt; asks for the Briefing disk |
| Prince of Persia 2 | HDD image | works |  |
| Princess Maker 2 | HDD image | works with notes | Display selector: click Colour with the mouse |
| Puyo Puyo 2 | HDD image | works |  |
| Ragnarokkr | HDD image | works |  |
| Rance 4.1 | HDD image | works with notes | 256 colours; the doubled, garbled picture seen before 2026-10-20 is fixed |
| Rance II | HDD image | works |  |
| Rance III | HDD image | works |  |
| Rance IV | HDD image | works |  |
| Revival Xanadu | HDD image | works |  |
| Rusty | HDD image | works with notes | Intro art and text sequence; at full CPU speed the C-Lab logo intro runs fast and cuts its PCM voice short (right at the 16 MHz CPU Speed setting; reported correct on a real Xe10). Every guest timer measures correct, so the cause is open |
| Sangokushi IV | HDD image | works with notes | Settings dialog, then asks for the game disk in a floppy drive |
| Sangokushi V | HDD image | works with notes | Needs EMS: VEM486 + VEMEMM.SYS enabled in CONFIG.SYS; reaches its menus. Without EMS: "not enough free memory" |
| Shizuku | HDD image | works |  |
| Sichuan | HDD image | works |  |
| SimCity 2000 DX | HDD image | works with notes | The vendor's boot floppy loads no memory manager and no mouse driver, so it was run from the hard disk with VEM486 removed from CONFIG.SYS and AUTOEXEC starting it (QMOUSE loaded). Mouse-driven, 640x480: a new city, its newspaper, and the simulation date advancing |
| SimEarth | HDD image | works with notes | Opens on the world map with its windows and Japanese menus. A hint strip in the text layer stays drawn over windows (the text layer overlays graphics on a PC-98); not compared with a real machine. No new planet was started |
| Slayers | HDD image | works |  |
| Space Hulk | HDD image | works |  |
| Space Quest IV | HDD image | works |  |
| Strike Commander | HDD image | works with notes | Tested without VEM486 (32-bit DOS extender, 256 colours); reaches the main menu |
| Strike Commander Plus | HDD image | partial | Boots to the DOS prompt; the game itself was not started in testing |
| Super Real Mahjong PII & PIII | HDD image | works | Title, mode menu and a hand in play |
| Sword World PC | HDD image | works |  |
| Taikou Risshiden II | HDD image | works with notes | Display selector and settings box need mouse clicks (Analog Display, then Standard and Decide); then the opening date card and story text |
| Teitoku no Ketsudan III | HDD image | works with notes | Needs EMS: VEM486 + VEMEMM.SYS enabled in CONFIG.SYS. Then asks for the Powerup Kit disk. Without EMS: "not enough free memory" |
| Tenbu - Mankan Zenseki | HDD image | works with notes | Answer n to the "MIDI sound?" question |
| Tetris | HDD image | works |  |
| Tetris 2 + Bombliss | HDD image | works |  |
| The Atlas II | HDD image | works |  |
| The Legend of Heroes (Eiyuu Densetsu) III - Shiroki Majo | HDD image | works |  |
| The Magic Candle | HDD image | works |  |
| The Story of King Aress (Aress Ou no Monogatari) | HDD image | works |  |
| Touhou 1 Reiiden | HDD image | works |  |
| Touhou 2 Fuumaroku | HDD image | works |  |
| Touhou 3 Yumejikuu | HDD image | works |  |
| Touhou 4 Gensoukyou | HDD image | works |  |
| Touhou 5 (Mystic Square) | HDD image | works | Sound select, title, demo and sprite-heavy gameplay |
| Toushin Toshi | HDD image | works |  |
| Toushin Toshi II | HDD image | works |  |
| Ultima VIII - Pagan | HDD image | works | 256 colours; reaches the copy-protection keyword screen |
| Urban Soldier | HDD image | works |  |
| Winning Post 2 Plus | HDD image | partial | Starts, then "Not Memory Error!": the image loads VEM486 /U without VEMEMM.SYS (EMS). Not retested with EMS |
| Wizardry VI | HDD image | partial | Launching it gave "FORGE SYSTEM ERROR: Unable to Load System Fonts" and a return to DOS; not investigated |
| Wolfenstein 3D | HDD image | works | Runs with no memory manager, as the image ships. Title, Options menu, episode and skill select, then gameplay on episode 1, floor 1 with a clean status bar |
| Words Worth | HDD image | works |  |
| Yougekitai - Jashin Koumaroku | HDD image | works with notes | Setup menu needs a mouse click on Initial Start; then the logo, intro and story scenes with text |

## CD-ROM titles

The boot hard-disk image of each, or the title's own CD boot floppy where the Media column says
*CD + boot floppy*, loads a CD driver and MSCDEX (see "DOS utilities and drivers").

| Title | Media | Status | Notes |
|---|---|---|---|
| Alone in the Dark 2 | CD + HDD image | works |  |
| Alone in the Dark 3 | CD + HDD image | works with notes | HIMEM only, no VEM486 (as the image ships). Intro, title, credits and the start menu in 256 colours; not played further. CD audio from the disc plays at the correct pitch and speed (checked with a recording) |
| Brandish 2 Renewal | CD + HDD image | works with notes | Mouse-driven launcher: click BR2 Start (upper right). Reached, but the test's click missed it, so not played further |
| Brandish 3 - Spirit of Balcan | CD + HDD image | works |  |
| Brandish 3 Renewal | CD + HDD image | works with notes | Mouse-driven launcher, as on the hard-disk version; reached, but the test's clicks did not hit a button, so not played further |
| Brandish Renewal | CD + HDD image | works |  |
| Brandish VT | CD + HDD image | works |  |
| Cyber War | CD + HDD image | works |  |
| Doom | CD + HDD image | works with notes | HIMEM only, no EMM386 or VEM486: the DX386 extender refuses to start in V86 mode. 256-colour 3D view and episode menu run |
| Dragon Lore | CD + HDD image | works |  |
| Eimmy to Yobanaide | CD + HDD image | works with notes | Uses CDXNP.SYS as its CD driver |
| El-Hazard - The Magnificent World | CD + HDD image | works |  |
| Emit Vol. 1 - Toki no Maigo | CD + boot floppy | works | Boots from the title's CD boot disk (VEM486 + VEMEMM.SYS). Logo, animation and the main menu. CD audio from the disc plays at the correct pitch and speed (checked with a recording) |
| F-117A Nighthawk Stealth Fighter 2.0 (256-color version) | CD + HDD image | works with notes | Answer its setup questions with n (joystick), 2 (sound) and 1 (256 colours); it then reaches the squadron bulletin board in 256 colours |
| Gakuen King | CD + HDD image | works |  |
| Giten Megami Tensei - Tokyo Mokushiroku | CD + HDD image | works |  |
| Golf Links 386 Pro | CD + HDD image | works with notes | Run without VEM486: under it, its extender stops with "the 386 is in virtual 8086 mode". Logo and main menu |
| Inherit the Earth - Quest for the Orb | CD + HDD image | works |  |
| Macross - Skull Leader Complete Pack | CD + HDD image | works with notes | Asks which drive to save to (buttons A-Z); no drive was picked in testing, so not played further |
| Mugen Houyou | CD + HDD image | works with notes | 256-colour picture was doubled and garbled before the 2026-10-20 PEGC fixes; clean since |
| My Home Dream 2 | CD + HDD image | works |  |
| Only You - Seikimatsu no Juliet-tachi | CD + HDD image | works |  |
| PGA Tour Golf III | CD + HDD image | works with notes | Run without VEM486: under it, the game stops with a VEM486 general protection error. Title, main menu and hole select |
| Photo Genic | CD + HDD image | works |  |
| Policenauts | CD + HDD image | works with notes | PATACD.SYS + MSCDEX; the intro reaches the logo; CD audio from the disc plays correctly (checked with a recording). The newspaper montage after the opening song plays without music: the game checks the drive 91 s into the 94 s song, sees it still playing and skips the next track. NP2kai does the same; real hardware not checked |
| Professional Baseball 1996 | CD + HDD image | works with notes | Needs EMS: VEM486 + VEMEMM.SYS enabled in CONFIG.SYS; intro, then the title menu with the mouse cursor. Without EMS it prints an EMS install failure and returns to DOS |
| Psychic Detective Series Vol. 1 - Invitation | CD + boot floppy | works | Boots from the title's CD boot disk. Intro text, title and the first scenes with text |
| Psychic Detective Series Vol. 2 - Memories | CD + boot floppy | works | Boots from the title's CD boot disk. Intro, save-slot prompt and the command menu with the mouse cursor. CD audio from the disc plays at the correct pitch and speed (checked with a recording) |
| Psychic Detective Series Vol. 3 - Aya | CD + boot floppy | works | Boots from the title's CD boot disk. Opening scenes with text |
| Race into Space - Uchuu e no Chousen | CD + HDD image | works with notes | HIMEM only, no VEM486: its DX386 extender refuses V86 mode. Intro and main menu with the mouse cursor |
| Revival Xanadu | CD + HDD image | works |  |
| Revival Xanadu II Remix | CD + HDD image | works |  |
| Sangokushi V | CD + HDD image | partial | Settings box and file copy from the CD work (Oak CD driver + MSCDEX), then the launcher returns to the DOS prompt with no message. The floppy build of this title needs EMS; the CD one was not retested with EMS |
| Schwarzschild GX - Sabita Sousei | CD + HDD image | works |  |
| Star Cruiser 2 | CD + boot floppy | partial | Boots from the game disk (EMM386, NECCD.SYS + MSCDEX). FM balance select, then the first intro text stays static: FM sound for about 20 s, then silence, and no CD audio starts; Enter and clicks do nothing. Cause open |
| Super Real Mahjong PIV Final | CD + HDD image | works | Mode menu, title and a hand in play |
| TFX | CD + HDD image | not a core bug | Hangs at "DOS/4GW Protected Mode Run-time 1.97 ... Loading..." under VEM486; NP2kai stops at the same point. Without VEM486 the DOS/16M extender reports an 8042 keyboard-controller timeout (it probes an AT controller) |
| The Legend of Heroes III - Shiroki Majo Renewal | CD + HDD image | works | Menu, logo, title and the prologue with scrolling text |
| The Legend of Heroes (Eiyuu Densetsu) IV - Akai Shizuku | CD + HDD image | works |  |
| The Legend of Kyrandia | CD + boot floppy | works | Boots from the title's CD boot disk (EMM386). Intro, a cutscene with Japanese text and the game screen |
| Theme Park | CD + HDD image | works with notes | HIMEM only, no VEM486: its DX386 extender refuses V86 mode. Intro and title run |
| Touhou Project CD (with Touhou 5 HDD install) | CD + HDD image | works | Sound select and title |
| Toushin Toshi II - Soshite, Sorekara | CD + HDD image | works | Title box, menu and story text pages. CD audio from the disc plays at the correct pitch and speed (checked with a recording) |
| Viper CTR - Asuka | CD + HDD image | works with notes | Fixed 2026-10-28 (GRCG tile ordering). Before the fix it showed garbled vertical stripes on 80 MHz and faster builds. Sogna logo, logo zoom and menu now draw correctly |
| Viper F-40 | CD + HDD image | works with notes | SGSCD resident driver + MSCDEX; tested without VEM486; start the game with SGS21 after the driver. Reaches the 256-colour title |
| Warcraft | CD + HDD image | works | HIMEM only (as the image ships). Intro, title menu, scenario select and mission text; Japanese text draws cleanly |
| Xenon - Mugen no Shitai | CD + HDD image | works |  |

## Floppy titles

| Title | Media | Status | Notes |
|---|---|---|---|
| 46 Okunen Monogatari - The Shinkaron | Floppy | works with notes | Boot from Disk 1 (user disk) and put Disk 2 in drive 2. The System disk alone is not a boot disk ("No system files") |
| 7N2BXW | Floppy | works |  |
| A Ressha de Ikou | Floppy | works |  |
| A Ressha de Ikou III | Floppy | works with notes | Asks for the user disk in drive B and a mouse click |
| Acrojet | Floppy | works |  |
| AD&D Pool of Radiance | Floppy | works |  |
| Advanced Lord Monarch | Floppy | works |  |
| Albatross | Floppy | works with notes | Asks a sound-board Y/N question (a key answers it) |
| Alpha | Floppy | works |  |
| Angelus - Akuma no Fukuin | Floppy | works |  |
| Arcus | Floppy | works |  |
| Arcus II | Floppy | works with notes | Disks 1 and 2 load; asks for Disk 3 mid-game (disk swap) |
| Arcus III | Floppy | works |  |
| Arcush | Floppy | works | Black screen fixed 2026-10-20 (DMA into G-VRAM) |
| Arguice no Tsubasa | Floppy | works |  |
| Arkanoid | Floppy | works |  |
| Asteka | Floppy | works |  |
| Battle Chess | Floppy | works |  |
| Bible Master | Floppy | works with notes | Wants the System and Data disks in the drives (only the system and opening disks were supplied) |
| Bomberman - Panic Bomber | Floppy | works |  |
| Brandish | Floppy | works |  |
| Bubblegum Crisis | Floppy | works with notes | Asks 1 (start from the beginning) or 2 (load data): answer with the number key, Enter is not an answer. Not played further |
| Burai Part 1 (Joukan) | Floppy | works |  |
| Cluju | Floppy | works |  |
| Creastar - Planets in Legend | Floppy | works |  |
| Crimson III | Floppy | not a core bug | Install master disk: "boot from an MS-DOS opening disk"; no game on it |
| Cruise Chaser Blassty | Floppy | works with notes | Answer n to the "NO ANIMATION MODE" prompt (Enter is not an answer) |
| Crystal Chaser - Tenkuu no Mashoukyuu | Floppy | works |  |
| Cybernetic Hi-School | Floppy | works with notes | Boot disk (MS-DOS 3.30) then asks for Disks A and B; type DEN |
| Daikairei - Dai Nippon Teikoku Kaigun no Kiseki | Floppy | works |  |
| Daikoukai Jidai | Floppy | works |  |
| Daisenryaku IV | Floppy | works |  |
| Daiva Story 7 | Floppy | not a core bug | Draws a blue empty window then loops: a real-mode LODSW at offset FFFF, a #GP on a 286 or newer CPU. Expected to hang on a real 486 too (not confirmed on a real Xe10); NP2kai and MAME do not model it |
| Das Schwert des Paracelsus (Paracelsus no Maken) | Floppy | works |  |
| Dead of the Brain | Floppy | works | Disk A + Disk B; title menu, then the first room with text and MORE prompts |
| Death Bringer | Floppy | works |  |
| Derby Stallion | Floppy | works |  |
| Dezeni Land | Floppy | works |  |
| Dinosaur | Floppy | works with notes | Program disk in drive 1, Scenario disk 1 in drive 2. Black screen fixed 2026-10-20 (FDC MF bit) |
| Dios | Floppy | works |  |
| Disc Station 98 #01 - Soukangou | Floppy | works |  |
| Disc Station 98 #14 | Floppy | works |  |
| Disc Station 98 #20 | Floppy | works with notes | Its installer formatted a blank disk in drive 2 and wrote files (FDC format and write work) |
| Doom II | Floppy | not a core bug | Disk 1 is not a boot disk ("No system files"); the CD version is the booting one |
| Door Door | Floppy | works |  |
| Dragon Half | Floppy | works with notes | Asks for the save disk in drive 2 |
| Dragon Knight | Floppy | works |  |
| Dragon Princess - Ryuu no Densetsu | Floppy | works |  |
| Eisei Meijin III | Floppy | works |  |
| Elysion | Floppy | works |  |
| Emerald Dragon | Floppy | works |  |
| Fantasian | Floppy | works |  |
| Fantasy Knight | Floppy | works with notes | RAM-disk prompt: type 1 (2 gives the game's own "RAM card not installed") |
| Fray | Floppy | works |  |
| Galaga | Floppy | works |  |
| Galf Streem | Floppy | works |  |
| Gambler Jikochuushinha | Floppy | not a core bug | The game runs LOCK MOV, which is an invalid opcode on a 386/486; NP2kai ignores LOCK. Expected to fail on a real 486 too (not confirmed on a real Xe10). Screen stays black |
| Gandhara | Floppy | works |  |
| Ginga Eiyuu Densetsu | Floppy | works |  |
| Godzilla | Floppy | not a core bug | Disk 1 alone is not a boot disk ("No system files"); the full set was not available |
| Ground Master - Ushinawareta Houju no Densetsu | Floppy | works |  |
| Gulf War - Soukouden | Floppy | works with notes | Disk swap: asks for Disk 3 in drive 0 and a reset |
| Hideger | Floppy | works |  |
| Hiouden | Floppy | works |  |
| Hiouden II | Floppy | works |  |
| Hokuto no Ken | Floppy | works |  |
| Hydlide | Floppy | works |  |
| Hydlide 3 SV | Floppy | works |  |
| Illusion City | Floppy | works | Configuration menus |
| Imperial Force | Floppy | works |  |
| Janou Touryuumon | Floppy | works with notes | Menu works; asks for the user disk in drive 2 |
| Jesus II | Floppy | works |  |
| Jotunn | Floppy | works with notes | Asks for the 8 MHz CPU clock mode and a reset (use the CPU Speed setting) |
| Klax | Floppy | works |  |
| Last Armageddon | Floppy | works | Disk A + Disk B; story slides and animation |
| Lode Runner | Floppy | works |  |
| Lord Monarch | Floppy | works with notes | Needs a user disk in drive 2 ("Drive-2 not ready" without it) |
| Madou Monogatari 1-2-3 | Floppy | works with notes | System disk + Sampling disk in drive 2. Black screen fixed 2026-10-20 (FDC MF bit); the System disk alone stays black |
| Madou Monogatari A.R.S | Floppy | works with notes | Needs all three disks (game, data, demo); with only two it asks for the third |
| Majinkyuu | Floppy | works |  |
| Mario Bros. Special | Floppy | works |  |
| Martial Age | Floppy | partial | Prints only an MS-DOS boot message then stays static (Disk A + B); may need an installed copy |
| Master of Monsters | Floppy | works |  |
| Metal Eye | Floppy | works |  |
| Mid-Garts | Floppy | works |  |
| Might and Magic III (Disk A+B) | Floppy | not a core bug | Disk A is not a boot disk ("No system files"); the hard-disk version is the one that boots |
| Misty Vol. 1 | Floppy | works |  |
| Mugen Senshi Valis | Floppy | works | Black screen fixed 2026-10-22 (DMA into text RAM). Wait about 20 s for the logo jingle |
| Mugen Senshi Valis II | Floppy | works with notes | Display select, then asks for Disk A in drive 1 and Disk C in drive 2 (3 disks) |
| Murder Club | Floppy | works |  |
| Nazo Puyo | Floppy | works |  |
| Nectaris | Floppy | works |  |
| Nobunaga no Yabou | Floppy | works |  |
| Nobunaga no Yabou - Zenkoku-ban | Floppy | works with notes | Disk A + Disk B in drive 2 ("New game or Load data"). Disk A alone is a data disk |
| Nobunaga no Yabou Haouden (floppy) | Floppy | works with notes | Display select and logo, then asks for the Scenario disk in drive 1 (disk swap) |
| Popful Mail | Floppy | works |  |
| Populous | Floppy | works with notes | The title menu takes F1 (Tutorial), F2 (Conquest) or F3 (Custom); not played further |
| Populous II Expert | Floppy | works with notes | Disk 1 + Disk 2. Intro art, then the mode menu; the test's clicks missed its entries, so not played further |
| Princess Maker | Floppy | works with notes | Disk A + Disk B in the two drives; with a user disk instead of Disk B it asks for Disk B |
| Princess Minerva | Floppy | works with notes | Asks for the scenario disk in drive 2 |
| Psy-O-Blade | Floppy | works with notes | Program disk in drive 1, Data disk in drive 2. Hang fixed 2026-10-22 (DMA into text RAM); ends at the data-load Y/N prompt |
| Puyo Puyo | Floppy | works with notes | Game disk + Demo disk in drive 2 (the game disk alone cannot find DEMO.OVL) |
| Quarth | Floppy | works |  |
| Quest for Glory | Floppy | not a core bug | Disk 1 is not a boot disk ("No system files") |
| Ranma 1-2 - Hiryuu Densetsu | Floppy | works with notes | Asks for Disk 4 in drive 1 (disk swap) |
| Reichsritter - Teikoku Kishidan | Floppy | works |  |
| Rogue | Floppy | works |  |
| Rogue Alliance | Floppy | works |  |
| Romancia | Floppy | works | Black screen fixed 2026-10-20 (FDD mode Auto) |
| Royal Blood | Floppy | works with notes | Asks for a blank user disk in drive 2 |
| Rune Worth - Kokui no Kikoushi | Floppy | works with notes | Player-register menu; asks for the user disk |
| Ryu - Naki no Ryu yori | Floppy | works |  |
| Saisoku Densetsu Racer X | Floppy | works |  |
| Salad no Kuni no Tomato-hime | Floppy | works with notes | At the loader prompt type START then Return. Black screen fixed 2026-10-21 |
| Sangokushi II | Floppy | works |  |
| Savior | Floppy | fails | Stays black with Disk 1 and Disk 2 in either order (2DD 16x256 sectors, the IPL reads then retries forever). NP2kai also stays black, so likely a dump or protection issue; cause not established |
| Seilane | Floppy | works |  |
| Shin Kugyokuden | Floppy | works |  |
| Shuten Douji | Floppy | works |  |
| Solitaire Royale | Floppy | fails | 1.2 MB 15x512 (5-inch) disk format; stays black. A 3.5-inch Xe10 drive is not expected to read it (not confirmed on hardware) |
| Sorcerian | Floppy | works with notes | Title and main menu; asks for the user disk in drive 2 to load |
| Sorcerian System Scenario Vol. 3 - Pyramid Sorcerian | Floppy | not a core bug | Scenario data disk; needs the Sorcerian program disk |
| Span of Dream | Floppy | works |  |
| Spindizzy II | Floppy | works |  |
| Star Cruiser | Floppy | works | Reaches the cockpit and the in-game menu. Fixed 2026-10-28: the floppy controller now reports a missing sector after the disk's second index pulse, as the real chip does, instead of at once |
| Star Trader | Floppy | works |  |
| Suikoden - Tenmei no Chikai | Floppy | works |  |
| Suzaku | Floppy | works |  |
| Ten to Chi to | Floppy | works with notes | Art, then asks for game Disk B in drive 2 |
| Tenbu - Sangokushi Seishi | Floppy | works with notes | Art, then asks for the scenario disk (disk swap) |
| Tenka Touitsu | Floppy | works |  |
| The 4th Unit | Floppy | works |  |
| The Bard's Tale III | Floppy | works |  |
| The Legend of Heroes (Eiyuu Densetsu) IV - Akai Shizuku | Floppy | works |  |
| Thexder | Floppy | works |  |
| Thunder Force | Floppy | works |  |
| Tritorn II | Floppy | works |  |
| Ultima Underworld | Floppy | not a core bug | Disk 1 is not a boot disk ("No system files"); wants a hard-disk install |
| Ultima V | Floppy | works |  |
| Vain Dream | Floppy | works |  |
| Will - The Death Trap 2 | Floppy | works |  |
| Wing Commander - Armada | Floppy | not a core bug | Disk 1 is not a boot disk ("No system files") |
| Wing Man 2 | Floppy | works with notes | Asks to press the KANA key |
| Wings | Floppy | works |  |
| Wizardry | Floppy | works |  |
| World Golf III | Floppy | works |  |
| Xak - The Art of Visual Stage | Floppy | works |  |
| Xak - The Tower of Gazzel | Floppy | works |  |
| Xak II - Rising of The Redmoon | Floppy | works |  |
| Xak III - The Eternal Recurrence | Floppy | works with notes | Menu, then asks for the user disk in drive 1 |
| Xanadu | Floppy | works with notes | Disks A-B + Disk C (user disk) in drive 2. Fixed 2026-10-20 (FDC track handling) |
| Xanadu Scenario II | Floppy | partial | Asks for Disk C in drive 2 although the user disk is there; unexplained, not established as a core bug |
| Xevious | Floppy | works with notes | Title waits for SPACE |
| XZR (Exile) | Floppy | works |  |
| Yaksa | Floppy | works |  |
| Ys | Floppy | works | Black screen fixed 2026-10-20 (FDC track handling) |
| Ys II | Floppy | works with notes | Intro art, then asks for Disk A in drive 1 (disk swap) |
| Ys III - Wanderers from Ys | Floppy | works |  |
| Zan - Kagerou no Toki | Floppy | works with notes | Asks for the Data disk in drive 1 (disk swap) |
| Zarth | Floppy | works |  |

## Windows 95

| Title | Media | Status | Notes |
|---|---|---|---|
| Windows 95 (PC-98) | HDD image | works | Boots to the desktop and the Welcome dialog at 640x480 with 256 colours; the clock advances; the boot log runs to the end. Needs `HIMEM.SYS` and `EMM386.EXE /UMB` (the `/T=` swap option hung until 2026-10-16). Display drivers checked: 640x480 256-colour (PEGC), 640x400 256-colour (Windows shows its own display-settings error dialog) and 640x400 16-colour (`EGCN4.DRV`), all drawing correctly since 2026-10-20. Black desktop fixed 2026-10-20 (CPU `LFS`/`LGS` fix). The Start menu was not exercised. |

## DOS utilities and drivers

| Item | Status | Notes |
|---|---|---|
| `HIMEM.SYS` | works | Needed by almost everything (`DOS=HIGH`). |
| `EMM386.EXE /UMB` (NEC MS-DOS 6.2) | works | EMS and upper memory. Does not suit software that refuses V86 mode (see DX386 below). |
| NEC `EMM.SYS` (1989) | works with notes | One title's intro misbehaves under it (slow, uncleared sprites, or black); `EMM386.EXE /UMB` is fine. |
| `VEM486.EXE /U` + `VEMEMM.SYS` | works | The memory manager some Koei images use. Without `VEMEMM.SYS` those titles stop with "not enough free memory". Use plain `/U`: the NP2kai-specific range `/U=A5-A7,D1-DF,E8-F4` makes VEM486 fault. |
| `HSB.EXE` (HSB-98) | works | Resident use is fine; `HSB.EXE IGDC:31` switches to the 31 kHz mode. |
| MSCDEX 2.23 + `NECCD.SYS` | works | Match the `/D:` name on both lines (README). CD audio plays; while a track plays `NECCD.SYS` refuses file reads (`Not ready`), as on real hardware. |
| `NECCDD.SYS`, `NECCDM.SYS` | works | Ran on the CD-version images (NECCDD on eight, NECCDM with CD audio on one). |
| `PATACD.SYS` | works with notes | Reads files and plays CD audio; rejects some direct driver calls. |
| `CDXNP.SYS` | works | The CD driver one title uses. |
| Oak OTI-011 CD driver + MSCDEX | works | Used by several CD-version images (drive Q:). |
| `SGSCD` resident driver | works | Needed by the SGS-engine CD title; load it before the game. |
| DX386 DOS extender (DOOM, Theme Park) | works with notes | Refuses to run in V86 mode ("already running in virtual-86 mode"): boot with HIMEM only. |
| DOS/4GW extender | not a core bug | Hangs at "Loading..." under VEM486 on one title; NP2kai does the same. |
| DOS/16M extender | not a core bug | Reports an 8042 timeout without VEM486 (it probes an AT keyboard controller for A20). |
| 32-bit extender titles (256-colour) | works | Run without VEM486: one flight sim, one adventure, one 3D adventure. |
| Mouse driver (`QMOUSE`) | works | Mouse-driven menus and clicks work. `QMOUSE -z` is the driver most of the tested hard-disk images load; some games read the bus mouse directly and load none. |
| Floppy FORMAT | works with notes | Raw (`.hdm`) images format: a disc-station installer formatted one in drive 2 and wrote files. D88 images do not: MS-DOS FORMAT (version 6.00) on a blank D88 reports that it cannot format the disk (checked 2026-10-28). |
| Keyboard mapping check (typing a directory listing) | works | `\` and `!` reach DOS. |
| File-integrity probe on HDD, floppy and CD | works | Passes without CD audio. With CD audio playing, the HDD and floppy checks pass; CD reads are refused by NECCD.SYS while audio plays, as on hardware, so the CD part is not judged then. |
| 31 kHz mode probe | works | Reached its end with no timeout; the dot clock matched the Xe10 capture within 10 ppm. |
| CPU test programs run from DOS (266 programs) | works | 1330 of 1330 passes over five passes, on the last regression run. |
