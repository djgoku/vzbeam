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
- Out of scope for this change (see Known limitations): pre-download size/disk
  guard, concurrency locking, and crash-safe stale-pending cleanup. These are
  pre-existing properties of the cache (the `latest` download shares them) and
  are deferred as a separate hardening pass rather than scope-crept here.

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

`ensure/2` gains a URL branch. Classification: a spec is a URL when
`URI.parse/1` yields a `scheme` of `"https"`; everything else uses the existing
flow unchanged. (A spec whose scheme is `http`/other → rejected; a spec with no
scheme is treated as a local PATH as today.)

**Canonical key vs. dedup shortcut.** `build` (from `image-info` after download)
remains the single canonical cache key — exactly as for `latest` and `PATH`.
The URL-string scan is *only* a pre-download bandwidth shortcut. So two
differently-worded URLs that resolve to the same build still dedup correctly:
the first downloads and indexes the build; the second misses the URL scan,
downloads, then hits the build-level check in step 4 (`:cached`/`:reconciled`,
pending discarded). The URL scan just lets the *same* URL skip the download
entirely.

**URL normalization (for validation and as the dedup key).** Parse with
`URI.parse/1` and require:

- `scheme == "https"` and a non-empty `host` (else → error, no download).
- Reject `userinfo` (credentials in URL) → error.
- Strip the `fragment` before storing/comparing — fragments are never sent to
  the server, so `…/x.ipsw#a` and `…/x.ipsw#b` are the same download and must
  not be treated as distinct index entries.

The **normalized** URL (fragment stripped) is what gets stored as the entry's
`url` and what the dedup scan compares against. `.ipsw` path suffix is **not**
required.

URL branch (`ensure_url`):

1. **Dedup by normalized URL.** Scan index entries for one whose stored `url`
   equals the normalized URL exactly. If found and its `{build}.ipsw` file
   exists → `{:ok, :cached, entry}`, **no download**.
2. **Download** to a unique pending temp file in the cache dir named
   `url-fetch-<unique>.ipsw`, via the existing `curl -fL` download helper.
   - The `.ipsw` suffix satisfies any loader extension check (see Verification).
   - The `url-fetch-` prefix can never collide with a finished `{build}.ipsw`,
     since `validate_build/1` build tokens never start with it.
   - `acquire/4`'s build-derived pending name is unusable here (build is unknown
     pre-download), so the URL branch mints its own unique name instead.
3. **Identify.** `image_info(pending_path)` → `{version, build, url, source}`.
   - `source` is set to `"url"`.
   - The stored `url` is the **normalized original request URL** (not Apple's
     CDN redirect target), so step-1 dedup matches on a subsequent fetch.
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
  normalized-URL dedup lookup. `put_index/2`, `size_sane/1`, `validate_build/1`,
  the `curl` `download/2` helper are reused.
- `lib/vzbeam/commands/fetch.ex` — **usage string + `@moduledoc` updated** to
  `<latest|PATH|URL>` so help text matches the new spec kind. The verb output
  (`:fetched` / `:cached` / `:reconciled`) is unchanged.
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
6. **Fragment normalization** — `…/x.ipsw#a` and `…/x.ipsw#b` produce the same
   stored `url`; the second fetch dedups against the first (download stub not
   called the second time).
7. **Userinfo rejection** — `https://user:pass@host/x.ipsw` → error, no download.

`fetch.ex` verb output needs no new tests; the usage-string change is covered by
the existing `fetch` command tests (update the expected string).

## Verification (implementation-time, not assumed)

Confirm `VZMacOSRestoreImage.load(from:)` reads the downloaded file under its
temp name — hence the temp file is given an `.ipsw` extension
(`url-fetch-<unique>.ipsw`) rather than a bare/`.pending` name, so any loader
extension check is satisfied.
Verify by running `image-info` against a real downloaded file on Apple Silicon
hardware (this build host cannot boot guests, but `image-info` reads metadata
only and is already exercised by the path-copy flow).

## Known limitations (deferred)

These are pre-existing properties of the cache that the `latest` download flow
already shares. They are **not** fixed in this change — doing so only for the URL
branch would be inconsistent, and fixing them cache-wide is a separate hardening
pass. Recorded here so they are not mistaken for oversights:

- **No pre-download size/disk guard** (Codex finding 1). `image-info` carries no
  expected size, so `size_sane/1` only rejects an empty file *after* transfer.
  No `Content-Length`/free-space preflight. Same as `latest` today.
- **No concurrency lock** (Codex finding 4). Two concurrent fetches of the same
  URL can both download and race on the `put_index/2` read-modify-write. Same as
  two concurrent `fetch latest` today. (The unique pending names mean they won't
  clobber each other's *files*; the waste is duplicate bandwidth + a possible
  lost index update.)
- **Not crash-safe** (Codex finding 5). A hard kill mid-download leaves a
  `url-fetch-<unique>.ipsw` pending file with no startup cleanup pass. Same as
  `latest`'s `.pending` files today.
