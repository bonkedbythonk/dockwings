# Research: ambient utility apps (notch and Dock-adjacent)

Date: 2026-11-11. Purpose: inform DockWings, a macOS 27 app that puts a now-playing widget, a drag-triggered file shelf and quick todos in the empty space left and right of a bottom-docked Dock.

Evidence levels used below:
- **[source]** read in the actual Swift source (boring.notch, DockDoor, mediaremote-adapter).
- **[vendor]** from the product's own page or README.
- **[secondhand]** a review or aggregator. Weak.
- **[inference]** my reading, not verified.

Alcove, NotchNook and MediaMate are closed source, and their pages say little about materials, motion or implementation. Anything about their internals is therefore weak or absent. All spring and timing numbers in section 2 come from boring.notch only.

## 0. Who actually works beside the Dock

Almost every app in this space targets the notch (top centre). Only a few use the Dock sides:

| App | What it is | Evidence |
|---|---|---|
| **Docktor** (docktor.pages.dev, free beta 0.15.2, macOS 26+) | Glass widgets beside the Dock (music, calendar, weather, system stats, device batteries), "drawers" that open for detail, plus Dock window previews. The closest product to DockWings. | [vendor] |
| **DockWidgets** (anishmanchanda.github.io/DockWidgets-webpage) | Transparent widgets (FlipClock, weather, music) kept within the Dock's height. macOS 14.6+. | [vendor] |
| **DockDoor** (open source, github.com/ejbills/DockDoor) | Not side widgets. It is Dock-adjacent: hover previews above Dock icons, a media widget popup for Spotify/Music icons, and an active-app indicator window drawn over the Dock. It has the best open-source Dock geometry code. | [source] |

Docktor details worth copying (all [vendor] from its page and Show HN post):
- Widgets "follow auto-hide Dock timing and animation and rise from below". They stay up while a drawer is open or a widget is hovered, even if the Dock hides.
- Widgets do not appear over full-screen apps, including during Space swipes (fixed in 0.15.2).
- The author says they matched macOS blur radii and animation timing "so it feels like part of the Dock".
- Permissions are optional and per feature. Accessibility is needed only for previews and the switcher. Widgets work without it. Automation is for Apple Music. Calendar uses EventKit. Spotify uses the Web API, not AppleScript.
- Earlier-version complaints [secondhand, aggregator, unconfirmed]: awkward behaviour with auto-hide, Dock magnification jitter, and popovers overlapping when the Dock is large. 0.11.2 reportedly fixed magnification jitter and side-Dock spacing. Its FAQ says that with an auto-hide Dock, "the widgets and preview mechanics will not be accessible" in older text, which 0.15.2 contradicts. Treat auto-hide as the hardest case.
- The Dock grows as apps open, which shrinks the side space. A secondhand write-up says widgets may reflow or clip, and the Dock recentres on every app launch.

## 1. Visual language

### boring.notch [source]
- **Material:** pure opaque black, `.background(.black)` clipped to a custom `NotchShape`, plus a 1 pt black strip along the top edge to hide the seam with the hardware notch. The window forces dark appearance. No blur or glass. This works only because the real notch is black, so the shape reads as the notch growing.
- **Shape:** `NotchShape` has two animatable corner radii. Closed is top 6 / bottom 14. Open is top 19 / bottom 24. The top corners curve inward (the shape flares into the menu bar), the bottom corners round outward. Both radii animate, so the silhouette morphs rather than just scaling.
- **Resting state:** closed notch exactly matches the hardware notch size. Width is derived from the screen: `frame.width` minus `auxiliaryTopLeftArea` and `auxiliaryTopRightArea`, plus 4 pt. Height can be the real notch (`safeAreaInsets.top`), the menu bar height or a custom value. On non-notch displays it uses a user-set height (so it is a black bar or pill that simulates a notch).
- **Idle content:** nothing extra. While music plays, the closed notch widens and shows a small album art tile on the left (height minus 12 pt, 4 pt corner radius) and a visualizer (Lottie or bars) on the right, with a black gap in the middle that matches the physical notch. This is the "live activity" look.
- **Open state:** 640 x 190 pt. Album art is 90 x 90 with a 13 pt radius when open (20 x 20 and 4 pt when closed), and it is shared between states via `matchedGeometryEffect`.
- **Shadow:** only when open or hovered, black at 0.7 opacity, radius 6 (4 without corner scaling).
- Album-art-derived colour: `MusicManager` computes an average colour of the artwork and animates it (`.smooth`) for tinting controls and the visualizer.

