# tinify-compress.sh

A production-ready Bash script to **recursively compress images** using the
**Tinify (TinyPNG / TinyJPG) API**, with **change detection, per-directory logs,
and safe incremental re-runs**.

Designed for **Debian/Ubuntu**, using a **local Python virtual environment**
to avoid system Python issues (PEP 668).

---

## Features

### Core
- Recursively crawls a directory tree
- Compresses images **in place** (safe temp-file swap)
- Supports: `png`, `jpg`, `jpeg`, `webp`, `avif`
- Optional backups (`.bak`)
- Dry-run mode
- One-command setup (`--setup`)
- Explicit exit codes (CI-friendly)

### Change Tracking & Logging
- Per-directory log file: `.tinify-compress.log`
- Stores **SHA-256 hash + filename**
- Skips unchanged files on subsequent runs
- Automatically recompresses changed files
- Automatically removes deleted files from logs
- Handles filenames with spaces safely

### Log Control Modes
- Disable logging entirely
- Rebuild logs from scratch
- Rebuild logs **without compressing**

---

## Requirements

- Debian or Ubuntu
- Tinify API key (free tier available)  
  https://tinypng.com/developers

---

## Installation

```bash
chmod +x tinify-compress.sh
```

Edit the script and set your API key:

```bash
readonly TINIFY_API_KEY="YOUR_API_KEY_HERE"
```

⚠️ Never commit your API key to a public repository.

---

## Setup

```bash
./tinify-compress.sh --setup
```

Creates a local virtual environment `.venv-tinify` and installs dependencies.

---

## Usage

### Incremental compression
```bash
./tinify-compress.sh -d ./assets
```

### Keep backups
```bash
./tinify-compress.sh -d ./assets -b
```

### Dry run
```bash
./tinify-compress.sh -d ./assets -n
```

---

## Logging & Change Detection

Each directory containing images gets its own hidden log file:

```
.tinify-compress.log
```

Log format:
```
<sha256_hash><TAB><relative_filename>
```

---

## Logging Flags

Disable logging:
```bash
./tinify-compress.sh -d ./assets --no-log
```

Rebuild logs and recompress:
```bash
./tinify-compress.sh -d ./assets --rebuild-log
```

Rebuild logs only (no compression):
```bash
./tinify-compress.sh -d ./assets --rebuild-log-only
```

---

## Exit Codes

| Code | Meaning |
|----:|--------|
| 0 | Success |
| 1 | General error |
| 2 | Invalid arguments |
| 3 | Missing dependency |
| 4 | Runtime error |

---

## License

MIT
