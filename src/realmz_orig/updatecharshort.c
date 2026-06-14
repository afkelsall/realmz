#include "prototypes.h"
#include "variables.h"

/************************** updatecharshort *****************************/
void updatecharshort(short who, short forcebox) {
  GrafPtr oldport;
  short ydist;
  Rect savedClip;

  if ((who < 0) || (who > charnum))
    return;

  GetPort(&oldport);
  SetPort(GetWindowPort(screen));
  // CHANGED FROM ORIGINAL IMPLEMENTATION: clip each stat number to the box it
  // is erased into. The substitute fonts can be taller than the originals, so
  // descenders would otherwise paint below the box and leave artifacts that the
  // per-box EraseRect never clears. Restored before returning.
  GetClipRect(&savedClip);
  RGBBackColor(&greycolor);
  BackPixPat(base);
  TextFont(font);
  TextFace(bold);
  TextMode(1);
  TextSize(17);

  if (forcebox) {
    updatepictbox(who, 0, 0);
    if (incombat)
      updatelight(who, FALSE);
  }

  box.top = who * 50 + 8;
  box.bottom = box.top + 15;
  box.left = 600 + leftshift;
  box.right = 635 + leftshift;

  ForeColor(yellowColor);
  if (c[who].ac > -1)
    MoveTo(605 + leftshift, box.top + 11);
  else
    MoveTo(600 + leftshift, box.top + 11);
  MyrNumToString(c[who].ac, myString);
  EraseRect(&box);
  ClipRect(&box);
  MyrDrawCString((Ptr)myString);

  box.top = who * 50 + 29;
  box.bottom = box.top + 15;
  box.left = 416 + leftshift;
  box.right = box.left + 29;

  ydist = box.top + 30;

  if (c[who].staminamax > 999)
    TextSize(12);

  MyrNumToString(c[who].stamina, myString);
  MoveTo((444 - TextWidth(myString, 0, strlen(myString))) + leftshift, box.top + 12);
  EraseRect(&box);
  ClipRect(&box);
  if (c[who].stamina < c[who].staminamax)
    ForeColor(whiteColor);
  MyrDrawCString((Ptr)myString);

  TextSize(17);

  if (c[who].spellpointsmax) {
    if (c[who].spellpointsmax > 999)
      TextSize(12);
    RGBForeColor(&cyancolor);
    box.left += 150;
    box.right += 151;
    if (c[who].spellpoints < c[who].spellpointsmax)
      ForeColor(whiteColor);
    MyrNumToString(c[who].spellpoints, myString);
    MoveTo((593 - TextWidth(myString, 0, strlen(myString))) + leftshift, box.top + 12);
    EraseRect(&box);
    ClipRect(&box);
    MyrDrawCString((Ptr)myString);
  }
  ClipRect(&savedClip);
  SetPort(oldport);
}