### Others
- **NotchNook** [secondhand and vendor]: the classic black notch, with a "Liquid Glass notch" offered in the Pro tier. Closed state with music shows art on one side and a waveform on the other. Expanded state is a widget tray (media, calendar, shortcuts, mirror, notes, to-dos). It always draws a notch on external displays, which a reviewer called jarring.
- **Alcove** [vendor, thin]: sells "fluid transitions, live activities, swipe gestures, customizable HUDs, lock screen widgets" (v1.7, $12.99, macOS 15+). Reviewers describe vertical swipes to expand or dismiss. No technical detail found. I could not confirm a file shelf or hover trigger.
- **MediaMate** [secondhand]: replaces volume and brightness HUDs, with four styles, one chosen per display. On an external display, now-playing becomes a separate floating panel instead of a notch. The notch expands on track change, play/pause or volume change for a configurable duration, can be excluded per app, and can be hidden during chosen Focus modes.
- **Atoll** [vendor]: an open-source boring.notch descendant. It credits boring.notch for interaction patterns, and credits SkyLightWindow for lock-screen widgets. It adds two-finger swipes to open and close, and horizontal swipes on the music pane for track skip or plus or minus 10 s seek. No Liquid Glass mention.
- **DockDoor** [source]: the hover container uses a `BlurView` (an NSVisualEffectView wrapper) clipped by `RoundedRectangle(style: .continuous)` with a hairline overlay, a stacked soft shadow drawn by a separate CALayer outside the clip, and `.smooth(duration: 0.35)` for artwork cross-fades. Artwork is a continuous-corner rounded rect.
- **Docktor** [vendor]: translucent glass bars at the Dock's height, drawers for detail.

### Why they don't look "pasted on" (synthesis)
1. They copy an existing system silhouette (notch shape, Dock tile radius) instead of inventing one.
2. They use continuous (squircle) corners and animate the corner radii with the size.
3. Closed state carries almost no content. The widget is a plain, small, quiet glyph and exists only when something is happening.
4. Content is dark-on-dark or glass with a hairline edge, and artwork is the only colour.
5. Motion matches the system (Docktor claims it matched Dock timing).

[inference] For DockWings the equivalent of the notch trick is: match the Dock's own shell. Same height as the Dock tile row, same corner radius family as the Dock's glass plate, same vertical baseline, and same material as the Dock, so the Dock looks like it simply has wings.

## 2. Motion

### The key architecture question: resize the window, or animate inside a fixed one?
boring.notch uses a **fixed, large, transparent window with the animated shape inside** [source].
- `windowSize` is a constant 640 x 210 (`openNotchSize` 640 x 190 plus a 20 pt `shadowPadding`).
- Each screen gets one `NSPanel` (borderless, non-activating, utility/HUD style) positioned once by `setFrameOrigin` at the top centre. It is never resized during open or close.
- SwiftUI animates the content: `.frame(height:)` on the notch layout, the `NotchShape` corner radii (animatable data), `.padding`, and `matchedGeometryEffect` for art. All run in one `withAnimation` / `.animation(value:)` transaction on the GPU-composited layer tree, so there is no AppKit window-resize latency or tearing.
- Cost: the window covers dead area. In boring.notch the transparent area is part of the panel, so hit-testing, drag regions and hover are computed from the visible shape (`contentShape`, plus separate notch-region rectangles for drag), not from the window frame. Verify click-through behaviour of the transparent corners on macOS 27 before relying on it [inference].
- Drag detection is independent of the window: a screen-coordinate `CGRect` of the open-notch footprint (640 x 190 at the top centre) is checked against `NSEvent.mouseLocation`.

Takeaway for DockWings: one fixed panel per wing, sized for the largest expanded state plus shadow room, anchored to the Dock's edge. Only change the panel frame when the Dock itself changes, never inside an expand or collapse animation.

