# Freespan

Freespan is a free macOS app that shows what is using space on your Mac, explains it in plain words, and helps you clean it up safely.

![Freespan overview](docs/screenshot-overview.png)

## Features

- **Fast scan of your home folder or the whole disk.** Sizes count allocated space and skip hard-link and clone duplicates. Results are cached, so the app opens with your last scan.
- **Built-in rules for 80+ common space users**: Xcode DerivedData, device support files and simulators, package manager caches (npm, Homebrew, CocoaPods, pip, Cargo, Gradle and others), `node_modules`, Docker disk images, browser and app caches, local AI models, old downloads and installers, iPhone backups, and large old files.
- **Every item gets a label**: *Safe to remove* (it comes back on its own), *Check first*, or *Keep*. Things your Mac or your apps need are never suggested.
- **Names before paths.** Items no rule covers are identified locally from app IDs, a table of known locations, Spotlight metadata and file types, so you see "Slack's cache" rather than a bare folder name.
- **Easy and Advanced modes.** Easy mode shows one "Clean Up Safely" button and a short "Check first" list. Advanced mode shows every group, label and source, plus whole-disk scans, a size threshold and excluded folders.
- **Space Map**: a ring chart of your folders that you can drill into.
- **Apps**: lists installed apps with the data each one keeps elsewhere. Clear an app's regenerable extras, uninstall an app together with its data, or find data left behind by apps you already removed.
- **In-use checks.** Items a running app has open are skipped, and Freespan offers to quit the app (only apps you can quit, never background services). Folders that are only partly in use are cleaned partly.
- **Deep Clean Plan**: a ranked cleanup plan built from the rules, with no AI involved.
- **Ask**: an optional panel for questions about your disk.
- **History with Undo** for every item Freespan has moved.
- Quick Look and Reveal in Finder for any item.

![Clean up safely](docs/screenshot-cleanup.png)
![Apps](docs/screenshot-apps.png)

## Safety model

- **Trash only.** Freespan never deletes anything permanently. Cleanup uses the system's Move to Trash, and every move is written to an undo log (`~/Library/Application Support/Freespan/actions.json`), so you can put things back from History. You get the space back when you empty the Trash.
- **Only built-in rules can mark something Safe.** Labels from local identification or from any AI assistant are capped at *Check first*, and they are never included in "Clean Up Safely" or the Safe steps of the Deep Clean Plan.
- **Protected paths.** A fixed list of locations (your Keychain, Mail, Messages, Photos and Music libraries, iCloud Drive, SSH and cloud credentials, system folders, other users' folders and more) can never be moved, whatever a rule or assistant says.
- **AI is local-first.** By default the assistant is Apple's on-device model (Foundation Models), so nothing leaves your Mac. Claude is optional and off by default. You can turn it on in Settings with your Claude subscription (through the `claude` command-line tool) or an Anthropic API key, which is stored in your Keychain. Claude sees file names, sizes and dates, never file contents, and your home folder path is shortened to `~` before anything is sent. You can also turn the assistant off and use rules and local identification only.

## Requirements

- macOS 15 or later.
- The on-device assistant needs macOS 26 with Apple Intelligence turned on. Everything else works without it.
- Full Disk Access is recommended. Without it, macOS hides protected folders such as Desktop, Documents and Downloads from the scan. Freespan asks once on first launch.

## Install

Download the DMG from [mcconnelldigital.com/freespan](https://mcconnelldigital.com/freespan/), open it, and drag Freespan to Applications.

## Build from source

You need Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
git clone https://github.com/mcconnellj-Dev/freespan.git
cd freespan
xcodegen generate
open Freespan.xcodeproj
```

`project.yml` signs with McConnell Digital's development team. To build under your own account, change `DEVELOPMENT_TEAM` in `project.yml` (or pick your team in Xcode's Signing & Capabilities tab) and run `xcodegen generate` again. A stable signing identity matters here: macOS ties Full Disk Access to the app's signature, so an ad-hoc signed build has to be granted access again after every rebuild.

If the project lives in `~/Desktop` or `~/Documents`, build with a DerivedData path outside it, because Finder metadata in those folders can break code signing:

```sh
xcodebuild -project Freespan.xcodeproj -scheme Freespan -configuration Release \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/Freespan-release build
```

Run the core library's tests (scanner, rules, cleanup, assistants):

```sh
swift test --package-path FreespanKit
```

Scripts:

- `scripts/install.sh` builds a Release copy and installs it to `/Applications` (the old copy goes to the Trash).
- `scripts/make-dmg.sh` builds a Release copy and packages `build/Freespan-<version>.dmg`. With a Developer ID Application certificate and a `freespan-notary` notarytool profile in the keychain, it signs, notarizes and staples the DMG.

## Project layout

- `App/`: the SwiftUI app (views, app model, sample data for previews).
- `FreespanKit/`: a Swift package with the scanner, rule engine (`Rules/Rules.json`), protected paths, cleanup and undo log, app inventory, local identification and the assistant integrations.
- `project.yml`: the XcodeGen spec that produces `Freespan.xcodeproj`.

## License

MIT. See [LICENSE](LICENSE).
