# Making a Shimeji pack with an image model

What DockWings' buddy (`Sources/DockWings/Buddy.swift`, `BuddyBrain.swift`) needs from a
character pack, written so an image-generating agent (Antigravity with Nano Banana Pro,
or any model that takes a reference picture) can make one from a single picture.

## Output

- A folder `art/Buddies/<catalog id>/` (or any folder you drop on the library drawer)
  with `shime1.png` ... `shime46.png`.
- Every frame: PNG, exactly **128 x 128**, **transparent background** (real alpha, no
  white or checkerboard), the **same scale** in every frame.
- The character **faces left** in every frame. DockWings mirrors frames to face right.
- Standing frames: **feet on the bottom edge**, body centred horizontally (x = 64).
  DockWings measures empty rows under the feet of `shime1.png`, so a few are fine, but
  keep them the same in every standing frame.
- Chibi proportions read best at 56-64 pt on screen: big head, short body, thick
  outlines, flat colours.

## Frames

Numbers are fixed: DockWings looks frames up by number (Shimeji-ee's default
`actions.xml`). "Anchor" is the point that touches the floor, wall or ceiling, in the
128 x 128 frame from the top-left.

| Frame | Pose | Anchor |
|---|---|---|
| 1 | Standing, neutral (also the middle of the walk) | feet, 64,128 |
| 2 | Walking, left foot forward | feet |
| 3 | Walking, right foot forward | feet |
| 4 | Falling: arms and legs up, surprised | feet |
| 5, 7, 9 | Held up by the head/collar while the hand moves left: body swings to the right, 5 a little, 7 more, 9 most | top centre |
| 6, 8, 10 | Same, hand moving right: body swings left, 6 a little, 8 more, 10 most | top centre |
| 11 | Sitting on the floor, legs forward | seat on the bottom edge |
| 12, 13, 14 | Climbing a wall on the LEFT: body pressed against the left side of the frame, hands and feet on that side; 12 reaching up, 13 holding, 14 pulling up | 64,128 |
| 15, 16, 17 | Sitting, head turned: 15 slightly away, 16 away, 17 back | seat |
| 18, 19 | Landing: 18 squashed (knees bent), 19 recovering | feet |
| 20 | Crawling on hands and knees | knees |
| 21 | Lying flat on the stomach (also used for sleeping) | body on the bottom edge |
| 22 | Jumping, arms up, happy | feet |
| 23, 24, 25 | Hanging from a ceiling by the hands, body below: 23 both hands, 24 reaching right, 25 reaching left | hands at 64,48 |
| 26, 27, 28, 29 | Sitting, looking up (26) and turning the head round (27-29) | seat |
| 30 | Sitting with legs up | seat |
| 31, 32, 33 | Sitting on a ledge, legs dangling below the bottom edge: 31 still, 32 left leg swung, 33 right leg swung | seat at 64,112 (legs hang 16 px lower) |
| 34-38 | Carrying or throwing a window (classic Shimeji); optional, any copy of 1/22 is fine | feet |
| 39-46 | Splitting into two (classic Shimeji); optional, copies of 1 are fine | feet |

Frames DockWings uses most: 1-4, 11, 21, 22 (always), 12-14 and 23-25 (climbing; without
them the character never climbs), 18-20 (landing, crawling, tripping), 31-33 (sitting on
window edges), 5-10 (being picked up), 26 (looking up).

## Extra moves (optional)

More frames (some packs have 70+) become extra moves through an `actions.xml` next to the
frames. Each extra action is a list of poses; images can sit in subfolders:

```xml
<Mascot xmlns="http://www.group-finity.com/Mascot">
  <ActionList>
    <Action Name="Dance" Type="Animate" BorderType="Floor">
      <Animation>
        <Pose Image="/dance/shime1.png" ImageAnchor="64,128" Velocity="0,0" Duration="5"/>
        <Pose Image="/dance/shime2.png" ImageAnchor="64,128" Velocity="0,0" Duration="5"/>
      </Animation>
    </Action>
  </ActionList>
</Mascot>
```

`Duration` is in ticks of 40 ms. DockWings plays extras now and then, from the right-click
menu, and by name: an action whose name contains "dance" plays to music, "pet" or
"nuzzle" when petted, "sleep" or "yawn" before sleeping.

## How to generate

1. Give the model one clear reference picture of the character (e.g. the catalog sprite).
2. Ask for **sheets**, not single frames: one image per group (walk 1-3; held 5-10;
   climbing 12-14; ceiling 23-25; sitting 11, 15-17, 26-30; ledge 31-33; others), in a
   grid of equal square cells, same character, same outfit, same scale, facing left,
   plain flat background. Sheets keep the style consistent; single calls drift.
3. Cut each cell to 128 x 128, remove the background to real transparency, put the
   feet on the bottom edge and centre the body (except climbing: against the left side;
   ceiling: hands at y = 48).
4. Name the files by the table above. Check the walk (1, 2, 1, 3) by flipping through
   it: feet should alternate and the head should not jump.
5. Don't generate frames by shifting or rotating one picture: it walks like a sticker.

## Checking it

`uv run --with pillow python tools/shimeji-check.py art/Buddies /tmp/sheets` checks every
pack (sizes, transparency, placeholders, duplicates, where feet, hands and legs sit) and
writes a contact sheet per pack to look at. Fix every ISSUE line, then look at the sheets.

Also:

- Never save a download site's "Not available" (or similar) placeholder as a frame. If a
  frame is missing, draw or generate it.
- Frames 47 and up only make sense with an actions.xml that uses them for new movement;
  copies of earlier frames add nothing.
- Save straight (not premultiplied) alpha: grey skin and dark halos around the character
  mean the colours were left premultiplied.

Drop the folder on the character drawer, put it out on the Dock, then run the scripted
test: `defaults write local.dockwings BuddyTest all`, relaunch, read
`~/Library/Logs/DockWings/buddy.log` (the first line says `climb true/false` and how many
frames loaded), and `defaults delete local.dockwings BuddyTest` afterwards.
