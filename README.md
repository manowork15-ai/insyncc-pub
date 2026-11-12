# Video Diary for Mac

A native macOS app for keeping a video diary. Open it, press **Space**, talk, press **Space** again.
Each entry gets a title, mood, tags and notes, and is uploaded to a Google Drive folder you choose,
filed by year and month.

```
My Drive › Video Diary › 2026 › 11 November › 2026-11-12 Thu 21.30 - Thursday Evening.mov
```

## The workflow

1. **Open the app.** It opens on the camera, ready to record. The camera turns on only while
   this screen is showing. If you've already recorded today, it opens on your library instead.
2. **Record.** Click the red button or press **Space**. A 3-2-1 countdown runs first
   (press Space to skip it, Esc to cancel). A prompt such as *"What surprised you today?"*
   helps when you don't know what to say, and **⇄** shuffles it. A mic meter shows the sound is coming through.
3. **Review and label.** Watch the take back, then add a title (or keep the suggested
   *"Thursday Evening"*), tap a mood emoji, add tags (your most-used tags are one click away)
   and notes. Press **⌘↩** to save or **Retake** to try again.
4. **It uploads in the background.** You go straight to your library, and the new entry shows an
   upload ring. Uploads resume after you quit, the Mac sleeps or the network drops. Closing the
   window doesn't stop an upload.
5. **Browse and rewatch.** Entries are grouped by month, with a sidebar timeline, search
   (titles, notes, `#tags`, dates), a mood filter, streak and total-time stats, and an
   **On this day** row for past years. Open an entry to play it (it downloads from Drive if it
   isn't on this Mac), edit its details (changes sync to Drive), move between entries with
   **⌘↑ / ⌘↓**, open it in Drive or delete it (it goes to the Drive trash).

Other features: a daily reminder notification, camera and mic selection (including iPhone
Continuity Camera), smaller HEVC files, a mirrored preview, and **Free Up Space** to delete
local copies of entries already in Drive.

### Keyboard shortcuts

| | |
|---|---|
| Space | Start or stop recording, or skip the countdown |
| Esc | Cancel the countdown |
| ⌘↩ | Save entry |
| ⌘N | New entry |
| ⌘L | All entries |
| ⌘R | Refresh from Google Drive |
| ⌘↑ / ⌘↓ | Newer / older entry |
| ⌘S | Save edits to an entry |
| ⌘, | Settings |

## How entries are stored in Drive

- **Files:** `<your folder>/<YYYY>/<MM Month>/<YYYY-MM-DD Ddd HH.mm> - <Title>.mov`.
  The year and month folders are created automatically.
- **Metadata:** title, mood, tags, duration and recording time are saved as the file's private
  `appProperties`. Your notes go in the file's Drive **description**, so you can read them in Drive too.
- **Drive is the source of truth.** A new Mac with the app signed in rebuilds the whole library
  from Drive. If you delete an entry in Drive, it disappears from the app. Edits you make in the
  app are written back to Drive.
- **On this Mac:** `~/Library/Application Support/VideoDiary` holds the recordings, thumbnails
  and library index. `~/Library/Caches/VideoDiary` holds videos downloaded for playback.

## Setup

### 1. Create a Google OAuth client (one-time, about 5 minutes)

The app talks to Google Drive through your own Google Cloud project, so your videos never pass
through a third-party server.

1. Go to <https://console.cloud.google.com/>, create a project, then open
   **APIs & Services › Library** and enable the **Google Drive API**.
2. Open **Google Auth Platform › Branding / Audience** and set up the consent screen with user
   type **External**.
   - Either add your Google account under **Test users**,
   - or click **Publish app**. Google shows an "unverified app" warning that you click through
     once. This is recommended, because Google expires sign-ins for apps in *Testing* status
     after 7 days.
3. Open **Google Auth Platform › Clients › Create client**, choose application type
   **Desktop app**, and copy the **Client ID** and **Client secret**.

The app asks for the full `drive` scope so you can choose any existing folder in your Drive as
the diary location.

### 2. Build the app

You need macOS 14 (Sonoma) or later and Xcode 15 or later (or the Xcode command-line tools).

```bash
./scripts/build-app.sh
open "build/Video Diary.app"
```

To skip typing the client ID in the app, bake it into the build:

```bash
GOOGLE_CLIENT_ID="1234-abc.apps.googleusercontent.com" GOOGLE_CLIENT_SECRET="GOCSPX-..." ./scripts/build-app.sh
```

To install, drag `build/Video Diary.app` into `/Applications`.

**Prebuilt:** every push builds a universal app in GitHub Actions. Download `VideoDiary-macOS`
from the run's artifacts. The app is ad-hoc signed, so the first time you open it,
right-click it and choose **Open**.

### 3. First launch

Onboarding takes you through these steps: **Welcome → Connect Google Drive → Choose folder**
(one click creates `My Drive/Video Diary`, or you can browse to any folder) **→ Camera check**,
with an optional evening reminder. You can skip Google and record locally first. Entries upload
once you connect in **Settings › Google Drive**.

## Project layout

```
Sources/VideoDiary/
  App/        VideoDiaryApp (scenes, menus), AppModel (navigation, record → save flow, reminders)
  Auth/       GoogleAuth (OAuth 2 + PKCE, loopback redirect), LoopbackServer, Keychain
  Capture/    CameraController (AVCaptureSession, devices, mic meter, recording), CameraPreview
  Drive/      DriveClient (Drive v3 REST, resumable chunked upload), DiaryLayout (naming, folders,
              metadata), SyncEngine (upload queue, retries, offline handling, library refresh)
  Library/    Models, EntryStore (local index, merging with Drive, streaks), Thumbnails
  Views/      Onboarding, Record and Review, Library, Entry detail, Folder picker, Settings, components
scripts/      build-app.sh (bundle, icon, sign), make-icon.swift
```

Notes:

- Tokens and client credentials are stored in the macOS Keychain. The OAuth redirect goes to
  `127.0.0.1` on a random port, which is Google's recommended flow for desktop apps.
- If you rebuild with ad-hoc signing, macOS may ask once to allow Keychain access, and may ask
  again for camera permission, because the app's signature changed. Sign with your own identity
  (`SIGN_IDENTITY="Apple Development: …"`) to avoid this.
- Recordings use 1080p when the camera supports it and are written with 5-second movie fragments,
  so a crash mid-recording still leaves a playable file.