### Springs and timings (boring.notch) [source]
| Use | Value |
|---|---|
| Open | `.spring(response: 0.42, dampingFraction: 0.8)` |
| Close | `.spring(response: 0.45, dampingFraction: 1.0)` (critically damped, no overshoot on the way out) |
| Hover/resize interactions | `.interactiveSpring(response: 0.38, dampingFraction: 0.8)`, deliberately one shared spring "to avoid conflicting animations" |
| Gesture progress, track change | `.smooth` |
| Open-state content swaps | `.smooth(duration: 0.35)` |

Pattern: bouncy open, flat close.

### Triggers and debounce [source]
- **Hover:** `onHover` on the visible shape. On enter, set `isHovering` with the shared spring and give haptic feedback. If "open on hover" is enabled, start a cancellable `Task` that sleeps `minimumHoverDuration` (user setting) and then opens only if still hovering. On exit, a cancellable `Task` sleeps 100 ms and then closes. Re-entering cancels the pending close. This 100 ms grace stops flicker while the pointer crosses small gaps.
- A second close path runs when the open notch is not hovered. It also sleeps 100 ms and checks guards (popover active, a share sheet open).
- Hover is optional. The default requires a click or gesture. Also supported: two-finger swipe (a pan gesture with progress scaling the content 1.0 to 0.6) and a keyboard shortcut.
- Extended hover padding (30 pt) and a zero-height padding (10 pt) enlarge the target when the closed notch is small.
- Drag-in opens it immediately with no dwell (section 4).
- MediaMate (secondhand): expands on events (track change, volume) for a configurable time.
- Atoll (vendor): also a configurable hover behaviour.

### Marquee [source]
- boring.notch `MarqueeText`: measures text width through a preference key. If wider than the frame, it renders two copies with a 20 pt gap and animates offset linearly at about 30 pt/s (duration = width / 30) after a start delay (`minDuration`, default 3 s), repeating forever. It clips to the frame.
- DockDoor `Marquee`: `TimelineView(.animation(minimumInterval: 1/30))` computing the offset from elapsed time (about 15 pt/s plus a delay). Cheaper on the render server and safe to pause.

## 3. Now playing

### The macOS 15.4+ problem
Since macOS 15.4 the private `MediaRemote` calls (`MRMediaRemoteGetNowPlayingInfo` and friends) return nothing for ordinary processes. The framework checks the caller's bundle identifier, and only processes with a `com.apple.` identifier are served [source: mediaremote-adapter README, citing an issue thread in Lyric Fever].

**mediaremote-adapter (ungive/mediaremote-adapter)** is the workaround everyone shares:
- Runs `/usr/bin/perl`, which is an Apple platform binary reported as `com.apple.perl*`, so MediaRemote answers it.
- Perl loads a small helper framework (`MediaRemoteAdapter.framework`, bundled with your app but **not linked**) that prints updates to stdout.
- Your app spawns `perl mediaremote-adapter.pl <framework> stream` and parses newline-delimited JSON. Commands: `get`, `stream`, `send`, `seek`, `shuffle`, `repeat`, `speed`, `test`.
- Payload keys: `bundleIdentifier`, `parentApplicationBundleIdentifier`, `playing`, `title`, `artist`, `album`, `duration`, `elapsedTime`, `timestamp`, `artworkMimeType`, `artworkData` (base64), plus `playbackRate`, shuffle and repeat. Stream updates can be diffs (`diff: true`), so the client must merge them.
- A `test` command (needs the bundled `MediaRemoteAdapterTestClient`) exits 0 if the adapter still works, intended for falling back to AppleScript.
- The README's tested-on badge (macOS 27.0, build 26A5425a, last tested 2026-09-04) says it works on macOS 27 today. The README explicitly warns the API may break and asks Apple for a proper entitlement.
- A maintained Swift package fork exists: **ejbills/mediaremote-adapter** (same author as DockDoor, used by DockDoor via `import MediaRemoteAdapter`).
- Risk: this depends on an Apple platform binary staying entitled. It is not App Store compatible [inference]. It has an official-looking fallback path (`test` then AppleScript), which every app below keeps.

