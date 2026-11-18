# Changelog

What changed between builds, with anything you must do when you rebuild and
reinstall. There are no signed releases: everyone builds from source, so read
the **Before you rebuild** notes first. The Mac and phone apps update together.

## Unreleased

### Before you rebuild

* **Phone notifications now take their push key from the build, not from
  Settings.** The *Team ID*, *Key ID* and *Choose .p8* fields in
  *Settings › Remote Shell › Notifications* are gone. To keep notifications:
  put your APNs key in `Config/` (`*.p8` is gitignored), add
  `PASSTHROUGH_PUSH_KEY_FILE = Config/AuthKey_<Key ID>.p8` to
  `Config/Signing.xcconfig` (plus `PASSTHROUGH_PUSH_KEY_ID` if the file isn't
  named `AuthKey_<Key ID>.p8`), run `xcodegen generate`, and rebuild the Mac
  app. The team is `DEVELOPMENT_TEAM`, or `PASSTHROUGH_PUSH_TEAM_ID` if the
  key belongs to another team (the iPhone app's, when the Mac uses a free
  team). The build stops with an error if the file named is missing or isn't
  a key.
* Without that line the Mac app builds and runs as before but sends no
  notifications, and the Notifications section is hidden. The iPhone's widget
  and Live Activity still show a shell that needs you.
* The key is now inside `Passthrough.app`: don't give a built app to anyone
  else; let them build their own with their own key.
* **iPad support: update the iPhone, the iPad and the Mac together.** The
  iPhone now links an iPad over its Personal Hotspot only, and the iPad learns
  which network is the hotspot from those links, so an older build on either
  side gets this wrong (an older iPhone also links over a Wi-Fi network both
  share). There are no compatibility shims. The Mac needs the new build too,
  for an iPad on the cable, for `internetFrom` (which iPhone the iPad uses) and
  for `goodbye`. Both iOS targets now build for iPad (`TARGETED_DEVICE_FAMILY`
  1,2); run `xcodegen generate` before building. The iPad's tunnel extension
  links `Vendor/HevSocks5Tunnel/HevSocks5Tunnel.xcframework`, which is checked
  in (`scripts/build-hev.sh` rebuilds it with the macOS library).
* **Screen view: update the Mac and the phone together.** The screen
  stream's `hello` changed (it now says what to show) and the Mac no longer
  draws the pointer into the picture: an older phone on a new Mac would show
  no pointer, and an older Mac doesn't understand the new `hello`. No
  compatibility shims.

#### Setting up the push key, step by step (for a person or for Claude)

If Claude (or another coding agent) is doing the rebuild, it should follow
these steps as written and check each one before building.

1. **Find the key.** Look for an `AuthKey_<Key ID>.p8` file: first in `Config/`,
   then with `mdfind -name AuthKey_ | grep '\.p8$'`. Use only the file name to
   decide; never print the file's contents.
2. **No key anywhere?** Only the account owner can make one: at
   developer.apple.com › *Certificates, IDs & Profiles* › *Keys*, add a key with
   *Apple Push Notifications service (APNs)* and download it. Apple lets you
   download it only once, so keep a copy somewhere safe (a password manager).
   An agent should ask the person for the file, not make the key itself. If
   they don't want notifications, skip to step 5: the build works without them.
