# Spell and monster data: layout, lookup, and how to read raw values

Read this when asked why a spell behaves a certain way, what a spell's real
parameters are, or what a monster's stats are (magic resistance, saves, immunities,
HD). It records the on-disk layout and a repeatable recipe for pulling raw values out
of the game data, so the investigation does not have to be re-derived each time. The
sibling doc `item-data.md` covers items the same way.

## The data lives in flat record arrays, big-endian, no headers

Like items, spells and monsters are stored as fixed-size C structs written straight to
disk in big-endian (Mac) order, with no header and no per-record framing. The engine
`fread`s the whole array, then byte-swaps the multi-byte fields in place with a
`Cvt...ToPc` helper (`convert.c` / `convert.h`). So:

- Record size = `sizeof(struct ...)` with Mac 2-byte alignment.
- Record count = file size / record size (and the file size is an exact multiple).
- A struct that is all single bytes needs no swap, so its `Cvt` is a no-op and a raw
  read from the file matches the in-memory values exactly. A struct with `short`/`int`
  fields does not: those bytes are big-endian in the file but little-endian in memory
  after the swap. This distinction matters for out-of-bounds reads (see the
  Cosmic Blast gotcha below).

## Spells

### Struct and file

- `struct spell` (`structs.h`, the global is `spellinfo`) is **30 bytes, all `char`/
  `unsigned char`**, so there is no padding and no byte-swap. `CvtTabSpellToPc` is
  `#define`d to nothing (`convert.h:151`). Field order, with byte index:

  ```
   0 range1       1 range2      2 queicon     3 tohitbonus   4 savebonus
   5 fixedtargetnum  6 canrotate  7 saveadjust  8 cannot     9 resistadjust
  10 cost        11 damage1     12 damage2     13 powerdam1  14 powerdam2
  15 duration1   16 duration2   17 powerdur1   18 powerdur2  19 spelllook1
  20 spelllook2  21 sound1      22 sound2      23 targettype 24 size
  25 special (unsigned)  26 damagetype  27 spellclass (unsigned)  28 incombat  29 incamp
  ```

- Standard spells are the data fork of `base/Realmz/Data Files/Data S`, read in
  `main.c` (around line 1175) as `spelldata[5][7][15]` (caste, level, slot).
  The file actually holds 525 records (5 * 7 * 15) but `main.c` reads only the first
  420 (4 castes). The 5th caste slot, `spelldata[4]`, is loaded separately from the
  scenario's `Data Spell` file in `misc.c` (around line 2453) for custom scenario
  spells; the last 105 records of `Data S` are unused.

### The caste index is off by one from the name resource

This is the easy thing to get wrong. Spell names are STR# resources in
`base/Realmz/Data Files/Custom Names.rsrc`, with resource id `1000 * class + level`:

  ```
  Sorcerer   1000..1006   (class 1, levels 1st..7th)
  Priest     2000..2006   (class 2)
  Enchanter  3000..3006   (class 3)
  Special    4000..4006   (class 4: pro jos, breath, potions, missiles, misc)
  ```

But `loadspell2` (`loadspell.c`) computes the `spelldata` array index as
`castcaste = id / 1000 - 1`. So the array index is **class minus 1**:

  ```
  spelldata[0] = Sorcerer   spelldata[1] = Priest
  spelldata[2] = Enchanter  spelldata[3] = Special   spelldata[4] = scenario custom
  ```