### How the apps read and control playback
- **boring.notch** [source]: `NowPlayingController` spawns the Perl stream process and decodes JSON into a `PlaybackState`. It loads send-command, seek, shuffle and repeat functions from the system `MediaRemote.framework` by name for *control* (`MRMediaRemoteSendCommand` with codes 0 play, 1 pause, 2 toggle, 4 next, 5 previous). Controllers are swappable: Apple Music and Spotify (AppleScript), YouTube Music (HTTP API with auth), and the MediaRemote-based Now Playing (system-wide). The user picks one during onboarding, with an `MusicControllerSelectionView`.
- **DockDoor** [source]: `MediaRemoteService` wraps the adapter's `onTrackInfoReceived`, activated only when a media widget is shown. It matches the playing app to a Dock icon by bundle ID, then by fuzzy name match.
- **Docktor** [vendor]: Spotify via the Web API and Apple Music via Automation (AppleScript), notably not the private MediaRemote path.
- **DockWidgets** [vendor]: AppleScript for Spotify and Apple Music only.

### Position and progress [source]
- boring.notch computes the position from a snapshot instead of polling: `estimatedPlaybackPosition = elapsedTime + (now - timestamp) * playbackRate`, clamped to `0...duration`. The UI re-evaluates it on a display-linked timeline only while visible and playing. Diff updates while paused carry the position forward. Slider seeks send `seek(to:)`.
- Artwork: decoded from the base64 payload. A change in title, artist, album, bundle ID or artwork bytes triggers a transition (a flip and cross-fade; there is an `isFlipping` flag). If no artwork exists, the app icon is used. The average colour is computed off the main thread.
- DockDoor adds a 0.35 s `.smooth` artwork cross-fade.
- Optimistic UI: DockDoor has a "playback intent" step that flips play/pause immediately, then resyncs from the stream (so the button never looks laggy).

## 4. File shelf and drag detection

### boring.notch `DragDetector` [source]
No special entitlement and no polling of the foreground app. It uses three global `NSEvent` monitors (they require no Accessibility permission for mouse events):
1. `leftMouseDown`: remember `NSPasteboard(name: .drag).changeCount`.
2. `leftMouseDragged`: if the drag pasteboard's `changeCount` differs from the remembered value *and* its types include a file URL, URL or string, then a real *content* drag has started (this distinguishes dragging a file from dragging a window or selecting text). From then on, hit-test `NSEvent.mouseLocation` against a fixed screen `CGRect`. The first inside-crossing fires `onDragEntersNotchRegion`, the first outside-crossing fires exit.
3. `leftMouseUp`: reset state.

One detector per screen, created with that screen's frame and rebuilt on screen-parameter changes, Space changes and window-screen changes. The hot zone is the full footprint of the open notch (640 x 190), anchored at the top centre.

On entry, the app opens the notch immediately and switches to the Shelf tab. It does not wait for hover.

### Drop and storage [source]
- Shelf view: SwiftUI `.onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted:)`. Empty state is a 3 pt round-capped dashed outline: accent colour at 0.9 opacity when targeted, white at 0.1 otherwise.
- `ShelfDropService` turns each `NSItemProvider` into a `ShelfItem`: a file (stored as a **security-scoped bookmark**, not a copy), a link, text, or raw data (written to a temp file and bookmarked, flagged temporary).
- Items persist (`ShelfPersistenceService`), with thumbnails (QuickLook thumbnailing), Quick Look preview, a share sheet, AirDrop via `QuickShareService`, and drag-out. Files are referenced, not duplicated, so the originals stay in place.
- NotchNook [vendor, secondhand]: dropping onto the notch opens the Tray and an AirDrop target. Items stay until dragged out. Pro adds a "Pocket" and clipboard history, and file conversions.
- DynamicLake [secondhand]: drop and drop actions. Perch [secondhand]: a shelf that appears from the notch area.

### Implication for DockWings [inference]
The same mouse-monitor plus `.drag` pasteboard trick works unchanged. The hot zone is each wing's rect (and maybe a generous margin along the Dock's bottom edge), derived from the Dock geometry in section 5. The shelf can open the moment a content drag enters, since the pointer is already low on screen.

## 5. Dock geometry and edge cases

