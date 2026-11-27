{
  lib,
  stdenvNoCC,
  python3,
  phoenix,
  sunbird-loader,
  # "pinned": inject the loader from the Nix store (reproducible, no self-update).
  # "mutable": behave like upstream's sunbird-macos.sh and keep a self-updating
  #            copy in ~/Library/Application Support/Sunbird, falling back to
  #            the pinned loader when offline.
  loaderMode ? "pinned",
  site ? "https://assets.sunbird.tools",
}:

assert lib.assertOneOf "loaderMode" loaderMode [
  "pinned"
  "mutable"
];

let
  pinnedLoader = "${sunbird-loader}/lib/libphoenix.dylib";
  discordApp = "${phoenix}/Applications/Discord Phoenix.app";

  # Sunbird's mark (the dashboard's sun from scripts/sunbird-macos.sh),
  # rendered without AppKit/WindowServer so icon generation works headless.
  iconScript = ''
    import math, struct, sys, zlib

    size = 1024
    center = size / 2.0
    unit = (size / 32.0) * 0.86
    rings = [
        (14.0 * unit, (0x1E, 0x1F, 0x22)),
        (12.0 * unit, (0xF5, 0x9E, 0x0B)),
        (5.0 * unit, (0xFF, 0xF3, 0xB0)),
    ]

    raw = bytearray()
    for y in range(size):
        raw.append(0)
        dy = (y + 0.5) - center
        dy2 = dy * dy
        for x in range(size):
            dx = (x + 0.5) - center
            d = math.sqrt(dx * dx + dy2)
            r = g = b = a = 0.0
            for radius, (cr, cg, cb) in rings:
                cov = max(0.0, min(1.0, radius + 0.5 - d))
                if cov > 0.0:
                    inv = 1.0 - cov
                    r = cr * cov + r * inv
                    g = cg * cov + g * inv
                    b = cb * cov + b * inv
                    a = cov + a * inv
            if a > 0.0:
                raw.extend((
                    int(min(255, round(r / a))),
                    int(min(255, round(g / a))),
                    int(min(255, round(b / a))),
                    int(min(255, round(a * 255.0))),
                ))
            else:
                raw.extend((0, 0, 0, 0))

    def chunk(tag, data):
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    ihdr = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", ihdr)
        + chunk(b"IDAT", zlib.compress(bytes(raw), 6))
        + chunk(b"IEND", b"")
    )
    with open(sys.argv[1], "wb") as fh:
        fh.write(png)
  '';
