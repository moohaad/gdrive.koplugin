# Google Drive Plugin for KOReader

Two-way sync for highlights, bookmarks, reading progress, and vocabulary across devices via Google Drive.

## Features

- **3-way merge sync** — annotations are merged intelligently, not overwritten. Edits on multiple devices are combined without data loss (same approach as [AnnotationSync](https://github.com/nicholasgasior/koreader-plugin-annotation-sync))
- **Vocabulary sync** — syncs `vocabulary_builder.sqlite3` (timestamp-based, newer wins)
- **Auto-sync** — automatically syncs on book open and close (configurable)
- **Browse & download** — browse your Google Drive and download files to your device
- **Per-book sync** — each book's annotations are identified by content hash, so renaming or moving files doesn't break sync

## Installation

Copy the `gdrive.koplugin` folder into your KOReader plugins directory:

```
<koreader>/plugins/gdrive.koplugin/
```

On Kindle, this is typically `/mnt/us/koreader/plugins/`. On Kobo, `/mnt/onboard/.adds/koreader/plugins/`.

## Setup

### 1. Create a Google Cloud OAuth2 Client

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Create a new project (or use an existing one)
3. Enable the **Google Drive API**
4. Go to **Credentials** → **Create Credentials** → **OAuth client ID**
5. Application type: **Web application**
6. Add `https://developers.google.com/oauthplayground` as an authorized redirect URI
7. Download the JSON credentials file

### 2. Get a Refresh Token

1. Go to [OAuth 2.0 Playground](https://developers.google.com/oauthplayground/)
2. Click the gear icon (⚙️) → check **Use your own OAuth credentials**
3. Enter your Client ID and Client Secret
4. In Step 1, select **Drive API v3** → `https://www.googleapis.com/auth/drive`
5. Authorize and exchange the authorization code for tokens
6. Copy the **refresh token**

### 3. Configure the Plugin

Place the credential files in KOReader's data directory under `gdrive/`:

```
<koreader-data>/gdrive/client_id.json
<koreader-data>/gdrive/refresh_token.txt
```

The data directory is typically the same as the KOReader directory (e.g., `/mnt/us/koreader/` on Kindle).

Alternatively, place them in the plugin directory (`gdrive.koplugin/`). The plugin checks the data directory first, then falls back to the plugin directory.

- `client_id.json` — the downloaded OAuth credentials JSON from Google Cloud Console
- `refresh_token.txt` — a plain text file containing only the refresh token

Then in KOReader: **Tools → Google Drive → Settings → Load Client ID (JSON)** and **Load Refresh Token (TXT)**.

## Usage

- **Tools → Google Drive → Sync** — manually sync the current book's annotations
- **Tools → Google Drive → Sync Vocabulary** — manually sync the vocabulary database
- **Tools → Google Drive → Browse** — browse and download files from Google Drive
- **Settings → Auto-sync on open/close** — toggle automatic sync when opening/closing a book
- **Settings → Auto-sync vocabulary** — toggle automatic vocabulary sync
- **Settings → Set Download Dir** — choose where downloaded files are saved

## How Sync Works

The plugin uses a 3-way merge protocol:

1. **Local** — current annotations in memory
2. **Cached** — snapshot from the last successful sync (`.sync` file)
3. **Remote** — annotations downloaded from Google Drive

On each sync, annotations from all three sources are compared. New annotations from either side are added, and conflicts (same position edited on both sides) are resolved by keeping the most recent edit. Deleted annotations (present in cache but missing from one side) are properly removed.

All sync data is stored in a `KOReader_Sync/annotations/` folder on Google Drive, with each book identified by a partial MD5 hash of its content.

## Files

```
gdrive.koplugin/
├── _meta.lua          # Plugin metadata
├── main.lua           # Main plugin logic and UI
├── annotations.lua    # Annotation merge helpers
├── gdrive_sync.lua    # 3-way sync protocol (download/merge/upload)
├── network.lua        # Google Drive API wrapper
└── utils.lua          # JSON utility
```

## License

MIT
