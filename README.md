# koreader2zotero

A KOReader plugin that syncs reading highlights to your Zotero library.

## Purpose

KOReader is a great e-reader for books. Zotero is a great reference manager for academic papers. This plugin bridges them: highlights you make while reading in KOReader are pushed to Zotero as a formatted note attached to the book's item, so your annotations live alongside your papers in one place.

## How it works

1. When you close a book (or trigger sync manually), the plugin reads KOReader's annotation sidecar for that file.
2. It searches your Zotero library for a matching book item by title. If none is found, it creates one with whatever metadata the ebook provides (title, author, ISBN).
3. New highlights are appended to a child note on that Zotero item, grouped by chapter and formatted as HTML blockquotes with page numbers and your inline comments.
4. The plugin tracks which highlights have already been synced so re-syncing is safe — it only appends what's new.

Highlights are stored as a Zotero **note item** rather than native PDF annotations, because KOReader doesn't produce the coordinate data native annotations require. Notes work for any book format and are fully searchable in Zotero.

## Architecture

```
zotero.koplugin/
├── main.lua   — plugin lifecycle, KOReader menu integration, event hooks
├── api.lua    — thin Zotero REST API v3 client (HTTPS, JSON)
└── sync.lua   — annotation reading, book matching, HTML rendering, state tracking
```

- **`main.lua`** registers a "Zotero" submenu under Tools, hooks `onCloseDocument` for auto-sync, and owns settings persistence via `G_reader_settings`.
- **`api.lua`** wraps the Zotero API endpoints needed: item search, item create, note create, note patch. All requests go to `api.zotero.org` over HTTPS using KOReader's bundled LuaSec.
- **`sync.lua`** reads from KOReader's doc settings sidecar (`.sdr/`), filters to unsynced annotations, renders HTML grouped by chapter, and calls the API. Per-book state (Zotero item key, note key, synced datetimes) is persisted in KOReader settings.

> **Note:** Only the current KOReader annotations format is supported. Books last opened with KOReader older than ~2021 that use the legacy highlight format will be skipped.

## Requirements

- KOReader with network access
- A Zotero account with an API key that has **read/write** access to your library
- Your Zotero **user ID** (the numeric ID, not your username)

Both are found at [zotero.org/settings/keys](https://www.zotero.org/settings/keys).

## Installation

Copy the plugin directory into KOReader's plugins folder and restart KOReader:

```
# Android (common path)
adb push zotero.koplugin /sdcard/koreader/plugins/

# Kobo / Kindle (via SSH or USB)
cp -r zotero.koplugin /mnt/onboard/.adds/koreader/plugins/

# Linux desktop
cp -r zotero.koplugin ~/.config/koreader/plugins/
```

The exact path depends on your device and KOReader installation method. A good reference is the KOReader wiki page on [plugin installation](https://github.com/koreader/koreader/wiki/User-plugins).

## Setup

1. Open KOReader and go to **Tools → Zotero → Settings**
2. Enter your Zotero API key, then your numeric user ID
3. Auto-sync on document close is enabled by default

## Usage

| Action | How |
|---|---|
| Sync when you finish reading | Just close the book — auto-sync fires automatically |
| Sync while reading | Tools → Zotero → Sync current book |
| Sync your whole library | Tools → Zotero → Sync all books |
| Disable auto-sync | Tools → Zotero → Auto-sync on close (toggle) |

## Limitations

- Book matching is title-based. If you have multiple editions of a book in Zotero, the plugin picks the first exact title match. You can clean up duplicates in Zotero after the fact.
- The legacy KOReader highlight format (pre-annotations API) is not supported.
- Zotero group libraries are not currently supported — only personal libraries.