### Finding the Dock and its free space (DockDoor source)
- `CoreDockGetOrientationAndPinning` gives position (left, bottom, right). Dock thickness per screen is derived by subtraction: bottom = `visibleFrame.minY - frame.minY`, and similarly for the other sides (`DockUtils.getDockSize`). This works even with auto-hide off. With auto-hide on, the inset is 0, so the Dock is effectively invisible to this method.
- Exact item rect: the Accessibility tree of the Dock process (`com.apple.dock`). The child with role `AXList` holds the tiles. The list's `AXPosition`/`AXSize` is the Dock plate span, and each child has a subrole (`AXApplicationDockItem` and so on) and a URL. This yields the left and right edges, which gives the free space as `screen.frame` minus the list rect, per side. It needs Accessibility permission (Docktor lists this as optional, for previews). It uses Quartz (top-left) coordinates, so convert them to AppKit (bottom-left) per screen.
- `DockUtils.runningDock` and a screen-index helper map the list rect to the screen that holds the Dock (it appears on one display, depending on the "Displays have separate Spaces" setting and where the pointer last hit the bottom edge).
- The "resting frame" correction: when tiles magnify, item frames grow. DockDoor takes the resting y from the max extent of siblings. DockWings should read the AXList frame, which does not magnify as much, or apply the same correction. Docktor says magnification jitter was its bug.
- Dock icon size changes the Dock height. The indicator code has size-dependent constants measured for sizes 36 to 156, with extra offsets on macOS 27 (a 5 pt "dot inset"), meaning the macOS 27 Dock renders its tiles slightly differently. Re-measure on 27.
- Observe changes: `NSWorkspace` app launch and terminate (the Dock list changes, the plate recentres), AX observers on the Dock process (`AXUIElementCreateApplication(dockPID)`), `NSApplication.didChangeScreenParametersNotification`, and the Dock's `com.apple.dock` preference changes. Debounce them.

### Window and level choices
| App | Class | Level | Collection behaviour |
|---|---|---|---|
| boring.notch | `NSPanel`, `.nonactivatingPanel`, borderless, can't become key or main | `.mainMenu + 3` | `canJoinAllSpaces`, `stationary`, `fullScreenAuxiliary`, `ignoresCycle` |
| DockDoor indicator | `NSPanel`, non-activating | `.statusBar` | `canJoinAllSpaces`, `transient`, `fullScreenAuxiliary`, `ignoresCycle`; `ignoresMouseEvents = true`; `animationBehavior = .none` |

- boring.notch also adds the window to a private CGS space created at the maximum level (`CGSSpaceCreate`, `CGSSpaceSetAbsoluteLevel` 2147483647). This keeps it above everything including full-screen content and, optionally, via SkyLight's `SLSRemoveWindowsFromSpaces`/delegate, above the lock screen. Both are private APIs. Skip them: DockWings should *not* appear over full-screen apps (Docktor behaves this way on purpose).
- `sharingType = .none` is an optional "hide from screen recording" setting in boring.notch.
- Never become key, so typing in other apps isn't interrupted. But a quick-todo field needs focus. Options [inference]: temporarily allow `canBecomeKey` only while the text field is active, or use a small separate key panel for text entry.

