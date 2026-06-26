# Item data: how the engine stores it and how to read raw values

Read this when asked about a specific item's real stats (magic plus, to-hit, damage,
AC, what an item actually does versus what its name says). It records the data model
and a repeatable recipe for pulling raw values out of the game data, so the
investigation does not have to be re-derived each time.

## The one fact that surprises people

An item has a single magic-plus field, `item.damage`. There is no separate to-hit
field. Both the "Damage +N" and the "Hit +M%" lines on an item are derived from that
one field (M = N * 5). And the item's printed name is an independent string that does
not have to agree with the plus. So "Helm of Might +2" can have a real plus of +1, and
the engine never notices the mismatch. The tooltip (driven by `item.damage`) is the
source of truth; the "+N" in the name is just flavor text.

## Structs (src/realmz_orig/structs.h)

- `struct item` is only an inventory reference: `short id; char equip, ident; short charge;`.
- `struct itemattr` is the loaded item record (the global `item` and the `all*` tables).
  It is exactly 100 bytes (hence `blank100` in main.c). Field order, with the short
  index of each (useful for raw reads):

  ```
  0 st        1 itemid     2 iconid     3 type      4 blunt
  5 nohands   6 lu         7 movement   8 ac        9 magres
  10 damage   11 spellpoints  12 sound
  13 wieght   14 cost      15 charge    16 iscurse  17 ismagical   (18 shorts = 36 bytes)
  int32_t itemcat[2]                                               (offset 36, 8 bytes)
  racerestrictions, casterestrictions, specificrace, specificcaste,
  raceclassonly, casteclassonly, spare2[7]                         (offset 44, 13 shorts)
  vssmall, vslarge, heat, cold, electric, vsundead, vsdd, vsevil,
  sp1, sp2, sp3, sp4, sp5, xcharge, drop                           (offset 70, 15 shorts)
  ```

  Byte offsets that matter: `itemid` at +2, `ac` at +16, `damage` (magic plus) at +20.
  `damage` is the plus. `heat/cold/electric/vsundead/vsdd/vsevil/vssmall` are separate
  bonus-damage fields that add to the damage roll but never to to-hit. `sp1..sp5` are
  special powers (e.g. `sp1 == 121` is a penetration "double to hit" weapon, `sp1 == 122`
  adds attacks).

## Where item stats and names live

- Stats (the `itemattr` records) are the data fork of `base/Realmz/Data Files/Data ID`.
  `main.c` (around line 938) freads it into four tables of 200 each, then byte-swaps
  big-endian Mac data with `CvtTabItemAttrToPc`:
  - weapons -> `allweapons[200]`  (itemid 0..199)
  - armor   -> `allarmor[200]`    (itemid 200..399)
  - helms   -> `allhelms[200]`    (itemid 400..599)  (this category also holds gloves,
    boots, shields, gauntlets, caps, not just helms)
  - magic   -> `allmagic[200]`    (itemid 600..799)
  - supply  -> `allsupply[200]` comes from a scenario file, `Scenarios/<name>/Data NI`,
    not from Data ID.

  So the data fork is 80000 bytes = 800 records * 100 bytes, in itemid order.

- `loaditem(id)` (loaditem.c) picks the table by `(id / 200)` and copies the record into
  the global `item`, then forces `item.type = abs(item.type)`.

- Names are the resource fork of the same file, `base/Realmz/Data Files/Data ID.rsrc`,
  opened as a resource file in `menuinit.c` (around line 97). They are mac-roman Pascal
  strings (length-prefixed). Lookups use
  `GetIndString(buf, getselection(itemid) + listoffset, itemid - getselection(itemid) + 1)`,
  where `getselection(id)` returns `(id / 200) * 200`. So within a category the name
  index is `itemid - categoryBase + 1`. There are two parallel lists per category:
  an unidentified/generic list ("Helm", "Shield") and an identified list with the magic
  names ("Helm of Might +2"). Both are in itemid order; entry N is the same itemid in
  each.

## Where the plus is used (so you can reason about effects)

- Tooltip: `showitems-showspecial.c` (around line 189) prints `Damage +item.damage`,
  then `Hit +(item.damage * 5)%`, then `Armor +item.ac`. One field, two lines.
- Equipping: `wear.c` (around line 169) sums worn item fields into the character:
  `c.damage += item.damage` (capped at 110), `c.ac += item.ac`, plus st, lu, magres,
  spellpoints, movebonus, special[], conditions, attacks. `c.damage` is therefore the
  sum of every worn magic plus.
- Character sheet: `updatecharinfo.c` shows attack bonus (DialogNum 11) as
  `conditions + character.damage * 5` and damage bonus (DialogNum 13) as
  `character.damage`. Both come from the same `character.damage`, so they always move
  together at a fixed 1:5 ratio.
- Combat: `attack.c` adds `item.damage` (weapon plus) to the damage roll and
  `character.damage` (all worn pluses) to the damage roll; the to-hit term is based on
  `character.damage` so every worn plus contributes 5 per point to to-hit, matching the
  character sheet. The penetration weapon (`sp1 == 121`) adds an extra `5 * item.damage`.

## Recipe: read an item's real stats from the data fork

1. Find the printed name in the resource fork to get its position in the category:

   ```
   LC_ALL=C grep -a -b -o "Helm of Might[^\n]*" "base/Realmz/Data Files/Data ID.rsrc"
   ```

   Then parse Pascal strings around that offset to list the identified names in order;
   the list is in itemid order. Anchor the alignment on a distinctive entry (for helms,
   "Helm of Pain -1" is the only early negative-AC helm) so you know which name maps to
   which itemid.

2. Read the record straight from the data fork. Category base index = category number
   (weapons 0, armor 1, helms 2, magic 3) times 200; record offset = itemid * 100.

   ```python
   import struct
   data = open("base/Realmz/Data Files/Data ID", "rb").read()
   def rec(itemid):
       off = itemid * 100
       st, iid, icon, typ, blunt, nohands, lu, mov, ac, magres, damage = \
           struct.unpack(">11h", data[off:off+22])
       return dict(itemid=iid, ac=ac, damage=damage, type=typ)
   print(rec(402))   # Helm of Might +2
   ```

   Sanity check the read: the `itemid` field in the record must equal the itemid you
   asked for (e.g. record 402 reports `itemid == 402`). If it does not, the offset or
   endianness is wrong.

## Worked example: "Helm of Might +2"

- Identified helm names in itemid order start at 400: 400 "Helm", 401 "Helm of Pain -1"
  (ac = -1, the anchor), 402 "Helm of Might +2", 403 "Helm of True Sight +3", ...
- Record 402: `itemid = 402, ac = 5, damage = 1`.
- So the real magic plus is +1, not +2. The tooltip reads "Damage +1 / Hit +5% / Armor +5".
  The "+2" in the name matches nothing in the data. Many items are mislabeled this way,
  so audits of "what should each item give" must read `item.damage`, not trust the name.
