{
  lib,
  stdenvNoCC,
  fetchurl,
  sources,
}:

let
  source = sources.phoenix;
in
stdenvNoCC.mkDerivation {
  pname = "phoenix";
  inherit (source) version;

  src = fetchurl {
    inherit (source) url hash;
    name = "phoenix-${source.version}-arm64.zip";
  };

  dontUnpack = true;
  # Store fixups can invalidate the signatures of the app and its helpers.
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/Applications" "$out/bin"
    /usr/bin/ditto -x -k "$src" "$out/Applications"
    app="$out/Applications/Discord Phoenix.app"
    test -x "$app/Contents/MacOS/Discord"
    test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" = "${source.version}"
    /usr/bin/codesign --verify --strict --deep "$app"
    /usr/bin/codesign --verify --strict \
      -R='anchor apple generic and identifier "com.discord.DesktopGpui" and certificate leaf[subject.OU] = "53Q6R32WPB"' "$app"

    cat > "$out/bin/phoenix" <<LAUNCHER
    #!${stdenvNoCC.shell}
    exec /usr/bin/open -a "$app" "\$@"
    LAUNCHER
    chmod +x "$out/bin/phoenix"

    runHook postInstall
  '';

  meta = {
    description = "Signed Phoenix desktop client for Apple Silicon";
    homepage = "https://sunbird.tools";
    license = lib.licenses.unfree;
    platforms = [ "aarch64-darwin" ];
    mainProgram = "phoenix";
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
}
