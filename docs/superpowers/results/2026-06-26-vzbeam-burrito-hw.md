# Burrito single-file packaging — hardware validation (2026-06-26)

Plan: `docs/superpowers/plans/2026-06-26-vzbeam-burrito-packaging.md` (Task 6, HW-gated).
Branch: `burrito-packaging`. Validated on a real Apple-Silicon Mac (this build host can't boot VZ guests).

## What was packaged

`MIX_ENV=prod mix release` → `burrito_out/vzbeam_macos_silicon` (Burrito 1.5.0, single target
`macos_silicon`, ERTS 17.0.2 / OTP 29). The ad-hoc-signed Swift `vz` sidecar rides inside the payload's
`priv/`; the engine finds it via `:code.priv_dir(:vzbeam)`.

## Evidenced on the Mac (layer 3 — no VM boot needed)

The single binary runs with **no Elixir/Erlang/Swift** on the target (contrast: the escript fails with
`env: escript: No such file or directory` without Erlang on PATH — exactly the friction Burrito removes).

The **bundled** sidecar extracts intact and is usable:

```
DIR=$(./burrito_out/vzbeam_macos_silicon maintenance directory)   # ~/Library/Application Support/.burrito/vzbeam_erts-17.0.2_0.1.0
VZ="$DIR"/lib/vzbeam-0.1.0/priv/vz
"$VZ" --version            -> {"protocol":1,"type":"version"}
codesign -d --entitlements - "$VZ"   -> [Key] com.apple.security.virtualization
test -x "$VZ"              -> exec bit OK
```

So: extraction is lossless, the protocol handshake works, the virtualization entitlement survived the
bundle→extract round-trip, and the binary is executable. On the build host the staged↔extracted bytes
were also confirmed sha256-identical.

## Reported working (layer 4 — VM boot)

The user confirmed the full flow works end-to-end from `vzbeam_macos_silicon` on the Mac (run a guest
from the bundled sidecar, etc.). Per-command boot output was not captured in this session; the
entitlement + `--version` evidence above is the load-bearing proof that the extracted sidecar is the
real signed product, and boot uses the same byte-identical binary.

## Non-bug worth recording

`vzbeam --help` appeared to print `unknown command: --help` on the Mac. Root cause (systematic-debugging):
the interactive zsh had `interactive_comments` off, so a trailing `# …` explanatory comment in a
copy-pasted command became **arguments** (`--help "#" …`). The `run(["--help"])` clause matches exactly
one arg, so extra args correctly fall through to "unknown command". Reproduced identically in the escript
and the packaged binary; clean `--help` returns exit 0. Not a packaging defect — a shell-comment artifact.

## Toolchain notes (macOS 26 build host)

- `xz` + `7z` + Zig 0.15.2 are provisioned via `mise.toml` (`conda:xz-tools`, `conda:7zip`, `zig`).
- On macOS 26 (Tahoe), Zig 0.15.2 fails to link against the macOS 26 SDK (`undefined symbol:
  _malloc_size` …); `SDKROOT` does **not** fix it (Zig resolves libSystem via `xcrun`). Building requires
  shadowing `xcrun` to return the macOS 15 SDK, or building on macOS ≤ 15. Documented in the README.
