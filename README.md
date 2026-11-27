# phoenix-flake

Phoenix (desktop build 2233, AppImage) wrapped with `appimageTools`, plus the Sunbird loader preloaded the same way upstream's `sunbird-linux.sh` does it. The AppImage itself is never modified.

## Outputs

| Output | What it is |
| --- | --- |
| `packages.phoenix` | Plain client, `bin/phoenix` |
| `packages.sunbird-loader` | `libphoenix.so`, pinned by hash |
| `packages.sunbird` (default) | `bin/sunbird`, `bin/sunbird-gate-only`, two desktop entries, loader from the store |
| `packages.sunbird-mutable` | Same, but self-updates the loader into `$XDG_DATA_HOME/sunbird` like upstream, store copy as offline fallback |
| `nixosModules.default` | `programs.sunbird.enable` / `.package` |
| `homeManagerModules.default` | Same for Home Manager, plus `programs.sunbird.defaultLinkHandler` |
| `overlays.default` | Adds all of the above to `pkgs` |

## Use

```nix
# flake.nix of your system config
inputs.phoenix.url = "git+https://github.com/ardishko/sunbird-nix";

# in a NixOS module
imports = [ inputs.phoenix.nixosModules.default ];
programs.sunbird.enable = true;
# programs.sunbird.package = inputs.phoenix.packages.x86_64-linux.sunbird-mutable;
```

Or per user with Home Manager:

```nix
imports = [ inputs.phoenix.homeManagerModules.default ];
programs.sunbird.enable = true;
# programs.sunbird.defaultLinkHandler = true;  # needs xdg.mimeApps.enable = true
```

Or just the package, without a module. Add the second part too, or the client takes over link handling again (see Known limits):

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

## How the preload works

`sunbird` exports `SUNBIRD_PRELOAD=<loader>` and `SUNBIRD_GATE_ONLY=1` for the gate-only entry, then runs `phoenix`. The FHS env's `/etc/profile` turns `SUNBIRD_PRELOAD` into `LD_PRELOAD` inside the bubblewrap sandbox, so the loader is not injected into bwrap or the outer wrapper. The sandbox also provides what the loader calls at runtime: `libcurl.so.4`, python3 + PyGObject + Ayatana AppIndicator (tray), zenity/kdialog (plugin file picker), wl-copy/xclip/xsel, notify-send, xdg-open.

## Updating

Nothing binary lives in this repo. `sources.json` holds URLs and hashes; Nix downloads the AppImage and loader from upstream at build time.

```sh
./update.sh   # scrape sunbird.tools + version.json, rewrite sources.json if anything changed
```

- Phoenix: build number, URL and SHA-256 come from the sunbird.tools page. The file itself comes from a separate mirror, so Nix checks one source against the other.
- Loader: Sunbird publishes no hash, so the script downloads it once and hashes it (trust on first use).

`.github/workflows/update.yml` runs this every 30 minutes, verifies by fetching through Nix, and opens a PR touching only `sources.json`.

## Known limits

- The loader URL is unversioned and the file changes every release. A pinned hash only builds while upstream still serves that exact file or it is already in your store. CI narrows the gap but cannot close it without mirroring the file. Between upstream's release and your merge, a fresh build fails with a hash mismatch: merge the PR, or use `sunbird-mutable`.
- Upstream's launcher kills an already running Phoenix that was started without Sunbird. This one does not: quit the plain client first.
- In-app "Apply Updates" in Sunbird cannot replace the store copy in `pinned` mode. Use `sunbird-mutable` if you want that.
- The client registers itself as the link handler on every launch, writing its own URL-handler entry into `~/.local/share/applications` that points at its bare binary (no sandbox, no loader) and resetting `mimeapps.list`. Both modules put their own file at that path, which makes the client leave it alone. With just the package, add the `xdg.dataFile` lines shown under Use.
- `tests/fake-appimage.nix` is a stand-in AppRun used to check the env and preload path without the real AppImage.