3. **Put it in place:** move it into `Config/` (for example
   `mv ~/Downloads/AuthKey_ABC123DEFG.p8 Config/`) and run
   `git check-ignore Config/AuthKey_ABC123DEFG.p8`, which must print the path
   (it is ignored, so it can't be committed).
4. **Name it in the config:** add
   `PASSTHROUGH_PUSH_KEY_FILE = Config/AuthKey_ABC123DEFG.p8` to
   `Config/Signing.xcconfig` (add `PASSTHROUGH_PUSH_KEY_ID = ABC123DEFG` too if
   the file isn't named `AuthKey_<Key ID>.p8`). `DEVELOPMENT_TEAM` there must be
   the team the key belongs to, or set `PASSTHROUGH_PUSH_TEAM_ID` to the
   key's team (it must be the team that signs the iPhone app).
5. **Regenerate and build:** `xcodegen generate`, then build the Mac app
   (Release for /Applications, as in docs/GUIDE.md › Setup). The build log
   says either `Bundled push key <Key ID> for team <Team ID>.` or
   `No PASSTHROUGH_PUSH_KEY_FILE: building without phone notifications.`
6. **Check the built app:**
   `ls build/Build/Products/Release/Passthrough.app/Contents/Resources | grep AuthKey_`
   shows the key when notifications are on.
7. **After installing:** open *Settings › Remote Shell › Notifications* on the
   Mac (it reads *Ready*), turn on *Settings › Notifications › Tell me when a
   shell needs me* on the iPhone, and click *Send Test Notification*.

### Added

* **One Mac can see and control another's screen.** On the iPhone, open a
  Mac and tap *Share screen with a Mac*, pick your other Mac and confirm with
  Face ID. That Mac gets a screen-only pass and opens the screen from
  Passthrough's menu (*Other Macs*), on the local network or from anywhere
  over iroh, without the phone. The pass can't open shells or change
  anything else. Remove it in *Settings › Remote Shell* on the shared Mac (on
  the other Mac, removing it only forgets that Mac's copy). It stops working
  when the phone that shared it loses access or its Screen permission there.
  The other Mac also holds the shared Mac's relay token, if it has one. Both
  Macs and the iPhone need this build. Not on Android yet.

* Screen view, far away: the Mac now keeps as many frames in flight as fit in
  the round trip (it was two, so a phone 100 ms away got about 20 frames a
  second) and lowers its bitrate when frames start arriving late, then raises
  it again.
* Screen view: *Picture* in the desktops menu: *Sharp* (crisp text, 60 fps,
  as before), *Smooth* (crisp text at 120 fps on ProMotion iPhones and
  iPads) or *Fast* (120 fps, slightly softer text, keeps moving on a slow
  link). And with *Fit to this iPhone/iPad*, *Text size*: *Larger text*,
  *Default* or *More space*.
* Screen view: *Use Here*. When the Mac's screen is open on another device
  too, a banner says so; *Use Here* ends the view there (it shows "open on
  …" with its own *Use Here* to take it back) and gives this device the
  display made for it.
* Screen view: pinch and rotate reach the Mac app under your fingers (Maps,
  Photos, Preview, Safari's zoom), as from a Mac trackpad. With *Fit to this
  iPhone/iPad* they always do, and a three-finger double-tap zooms the view;
  on the Mac's own display pinch still zooms the view unless *Pinch and
  rotate go to …* is on. It uses an undocumented macOS event (as Mac Mouse
  Fix does), checked on macOS 27.
* Screen view: momentum scrolling. A two-finger scroll that ends moving
  carries on and slows like a Mac trackpad's; touching the screen stops it.
* Screen view: a spinner or streaming text alone, with no one touching the
  phone, goes at 15 frames a second, back to full speed at the first touch.
* Screen view: HEVC instead of H.264 where the phone decodes it (every
  supported iPhone and iPad): a little sharper for the same bits.
* Screen view, slow links: when the bitrate gets too low for the picture's
  size, the Mac sends a smaller picture (¾, then ½ each side) rather than a
  blurry full-size one, and the full size again once the link allows it.
  Keyframes, which are big whatever the bitrate, shrink with it.
* Screen view: the desktops menu says how you're connected (your network,
  directly, or through a relay), and the view says so once if it stays on a
  relay, the likeliest reason for lag.
* Screen view: the phone draws the Mac's pointer itself, so it moves the
  moment your finger does instead of a round trip later.
* Screen view: *Screen shape › Fit to this iPhone/iPad* (in the desktops
  menu). The Mac makes a display in the device's shape and resolution, turns
  with it, and mirrors its own displays onto it while you view, so the
  desktop fills the screen at a readable size, clear of the Dynamic Island
  and the view's controls. The default is still the
  Mac's own display, as before. It uses macOS's private virtual-display API
  (as Sidecar and DeskPad do); if that fails the view says so and shows the
  Mac's own display.

* Shell status: sessions say what Claude Code is doing (working, needs you,
  done); the widget and Live Activity show a shell that needs you.
* Notifications: a Mac tells the iPhone when a shell needs it or finishes a
  long task, through Apple's push service, sealed end to end.
* A long session's replay restores its terminal modes, so full-screen programs
  reattach on their own screen.
* iPad: **Internet through iPhone**. On the iPhone's Personal Hotspot, the
  iPad's traffic leaves from the iPhone's own network stack through
  Passthrough, not as hotspot data. Its tunnel holds every route and runs
  tun2socks to the link the iPhone dials in on; with the link down the iPad is
  offline on purpose, with **Use hotspot data instead**. It runs only on the
  iPhone's hotspot (known by its DNS server, or learned from a first working
  link), and steps aside within seconds anywhere else.
* iPad: pairs with its iPhone by a QR code (one-time, five minutes). On the
  iPhone: *iPhone* tab › *Paired devices* › **Pair › Scan an iPad's code**,
  then Face ID.
* iPad as the Mac's remote: it pairs over the cable and gets the shell and
  screen like a phone, but the Mac never routes through it. With an iPhone
  attached too, the Mac's panel offers **Pair iPad** (the Mac talks to one
  device at a time and the iPhone comes first). The Mac's panel says which
  iPhone the iPad gets its internet from, and *Phones with access* shows it
  as an iPad, under the name it goes by now. On iPad, Apple Pencil clicks and
  drags where it touches on the Mac's screen, and double-tap (or squeeze)
  right-clicks. On iPad the screen view
  fills the display under a floating bar, and a trackpad, mouse or hardware
  keyboard goes straight to the Mac.
* iPhone: *Sharing with* lists the Macs and iPads using it right now, and
  *Paired devices* lists both.

### Changed

* *This iPhone* (*This iPad* on an iPad) is its own tab, *iPhone* (*iPad*),
  replacing the row on the Mac tab.
* Turning Passthrough off on the iPhone tells its Macs and iPads first
  (`goodbye`), so an iPad says so at once; a link that only drops is still held
  two minutes for a resume.
* iPhone: opening the app no longer resizes a shell in use in a terminal window
  on the Mac.
* The pairing code's countdown ticks (it could stay at 5:00), and the power
  button's ring and the status dots no longer slide left and right; they
  hold still under Reduce Motion (the spinner still turns).
