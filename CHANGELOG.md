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

* Shell status: sessions say what Claude Code is doing (working, needs you,
  done); the widget and Live Activity show a shell that needs you.
* Notifications: a Mac tells the iPhone when a shell needs it or finishes a
  long task, through Apple's push service, sealed end to end.
* A long session's replay restores its terminal modes, so full-screen programs
  reattach on their own screen.
