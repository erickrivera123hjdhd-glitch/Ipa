# Visualizer (iOS)

Native iPad app (iPad only; landscape split layout) version of the lyricbot visualizer: black screen, album cover in a circle, a ring of bars
that rises with the beat, floating dots. No text, no accounts, **no automatic posting**.

Get the audio from: a pasted link (TikTok or a direct audio/video file link), any audio or video file
(the sound is taken from the video), or a video from Photos. Then: live preview, Small / Medium / Large line size
(plus fine-tune sliders), dots on/off, video length, cover photo, *Make video*, then Save to Photos or Share yourself.

Links: TikTok pages and direct file links work on the phone. YouTube/Instagram and similar hide their media,
so for those save the video and use the file or Photos button.

## Get the unsigned IPA from GitHub
1. Create a new GitHub repo and upload everything in this zip (keep `.github/workflows/build-ipa.yml`).
2. Open the repo's **Actions** tab. *Build unsigned IPA* runs on every push (or press *Run workflow*).
3. Download the artifact **LyricbotVisualizer-unsigned-ipa** from the finished run
   (or push a tag like `v1.0` and the IPA is attached to a Release).

The IPA is **unsigned**: install it with AltStore, Sideloadly, TrollStore, or your own certificate. iPadOS 16+. To also run on iPhone, change TARGETED_DEVICE_FAMILY to "1,2" in project.yml.