### Full-screen, multi-display, Spaces, Mission Control
- **Full screen:** boring.notch uses the MacroVisionKit `FullScreenMonitor`, an async stream of Space changes. It records per screen UUID whether a full-screen Space is active, with an option to restrict the hide behaviour to when the music app itself is full-screen. Result: hide or collapse the notch. NotchNook (secondhand) stays on top of full-screen video, which a reviewer found obstructive. Docktor hides over full-screen apps. DockDoor's `fullScreenAuxiliary` flag is what lets a panel coexist with a full-screen Space at all. If it is omitted, the panel won't show there.
- **Multi-display:** both boring.notch and Atoll keep one window or view model per `NSScreen`, keyed by `displayUUID`, with a "show on all displays" option or a preferred display, rebuilt on `didChangeScreenParametersNotification`. MediaMate lets each display have its own style. NotchNook draws a fake notch on external displays, a known criticism. For DockWings the Dock lives on one screen at a time, so create the wings only on the Dock's screen and move them when it changes.
- **Spaces / Mission Control:** `canJoinAllSpaces` + `stationary` keep the panel from sliding with Space switches. `ignoresCycle` keeps it out of Cmd+` cycling. `.stationary` also keeps it still during Mission Control, as the Dock does.
- **Auto-hide Dock:** boring.notch has no equivalent. Docktor mirrors the Dock's timing, slide and speed settings, and keeps widgets up while a drawer is open or hovered. Honest options for DockWings: (1) only run when the Dock is visible, (2) follow Dock show/hide using the `com.apple.dock` `autohide-delay` and `autohide-time-modifier` defaults, (3) keep the wings pinned independently. This is the biggest open design decision.
- **Magnification:** read the non-magnified frame (section 5, above).
- **Hiding when not useful:** MediaMate hides during selected Focus modes. boring.notch hides in full-screen and can restrict to "now playing only". Docktor widgets disappear when the Dock hides. Idle widgets collapse to nothing.
- **Screen recording:** `sharingType = .none` (boring.notch setting) hides the panel from capture. DockDoor's thumbnails require Screen Recording permission, which DockWings does not need.
- **Gatekeeper and permission posture:** Docktor asks for nothing at first launch and gates each feature. DockWidgets asks only for Automation. A user-facing "why we need this" row per permission is the norm.

## 6. Liquid Glass (macOS 26/27)

What the sources show:
- **NotchNook Pro** sells a "Liquid Glass notch" as a premium style next to the classic black notch [vendor]. Black is still the default. No technical detail.
- **Docktor** is macOS 26+ only and describes "glass widgets" [vendor]. Its 0.15.2 notes mention "cleaner drawer animations on macOS 27", so it tracks the 27 betas.
- **boring.notch** and **Atoll**: no use of `glassEffect` or `NSGlassEffectView` found. A code search of boring.notch for both names returned nothing. Black shape only.
- **DockDoor** [source, notable]: `LiquidGlass.swift` goes beyond public API. It reaches private SwiftUI symbols by mangled name (`_Glass` variants such as dock, controlCenter, widgets, sidebar, clear, regular) through `@_silgen_name`, validates the runtime type's size, and builds a `Glass` through the explicit initialiser, so the user can pick a "flavor" slider. It is gated on `#available(macOS 27, *)`, caches `Glass` values, and falls back to blur on older systems. Interesting evidence that macOS 27 has Dock-flavoured glass that public API does not expose, and a warning that copying it is fragile.

