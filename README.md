# tinify-compress.sh

A robust Bash script to **recursively compress images** using the
**Tinify (TinyPNG/TinyJPG) API**.\
Designed for **Debian/Ubuntu**, with safe defaults, clear logging, and
no system Python pollution.

The script uses a **local Python virtual environment** to avoid Debian's
*externally-managed-environment (PEP 668)* restrictions.

------------------------------------------------------------------------

## Features

-   Recursively crawls a directory
-   Compresses images in place (safe temp-file swap)
-   Supports: png, jpg, jpeg, webp, avif
-   Optional backups (`.bak`)
-   Dry-run mode
-   One-command setup on Debian/Ubuntu
-   Explicit error codes (CI-friendly)
-   No global Python or npm installs required

------------------------------------------------------------------------

## Requirements

-   Debian or Ubuntu
-   Tinify API key (free tier available at
    https://tinypng.com/developers)

------------------------------------------------------------------------

## Installation

``` bash
chmod +x tinify-compress.sh
```

Edit the script and set:

``` bash
readonly TINIFY_API_KEY="YOUR_API_KEY_HERE"
```

Do not commit your API key to a public repository.

------------------------------------------------------------------------

## Setup

``` bash
./tinify-compress.sh --setup
```

Creates a local virtual environment `.venv-tinify` and installs
dependencies.

------------------------------------------------------------------------

## Usage

``` bash
./tinify-compress.sh -d ./assets
./tinify-compress.sh -d ./assets -b
./tinify-compress.sh -d ./assets -n
```

------------------------------------------------------------------------

## Exit Codes

    Code Meaning
  ------ --------------------
       0 Success
       1 General error
       2 Invalid arguments
       3 Missing dependency
       4 Runtime error

------------------------------------------------------------------------

## License

MIT
