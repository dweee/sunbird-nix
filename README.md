# phoenix-flake

Phoenix (desktop build 2233) with the Sunbird loader, packaged for NixOS (`x86_64-linux`) and Apple Silicon macOS (`aarch64-darwin`).

On Linux, the AppImage is wrapped with `appimageTools` and preloaded the same way upstream's `sunbird-linux.sh` does it without modifying the AppImage. On Apple Silicon macOS, `sunbird-loader` is built from source from [Sunbird PR #67][macos-pr], and `sunbird` wraps an ad-hoc re-signed copy of `Discord Phoenix.app` with `DYLD_INSERT_LIBRARIES` matching upstream's `sunbird-macos.sh`.

## Outputs

| Output | What it is |
| --- | --- |
| `packages.phoenix` | Plain signed client, `bin/phoenix` (`Applications/Discord Phoenix.app` on macOS) |
| `packages.sunbird-loader` | `libphoenix.so` on Linux (pinned by hash) or `libphoenix.dylib` on macOS (built from [Sunbird PR #67][macos-pr]) |
| `packages.sunbird` (default) | `bin/sunbird`, `bin/sunbird-gate-only`, desktop entries / `.app` bundles, loader from the store |
| `packages.sunbird-mutable` | Same, but self-updates the loader (`$XDG_DATA_HOME/sunbird` on Linux, `~/Library/Application Support/Sunbird` on macOS), store copy as offline fallback |
| `nixosModules.default` | `programs.sunbird.enable` / `.package` (Linux) |
| `homeManagerModules.default` | Same for Home Manager (Linux and Apple Silicon macOS), plus `programs.sunbird.defaultLinkHandler` on Linux |
| `overlays.default` | Adds all of the above to `pkgs` for the current platform |

## Use

```nix
# flake.nix of your system config
inputs.phoenix.url = "git+https://github.com/ardishko/sunbird-nix";

# in a NixOS module
imports = [ inputs.phoenix.nixosModules.default ];
programs.sunbird.enable = true;
# programs.sunbird.package = inputs.phoenix.packages.x86_64-linux.sunbird-mutable;
```

Or per user with Home Manager (Linux or `aarch64-darwin`):

```nix
imports = [ inputs.phoenix.homeManagerModules.default ];
programs.sunbird.enable = true;
# programs.sunbird.defaultLinkHandler = true;  # Linux only; needs xdg.mimeApps.enable = true
```

Or just the package on Linux, without a module. Add the second part too, or the client takes over link handling again (see Known limits):

```nix
{ inputs, pkgs, ... }:
let
  sunbird = inputs.phoenix.packages.${pkgs.system}.sunbird;
in
{
  home.packages = [ sunbird ];
  xdg.dataFile."applications/${sunbird.urlHandler}" = {
    source = "${sunbird}/share/applications/${sunbird.urlHandler}";
    force = true;
  };
}
```

Quick test: `nix run .` (Sunbird) / `nix run .#gate-only` / `nix run .#phoenix`.

## Apple Silicon

`sources-darwin.json` pins the macOS ARM64 Phoenix 2233 archive and the [Sunbird PR #67][macos-pr] loader source separately from the Linux `sources.json` update schedule:

- `packages.aarch64-darwin.phoenix` ships the stock signed `Discord Phoenix.app` with Discord's original signature and hardened runtime verified at build time.
- `packages.aarch64-darwin.sunbird-loader` builds `libphoenix.dylib` from `cocomeshy/sunbird` (PR #67), runs the upstream macOS crate tests (`phoenix-hook`, `phoenix-sigs`, `phoenix-ui-desktop`), and ad-hoc signs the dylib.
- `packages.aarch64-darwin.sunbird` (default) builds an ad-hoc re-signed `Applications/Sunbird.app` from `phoenix` with `Sunbird.icns` and `LSEnvironment.DYLD_INSERT_LIBRARIES` pointing at `sunbird-loader`, plus `Applications/Sunbird (access gate only).app`, `bin/sunbird`, and `bin/sunbird-gate-only`. Helpers and frameworks inside the bundle keep Discord's signatures, and the stock `phoenix` output stays untouched.
- `packages.aarch64-darwin.sunbird-mutable` keeps a self-updating copy under `~/Library/Application Support/Sunbird` like `scripts/sunbird-macos.sh`, falling back to the store-built `sunbird-loader` when offline.

[macos-pr]: https://github.com/sunbird-tools/sunbird/pull/67

## How the preload works

On Linux, `sunbird` exports `SUNBIRD_PRELOAD=<loader>` and `SUNBIRD_GATE_ONLY=1` for the gate-only entry, then runs `phoenix`. The FHS env's `/etc/profile` turns `SUNBIRD_PRELOAD` into `LD_PRELOAD` inside the bubblewrap sandbox, so the loader is not injected into bwrap or the outer wrapper. The sandbox also provides what the loader calls at runtime: `libcurl.so.4`, python3 + PyGObject + Ayatana AppIndicator (tray), zenity/kdialog (plugin file picker), wl-copy/xclip/xsel, notify-send, xdg-open.

On macOS, `Discord Phoenix.app` ships with the hardened runtime, which ignores `DYLD_INSERT_LIBRARIES`. Following `scripts/sunbird-macos.sh`, `sunbird` ad-hoc re-signs a copy named `Sunbird.app` without the hardened runtime or restricted entitlements and sets `LSEnvironment.DYLD_INSERT_LIBRARIES` so Finder, Spotlight, Dock, and `Cmd+R` relaunches keep the loader inserted.

## Updating

Nothing binary lives in this repo. `sources.json` holds URLs and hashes for Linux; `sources-darwin.json` holds the macOS Phoenix archive and PR #67 loader source pin. Nix fetches everything at build time.

```sh
./update.sh   # scrape sunbird.tools + version.json + PR #67, rewrite sources*.json if anything changed
```

- Phoenix: build number, URL and SHA-256 come from the sunbird.tools page for both Linux and Apple Silicon. The files themselves come from a separate mirror, so Nix checks one source against the other.
- Loader (Linux): Sunbird publishes no hash, so the script downloads it once and hashes it (trust on first use).
- Loader (Apple Silicon): tracks [Sunbird PR #67][macos-pr] (and falls over to `sunbird-tools/sunbird` `main` once merged), prefetching the source archive and `sunhook-sys` git dependency hash from `Cargo.lock`.

`.github/workflows/update.yml` runs this every 30 minutes, verifies the updated hashes through Nix, and opens a PR touching only `sources.json` and/or `sources-darwin.json`.

## Known limits

- The Linux loader URL is unversioned and the file changes every release. A pinned hash only builds while upstream still serves that exact file or it is already in your store. CI narrows the gap but cannot close it without mirroring the file. Between upstream's release and your merge, a fresh build fails with a hash mismatch: merge the PR, or use `sunbird-mutable`.
- Upstream's launcher kills an already running Phoenix that was started without Sunbird. This one does not: quit the plain client first.
- In-app "Apply Updates" in Sunbird cannot replace the store copy in `pinned` mode. Use `sunbird-mutable` if you want that.
- On macOS, stripping Discord's restricted entitlements on the ad-hoc signed copy means macOS keychain/app-group sharing with stock Discord Phoenix is unavailable, so Sunbird may ask you to log in once.
- On Linux, the client registers itself as the link handler on every launch, writing its own URL-handler entry into `~/.local/share/applications` that points at its bare binary (no sandbox, no loader) and resetting `mimeapps.list`. Both modules put their own file at that path, which makes the client leave it alone. With just the package, add the `xdg.dataFile` lines shown under Use.
- `tests/fake-appimage.nix` is a stand-in AppRun used to check the env and preload path without the real AppImage.
