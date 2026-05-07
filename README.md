# koreader2zotero

A KOReader plugin that syncs reading highlights to your Zotero library.

## Purpose

KOReader is a great e-reader for books. Zotero is a great reference manager for academic papers. This plugin bridges them: highlights you make while reading in KOReader are pushed to Zotero as a formatted note attached to the book's item, so your annotations live alongside your papers in one place.

## How it works

1. When you close a book (or trigger sync manually), the plugin reads KOReader's annotation sidecar for that file.
2. It searches your Zotero library for a matching book item by title. If none is found, it creates one. If a Calibre server is configured, it enriches the new item with ISBN, publisher, and publication date from Calibre before creating it.
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
- **`sync.lua`** reads from KOReader's doc settings sidecar (`.sdr/`), filters to unsynced annotations, renders HTML grouped by chapter, and calls the API. Per-book state (Zotero item key, note key, synced datetimes) is persisted in KOReader settings. Optionally queries a Calibre content server for richer book metadata.

> **Note:** Only the current KOReader annotations format is supported. Books last opened with KOReader older than ~2021 that use the legacy highlight format will be skipped.

## Requirements

- KOReader with network access
- A Zotero account with an API key that has **read/write** access to your library
- Your Zotero **user ID** (the numeric ID, not your username)

Both are found at [zotero.org/settings/keys](https://www.zotero.org/settings/keys).

**Optional:** A running Calibre content server for ISBN and publisher metadata enrichment.

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
3. Optionally enter your Calibre server URL (e.g. `https://192.168.1.100:8080`) and library ID if your library is not the default `Calibre Library` (e.g. `library`)
4. Auto-sync on document close is enabled by default

### Finding your Calibre library ID

The library ID is the folder name of your Calibre library, lowercased. If you're unsure, you can verify it works by hitting this URL in a browser:

```
https://YOUR-CALIBRE-HOST/ajax/search/YOUR-LIBRARY-ID?query=*&num=1
```

A JSON response with a non-zero `num_books_without_search` confirms both the URL and library ID are correct.

## Usage

| Action | How |
|---|---|
| Sync when you finish reading | Just close the book — auto-sync fires automatically |
| Sync while reading | Tools → Zotero → Sync current book |
| Sync your whole library | Tools → Zotero → Sync all books |
| Backfill ISBN/publisher on existing items | Tools → Zotero → Backfill metadata from Calibre |
| Re-push a book (e.g. after deleting it in Zotero) | Tools → Zotero → Clear cache for current book, then sync |
| Clear all cached mappings | Tools → Zotero → Clear all caches |
| Disable auto-sync | Tools → Zotero → Auto-sync on close (toggle) |
| Diagnose connection issues | Tools → Zotero → Test Zotero connection / Test Calibre connection |
| Diagnose book search | Open the book, then Tools → Zotero → Test Calibre book search |

## Limitations

- Book matching is title-based. If you have multiple editions of a book in Zotero, the plugin picks the first exact title match. You can clean up duplicates in Zotero after the fact.
- The legacy KOReader highlight format (pre-annotations API) is not supported.
- Zotero group libraries are not currently supported — only personal libraries.
- Zotero WebDAV file sync is unaffected — the plugin only writes metadata (notes and book items) via the Zotero API, which works the same regardless of your file sync method.
