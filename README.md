# Visualizer (iOS)

Native iOS version of the lyricbot visualizer: black screen, album cover in a circle, a ring of bars
that rises with the beat, floating dots. No text, no accounts, **no automatic posting** — you pick a song,
watch the live preview, tap *Make video*, then save it to Photos or share it yourself.

Controls: line thickness, line length (both default to the bigger look), dots on/off, video length (15s / 30s / 60s / full), cover photo.

## Get the unsigned IPA from GitHub
1. Create a new GitHub repo and upload everything in this zip (keep `.github/workflows/build-ipa.yml`).
2. Open the repo's **Actions** tab. The *Build unsigned IPA* workflow runs on every push (or press *Run workflow*).
3. When it finishes, open the run and download the artifact **LyricbotVisualizer-unsigned-ipa**
   (or push a tag like `v1.0` and the IPA is attached to a Release).

The IPA is **unsigned** — it won't install by itself. Sign/install it on your phone with AltStore, Sideloadly,
TrollStore, or your own certificate.

Needs iOS 16+. Built with XcodeGen (`project.yml`) on a macOS runner; there is no checked-in .xcodeproj.
