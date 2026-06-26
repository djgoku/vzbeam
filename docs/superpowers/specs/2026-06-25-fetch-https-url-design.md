# `vzbeam fetch https://…ipsw` — design

## Goal

Add a third `fetch` spec kind — an `https://` URL — alongside the existing
`latest` and local `PATH`. A user can run:

```
vzbeam fetch https://updates.cdn-apple.com/…/UniversalMac_…_Restore.ipsw
```

and have the image downloaded, identified, and cached exactly like `latest`.

## Scope / non-goals

- Pure Elixir in `VzBeam.Cache`. **No Swift sidecar change.**
- `https://` only. `http://` and other schemes are rejected (no plaintext
  download of a ~15 GB image; matches the user's `fetch https://…` intent).
- No `.ipsw` extension requirement on the URL — the content is validated by
  `image-info`, not the filename.

## Why no Swift change

The crux is **ordering**. Today `VzBeam.Cache.ensure/2`:

1. calls `Sidecar.image_info(spec)` *first* to learn `build`/`version`,
2. checks the cache by `build`,
3. then downloads (`latest`, via `curl`) or copies (local `PATH`).

The Swift `image-info` sidecar only understands `latest` and local file paths
(`VZMacOSRestoreImage.fetchLatestSupported` / `.load(from: fileURL)`). It cannot
read a *remote* IPSW's metadata. So for a URL we must get the bytes local before
we can identify them: **download-first, then `image-info` the downloaded file.**

`image-info` on a local file is already exercised by the existing path-copy
flow, so the URL branch rides existing, working machinery.

## New flow

`ensure/2` gains a URL branch. Classification: a spec matching `https://…` takes
the URL branch; everything else uses the existing flow unchanged.

URL branch (`ensure_url`):

1. **Dedup by URL string.** Scan index entries for one whose stored `url` equals
   this URL exactly. If found and its `{build}.ipsw` file exists →
   `{:ok, :cached, entry}`, **no download**.
2. **Download** to a pending temp file ending in `.ipsw`, via the existing
   `curl -fL` download helper. The `.ipsw` extension is kept so the loader
   cannot object to the name (see Verification).
3. **Identify.** `image_info(pending_path)` → `{version, build, url, source}`.
   - `source` is set to `"url"`.
   - The stored `url` is the **original request URL** (not Apple's CDN redirect
     target), so step-1 dedup matches on a subsequent fetch.
   - `validate_build/1` runs as today (rejects empty / `.` / `..` / path
     separators).
4. **Place + index.** If that `build` is already cached, or `{build}.ipsw`
   already exists on disk → discard the pending file, return `:cached` /
   `:reconciled`. Otherwise `rename` pending → `{build}.ipsw` and write the
   index entry (`bytes`, `fetchedAt`, etc.).
5. **Failure cleanup.** Any error removes the pending file (the existing
   `acquire/4` already does this on its error path; the URL branch follows the
   same pattern).

## Error handling

No new user-facing message types. `fetch.ex` already renders:

- success → `fetched <version> (<build>)` or `already cached <version> (<build>)`
- `{:error, reason}` → `fetch failed: <inspect reason>`

A download that is not a valid restore image surfaces as `image-info` failing →
`fetch failed: …`. A malformed/unsupported URL-looking spec is rejected the same
way.

## Components touched

- `lib/vzbeam/cache.ex` — add URL classification + `ensure_url` branch +
  URL-string dedup lookup. `acquire/4`, `put_index/2`, `size_sane/1`,
  `validate_build/1`, the `curl` `download/2` helper are reused.
- `lib/vzbeam/commands/fetch.ex` — **no change** (verb output already covers
  `:fetched` / `:cached` / `:reconciled`).
- Swift — **no change**.

## Testing

`VzBeam.Cache.ensure/2` is dependency-injected
(`deps.image_info`, `deps.download`, `deps.copy`). New tests drive the URL
branch with stubbed deps:

1. **Fresh download** — URL not in index → `:fetched`; `download` stub called,
   `image_info` called on the pending path, index entry written with
   `source: "url"` and the original URL.
2. **Repeat by URL** — same URL already indexed with file present → `:cached`,
   and the `download` stub is asserted **not** called.
3. **Download-then-build-already-present** — URL differs but resolves to an
   already-cached build → pending file discarded, `:cached`/`:reconciled`.
4. **`image-info` failure** — download succeeds but identify fails → error
   surfaced, pending file cleaned up (not left on disk).
5. **Scheme rejection** — `http://…` (and other non-`https` URL-looking specs)
   → error, no download attempted.

`fetch.ex` verb output needs no new tests.

## Verification (implementation-time, not assumed)

Confirm `VZMacOSRestoreImage.load(from:)` reads the downloaded file regardless of
a `.pending`-style name — hence the temp file is given an `.ipsw` extension.
Verify by running `image-info` against a real downloaded file on Apple Silicon
hardware (this build host cannot boot guests, but `image-info` reads metadata
only and is already exercised by the path-copy flow).