Public API guidance (WWDC25 session 310, read; the AppKit summary is from the session, the SwiftUI notes below are not from a fetched page):
- AppKit: `NSGlassEffectView` takes a `contentView` (don't place it behind content as a sibling) and has `cornerRadius` (large value gives a capsule) and tint. `NSGlassEffectContainerView` groups nearby glass so it renders as one sampling pass and lets shapes merge by proximity (`spacing`). Glass cannot sample other glass, so group. Use glass sparingly, for top-level controls.
- SwiftUI (from my own knowledge, the Apple page failed to load, so verify): `.glassEffect(_:in:)` with `Glass.regular`/`.clear`/`.interactive()`/`.tint()`, `GlassEffectContainer(spacing:)`, and `glassEffectID(_:in:)` with a namespace for morphing between shapes.
- Search results flagged (anecdotal, forum-level): a non-key `NSPanel` may not show the active glass appearance. A forum thread asks whether it can be forced on a non-key panel, with no answer found. DockDoor's `forceActiveAppearance` private option is aimed at exactly this. This matters for DockWings, whose wings are non-key panels. An Electron PR notes that custom borderless window corner masks plus shadows caused WindowServer GPU load on macOS 26, so prefer AppKit's own corner/shadow handling to a hand-built mask [secondhand].

## 7. Takeaways for DockWings
1. **Match the Dock, not the notch.** The notch trick (black shape that continues the hardware) becomes: same height, baseline, corner radius and glass flavour as the Dock plate. Glass on macOS 26+/27 via public `NSGlassEffectView`/`GlassEffectContainer`; do not copy DockDoor's private `_Glass` symbols. Test non-key panel appearance early.
2. **One fixed transparent panel per wing, content animated inside.** Size it for the largest expanded state plus shadow room. Do not resize the window during animation (boring.notch's design). Resize only when the Dock changes.
3. **Spring pair:** open `spring(response 0.42, damping 0.8)`, close `spring(response 0.45, damping 1.0)`. One shared spring for hover. Hover-in dwell as a setting, close debounce of about 100 ms using cancellable Tasks. Animatable corner radii, `matchedGeometryEffect` for artwork.
4. **Dock geometry:** `CoreDockGetOrientationAndPinning` plus `visibleFrame` inset for thickness, and the Dock process's `AXList` frame for the plate span. Free side space is `screen.frame` minus that rect. Accessibility makes it exact. Without it, estimate from the Dock's preferences (tilesize, magnification) [inference]. Observe app launch/terminate and screen changes with debouncing.
5. **Auto-hide and full screen are the product's hard edges.** Docktor's behaviour (follow Dock timing, stay up while hovered or a drawer is open, never over full-screen apps) is the target. Use `canJoinAllSpaces`, `stationary`, `ignoresCycle`, non-activating panel; skip CGS/SkyLight private spaces.
6. **Now playing:** mediaremote-adapter (via the maintained ejbills Swift package) for system-wide state, with a `test` check and AppleScript fallback for Music and Spotify. Compute progress from `elapsedTime`, `timestamp` and `playbackRate` instead of polling. Merge diff updates. Optimistic play/pause. Marquee via `TimelineView` at 30 fps, paused when hidden. Artwork rounded-continuous with a 0.35 s cross-fade and an app-icon fallback.
7. **File shelf:** global `leftMouseDown/Dragged/Up` monitors plus `NSPasteboard(name: .drag).changeCount` and a type check to detect a real content drag, with each wing's rect as the hot zone. Open instantly on entry with no dwell. Drop with `.onDrop`; store files as security-scoped bookmarks (originals untouched) and persist them; dashed outline that goes accent when targeted.
8. **Permissions and idle state:** ask for nothing on first launch and gate per feature, like Docktor. Idle wings should be nearly invisible: a small glyph at most, and fully collapsed when there is no media, no shelf items and no todos due.

## Sources
- boring.notch source: https://github.com/TheBoredTeam/boring.notch (boringNotch/ContentView.swift, sizing/matters.swift, observers/DragDetector.swift, observers/FullscreenMediaDetection.swift, components/Notch/BoringNotchSkyLightWindow.swift, components/Notch/BoringNotchWindow.swift, components/Notch/NotchShape.swift, private/CGSSpace.swift, MediaControllers/NowPlayingController.swift, managers/MusicManager.swift, components/Live activities/MarqueeTextView.swift, components/Shelf/*, boringNotchApp.swift)
- mediaremote-adapter: https://github.com/ungive/mediaremote-adapter and https://github.com/ejbills/mediaremote-adapter
- DockDoor source: https://github.com/ejbills/DockDoor (Utilities/LiquidGlass.swift, DockUtils.swift, ActiveAppIndicator/*, Media/MediaRemoteService.swift, Components/Marquee.swift, Hover Window views)
- Atoll: https://github.com/Ebullioscopic/Atoll
- Docktor: https://docktor.pages.dev/ , https://hnshowcase.com/post/47944044/docktor-i-put-live-window-previews-and-widgets-on-the-macos- , https://chatgate.ai/post/docktor (secondhand)
- DockWidgets: https://anishmanchanda.github.io/DockWidgets-webpage
- NotchNook: https://lo.cafe/notchnook ; MacStories review of NotchNook and MediaMate: https://www.macstories.net/reviews/notchnook-and-mediamate-two-apps-to-add-a-dynamic-island-to-the-mac/
- Alcove: https://tryalcove.com (marketing page only), plus secondhand reviews found via search
- Apple WWDC25 session 310, "Build an AppKit app with the new design": https://developer.apple.com/videos/play/wwdc2025/310/
- Not retrieved: Apple's NSGlassEffectView and SwiftUI "Applying Liquid Glass to custom views" documentation pages loaded with title only.

## Gaps and honesty notes
- Nothing was run or tested. No app was installed.
- No source exists for Alcove, NotchNook, MediaMate, DynamicLake or Docktor. Their behaviour is from vendor text and reviews.
- boring.notch's hover and click-through behaviour for the transparent part of its fixed panel is inferred from code structure.
- boring.notch's BoringAnimations library value was not found; the numbers listed are the ones literally in ContentView.swift.
- Docktor's own FAQ and secondhand summaries disagree on auto-hide behaviour. The vendor page (0.15.2) is treated as authoritative.