in
stdenvNoCC.mkDerivation {
  pname = if loaderMode == "mutable" then "sunbird-mutable" else "sunbird";
  inherit (sunbird-loader) version;

  dontUnpack = true;
  # Store fixups can invalidate the signatures of the app and its helpers.
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Applications" "$out/bin" "$out/share/sunbird"

    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT

    ${python3}/bin/python3 - "$work/icon.png" <<'PY'
    ${iconScript}
    PY

    mkdir -p "$work/Sunbird.iconset"
    for sz in 16 32 128 256 512; do
      /usr/bin/sips -z "$sz" "$sz" "$work/icon.png" \
        --out "$work/Sunbird.iconset/icon_''${sz}x''${sz}.png" >/dev/null
      /usr/bin/sips -z "$((sz * 2))" "$((sz * 2))" "$work/icon.png" \
        --out "$work/Sunbird.iconset/icon_''${sz}x''${sz}@2x.png" >/dev/null
    done
    /usr/bin/iconutil -c icns "$work/Sunbird.iconset" -o "$out/share/sunbird/Sunbird.icns"

    ${
      if loaderMode == "pinned" then
        ''
          app="$out/Applications/Sunbird.app"
          if ! /bin/cp -cR "${discordApp}" "$app" 2>/dev/null; then
            /usr/bin/ditto "${discordApp}" "$app"
          fi
          chmod -R u+w "$app"
          /usr/bin/xattr -cr "$app"

          plist="$app/Contents/Info.plist"
          /usr/bin/plutil -replace CFBundleName -string Sunbird "$plist"
          /usr/bin/plutil -replace CFBundleDisplayName -string Sunbird "$plist"
          cp "$out/share/sunbird/Sunbird.icns" "$app/Contents/Resources/Sunbird.icns"
          /usr/bin/plutil -remove CFBundleIconName "$plist" 2>/dev/null || true
          /usr/bin/plutil -replace CFBundleIconFile -string Sunbird "$plist"
          # Launch Services (Dock, Spotlight, Cmd+R relaunch) keeps the loader
          # inserted through LSEnvironment while preserving Discord's Malloc* keys.
          /usr/bin/plutil -replace LSEnvironment.DYLD_INSERT_LIBRARIES \
            -string "${pinnedLoader}" "$plist"

          # Ad hoc without hardened runtime or Discord's restricted entitlements;
          # helpers and frameworks inside keep Discord's own signatures.
          /usr/bin/codesign --force --sign - "$app"
          /usr/bin/codesign --verify --strict "$app"
          /usr/bin/codesign -dv "$app" 2>&1 | grep -Fq 'Signature=adhoc'
          test "$(/usr/bin/plutil -extract LSEnvironment.DYLD_INSERT_LIBRARIES raw "$plist")" = "${pinnedLoader}"

          cat > "$out/bin/sunbird" <<LAUNCHER
          #!${stdenvNoCC.shell}
          set -eu
          gate_only=
          [ "\''${1:-}" = --update ] && exit 0
          while [ "\''${1:-}" = --no-runtime ] || [ "\''${1:-}" = --gate-only ]; do
            gate_only=1
            shift
          done
          set -- --env "DYLD_INSERT_LIBRARIES=${pinnedLoader}" --args "\$@"
          [ -n "\$gate_only" ] && set -- --env SUNBIRD_GATE_ONLY=1 "\$@"
          exec /usr/bin/open -a "$app" "\$@"
          LAUNCHER
          chmod +x "$out/bin/sunbird"
        ''
      else
        ''
          cat > "$out/bin/sunbird" <<LAUNCHER
          #!${stdenvNoCC.shell}
          set -eu
          home="\$HOME/Library/Application Support/Sunbird"
          site="${site}"
          discord="${discordApp}"
          pinned="${pinnedLoader}"
          icon="$out/share/sunbird/Sunbird.icns"
          copy="\$home/Sunbird.app"
          brand=2
          gate_only=

          mkdir -p "\$home"
          fetch() { /usr/bin/curl -fsSL --proto =https --proto-redir =https "\$@" 2>/dev/null; }

          version=
          [ -f "\$home/pin" ] || version=\$(fetch --max-time 5 "\$site/version.json" |
            /usr/bin/sed -n 's/.*"loader": *"\([^"]*\)".*/\1/p')
          if [ -n "\$version" ] && [ "\$version" != "\$(cat "\$home/version" 2>/dev/null)" ]; then
            tmp=\$(mktemp "\$home/libphoenix.dylib.XXXXXX")
            if fetch --max-time 60 -o "\$tmp" "\$site/plugins/libphoenix-macos-arm64.dylib" &&
               /usr/bin/file -b "\$tmp" 2>/dev/null | /usr/bin/grep -q 'Mach-O 64-bit dynamically linked shared library arm64' &&
               LC_ALL=C /usr/bin/grep -q 'phoenix-version:' "\$tmp" &&
               (/usr/bin/codesign -v "\$tmp" >/dev/null 2>&1 || /usr/bin/codesign --force --sign - "\$tmp" >/dev/null 2>&1); then
              mv "\$tmp" "\$home/libphoenix.dylib"
              echo "\$version" >"\$home/version"
            else
              rm -f "\$tmp"
            fi
          fi

          loader="\$pinned"
          [ -f "\$home/libphoenix.dylib" ] && loader="\$home/libphoenix.dylib"
          [ "\''${1:-}" = --update ] && exit 0
          while [ "\''${1:-}" = --no-runtime ] || [ "\''${1:-}" = --gate-only ]; do
            gate_only=1
            shift
          done

          stamp="\$(/usr/bin/stat -f '%m %z' "\$discord/Contents/MacOS/Discord") \$loader brand \$brand"
          if [ "\$stamp" != "\$(cat "\$home/stamp" 2>/dev/null)" ] ||
             ! /usr/bin/codesign -dv "\$copy" 2>&1 | /usr/bin/grep -q 'Signature=adhoc'; then
            tmp=\$(mktemp -d "\$home/Sunbird.XXXXXX")
            new="\$tmp/Sunbird.app"
            if ! /bin/cp -cR "\$discord" "\$new" 2>/dev/null; then
              /usr/bin/ditto "\$discord" "\$new"
            fi
            chmod -R u+w "\$new"
            /usr/bin/xattr -cr "\$new"
            plist="\$new/Contents/Info.plist"
            /usr/bin/plutil -replace CFBundleName -string Sunbird "\$plist"
            /usr/bin/plutil -replace CFBundleDisplayName -string Sunbird "\$plist"
            cp "\$icon" "\$new/Contents/Resources/Sunbird.icns"
            /usr/bin/plutil -remove CFBundleIconName "\$plist" 2>/dev/null || true
            /usr/bin/plutil -replace CFBundleIconFile -string Sunbird "\$plist"
            /usr/bin/plutil -replace LSEnvironment.DYLD_INSERT_LIBRARIES -string "\$loader" "\$plist"
            /usr/bin/codesign --force --sign - "\$new" >/dev/null 2>&1
            rm -rf "\$copy"
            mv "\$new" "\$copy"
            rmdir "\$tmp"
            echo "\$stamp" >"\$home/stamp"
            /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "\$copy" 2>/dev/null || true
          fi

          set -- --env "DYLD_INSERT_LIBRARIES=\$loader" --args "\$@"
          [ -n "\$gate_only" ] && set -- --env SUNBIRD_GATE_ONLY=1 "\$@"
          exec /usr/bin/open -a "\$copy" "\$@"
          LAUNCHER
          chmod +x "$out/bin/sunbird"

          launcher_app="$out/Applications/Sunbird.app"
          mkdir -p "$launcher_app/Contents/MacOS" "$launcher_app/Contents/Resources"
          cp "$out/share/sunbird/Sunbird.icns" "$launcher_app/Contents/Resources/Sunbird.icns"
          cat > "$launcher_app/Contents/MacOS/sunbird" <<WRAPPER
          #!${stdenvNoCC.shell}
          exec "$out/bin/sunbird" "\$@"
          WRAPPER
          chmod +x "$launcher_app/Contents/MacOS/sunbird"
          cat > "$launcher_app/Contents/Info.plist" <<'PLIST'
          <?xml version="1.0" encoding="UTF-8"?>
          <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
          <plist version="1.0">
          <dict>
            <key>CFBundleExecutable</key><string>sunbird</string>
            <key>CFBundleIdentifier</key><string>tools.sunbird.launcher</string>
            <key>CFBundleName</key><string>Sunbird</string>
            <key>CFBundleDisplayName</key><string>Sunbird</string>
            <key>CFBundleIconFile</key><string>Sunbird</string>
            <key>CFBundlePackageType</key><string>APPL</string>
            <key>CFBundleShortVersionString</key><string>1.0</string>
            <key>LSMinimumSystemVersion</key><string>13.0</string>
            <key>LSUIElement</key><true/>
          </dict>
          </plist>
          PLIST
          /usr/bin/codesign --force --sign - "$launcher_app"
          /usr/bin/codesign --verify --strict "$launcher_app"
        ''
    }

    cat > "$out/bin/sunbird-gate-only" <<LAUNCHER
    #!${stdenvNoCC.shell}
    exec "$out/bin/sunbird" --gate-only "\$@"
    LAUNCHER
    chmod +x "$out/bin/sunbird-gate-only"

    gate_app="$out/Applications/Sunbird (access gate only).app"
    mkdir -p "$gate_app/Contents/MacOS" "$gate_app/Contents/Resources"
    cp "$out/share/sunbird/Sunbird.icns" "$gate_app/Contents/Resources/Sunbird.icns"
    cat > "$gate_app/Contents/MacOS/sunbird-gate-only" <<WRAPPER
    #!${stdenvNoCC.shell}
    exec "$out/bin/sunbird-gate-only" "\$@"
    WRAPPER
    chmod +x "$gate_app/Contents/MacOS/sunbird-gate-only"
    cat > "$gate_app/Contents/Info.plist" <<'PLIST'
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleExecutable</key><string>sunbird-gate-only</string>
      <key>CFBundleIdentifier</key><string>tools.sunbird.launcher.gate-only</string>
      <key>CFBundleName</key><string>Sunbird (access gate only)</string>
      <key>CFBundleDisplayName</key><string>Sunbird (access gate only)</string>
      <key>CFBundleIconFile</key><string>Sunbird</string>
      <key>CFBundlePackageType</key><string>APPL</string>
      <key>CFBundleShortVersionString</key><string>1.0</string>
      <key>LSMinimumSystemVersion</key><string>13.0</string>
      <key>LSUIElement</key><true/>
    </dict>
    </plist>
    PLIST
    /usr/bin/codesign --force --sign - "$gate_app"
    /usr/bin/codesign --verify --strict "$gate_app"

    runHook postInstall
  '';

  passthru = {
    inherit phoenix sunbird-loader loaderMode;
  };

  meta = {
    description = "Phoenix started with the Sunbird loader injected on Apple Silicon";
    homepage = "https://sunbird.tools";
    license = lib.licenses.unfree;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "sunbird";
  };
}