Level and slot are also 0-based: `castlevel = level - 1`, `castnum = nameIndex` (the
STR# string index, 0-based). So "Sorcerer 4th, first name" is `spelldata[0][3][0]`.
If a record you read looks like the wrong spell (e.g. you expected a damage blast and
got a haste effect), you almost certainly used the class number instead of class - 1.

### What the fields mean for resistance and damage

- `damage` per cast = `randrange(damage1, damage2)` plus, for each of `powerlevel`
  iterations, `randrange(powerdam1, powerdam2)`. So a spell with `damage1=damage2=0`
  and `powerdam1=2, powerdam2=4` does 2-4 per power level and nothing at power 0.
- `spellclass` selects the monster `spellimmune[]` slot and groups the spell. `0` is
  charm, `9` is missile, the elemental/attack classes are in between.
- `damagetype` (abs) 1-7 are elemental and allow a saving throw and elemental
  protection halving; `8` is non-elemental magical (no save, no elemental resist);
  `9` is missile. `resolvespell.c` only runs the save/immune path for `damagetype < 8`.
- `cannot`, `saveadjust`, `savebonus`, `resistadjust` tune saves and resistance. In
  `resist()`, `cannot == 1 || cannot > 2` makes the spell unresistable for non-missile
  classes (it returns FALSE early).

## Monsters

### Struct and file

- `struct monster` (`structs.h:159`) is **210 bytes** with Mac 2-byte alignment (its
  largest member is `short`, so struct alignment is 2). `CvtMonsterToPc`
  (`convert.c:236`) byte-swaps the `short` blocks (`money`, `spells`, `items`,
  `weapon`, `iconid`, `spellpoints`, `exp`, `stamina`, `staminamax`, `underneath`,
  `todoondeath`, `maxspellpoints`); everything before `money` is single bytes.

- Byte offsets of the fields that matter for combat/resistance audits:

  ```
   0 hd        1 bonus     2 dx        3 name (index)   4 movementmax
   5 ac        6 magres    7 dist
   8 traiter   9 size     10 type[8] (10..17)
  18 noofattacks  19 noofmagattacks  20 attacks[5][4] (20..39)
  40 damplus  41 castpercent  42 runpercent  43 surrenderpercent  44 misslepercent  45 cansum
  46 save[6] (46..51)        52 spellimmune[6] (52..57)
  58 short money[3] (58..63) 64 short spells[10] ...
  ...
  170 char monname[40] (170..209)   <- record ends at 210
  ```

  `magres` is a signed `char` at +6. `save[6]` (+46) are the six saving-throw
  percentages. `spellimmune[6]` (+52) are six per-class immunity flags. `monname[40]`
  (+170) is a mac-roman C string (the in-place custom name); `name` at +3 is a separate
  index into a STR# name list.

- Monster records live in the scenario's `Data MD` family
  (`Scenarios/<name>/Data MD`, `Data MD1`, `Data MD2`, `Data MD-1`, ...). Each file is
  a flat array of 210-byte records; record count = file size / 210. The `Data MD` in
  `City of Bywater` is 32550 bytes = 155 records.

### Finding a monster by name

The reliable anchor is `monname` at offset 170. Search the file for the name string,
then the record start is `nameOffset - 170`, and you can confirm alignment because
`(nameOffset - 170) % 210 == 0`. From there read `magres` at +6, `save` at +46,
`spellimmune` at +52, etc. (Watch the byte order: `magres`/`save`/`spellimmune` are
single bytes so the raw file value is the runtime value, but `money`/`spells`/`items`
are big-endian in the file and little-endian in memory after `CvtMonsterToPc`.)

## Gotcha: spellclass 6 reads spellimmune[6] out of bounds (the Cosmic Blast bug)

`spellimmune` is only 6 wide (indices 0-5), but `resist()` (`resist.c:49`) guards the
immunity lookup with `spellclass < 7`, so a class-6 spell indexes `spellimmune[6]`, one
past the array. The next field in memory is `short money[3]` at +58. Because
`CvtMonsterToPc` swaps `money` to little-endian, that stray byte is the **low byte of
`money[0]`** at runtime. Any monster carrying gold whose low byte is nonzero therefore
reads as immune and auto-resists. Cosmic Blast (Sorcerer 4th / Enchanter 3rd) is
exactly `spellclass == 6`, so it is the spell that triggers this.

Two further notes:
- The correct guard already exists at `resolvespell.c:321`, which uses `spellclass < 6`
  for the same `spellimmune[]` lookup. The fix is to change `resist.c:49` to `< 6`.
- It is a port regression made worse by endianness: on the big-endian Mac the
  out-of-bounds byte was `money[0]`'s high byte, so only money >= 256 triggered it; the
  little-endian port reads the low byte, which is nonzero far more often.

## Recipe: read a spell or monster record from the data fork

```python
import struct

# Spell: Data S, 30-byte all-char records, index [caste][level][slot] with
# caste = class - 1 (Sorcerer=0, Priest=1, Enchanter=2, Special=3).
sdata = open("base/Realmz/Data Files/Data S", "rb").read()
def spell(caste, level, slot):       # all 0-based
    off = ((caste * 7 + level) * 15 + slot) * 30
    b = sdata[off:off+30]
    sc = lambda i: b[i] - 256 if b[i] > 127 else b[i]   # signed char
    return dict(spellclass=b[27], damagetype=sc(26), cannot=sc(8),
                resistadjust=sc(9), powerdam=(sc(13), sc(14)), targettype=sc(23))
print(spell(0, 3, 0))   # Sorcerer 4th, slot 0 = Cosmic Blast

# Monster: Data MD, 210-byte records; find by name at +170.
mdata = open("base/Realmz/Scenarios/City of Bywater/Data MD", "rb").read()
import re
for m in re.finditer(b"Krise", mdata):
    if (m.start() - 170) % 210 == 0:
        r = mdata[m.start()-170:m.start()-170+210]
        sc = lambda i: r[i] - 256 if r[i] > 127 else r[i]
        print(dict(hd=r[0], magres=sc(6),
                   save=[sc(46+i) for i in range(6)],
                   spellimmune=[sc(52+i) for i in range(6)],
                   money=struct.unpack(">3h", r[58:64])))   # big-endian in file
```

Sanity check: a monster record's `monname` (bytes 170..209) should be the name you
searched for, and the record must be 210-aligned. A spell record that reads as an
unrelated effect means the caste index was not decremented from the class number.
