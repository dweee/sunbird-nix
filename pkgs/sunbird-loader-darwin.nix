{
  lib,
  stdenv,
  fetchFromGitHub,
  rustPlatform,
  sqlite,
  sources,
}:

let
  source = sources.loader;
  src = fetchFromGitHub {
    inherit (source)
      owner
      repo
      rev
      hash
      ;
  };
in
rustPlatform.buildRustPackage {
  pname = "sunbird-loader";
  inherit (source) version;
  inherit src;

  cargoLock = {
    lockFile = "${src}/Cargo.lock";
    outputHashes = {
      "sunhook-sys-0.1.0" = source.sunhookHash;
    };
  };

  buildInputs = [
    sqlite
  ];

  # crates/runtime/build.rs reads PHOENIX_VERSION from `git log`, falling back
  # to "0" when built from a source archive without .git.
  postPatch = ''
    substituteInPlace crates/runtime/build.rs \
      --replace-fail '"0"' '"${source.version}"'
  '';

  cargoBuildFlags = [
    "-p"
    "phoenix-loader"
  ];

  # Matches the macOS test set in upstream PR #67 (.github/workflows/site.yml).
  cargoTestFlags = [
    "-p"
    "phoenix-hook"
    "-p"
    "phoenix-sigs"
    "-p"
    "phoenix-ui-desktop"
  ];

  installPhase = ''
    runHook preInstall

    dylib="target/${stdenv.hostPlatform.rust.rustcTarget}/release/libphoenix.dylib"
    if [ ! -f "$dylib" ]; then
      dylib="target/release/libphoenix.dylib"
    fi
    test -f "$dylib"

    install -Dm555 "$dylib" "$out/lib/libphoenix.dylib"

    /usr/bin/file -b "$out/lib/libphoenix.dylib" | grep -Fq 'Mach-O 64-bit dynamically linked shared library arm64'
    LC_ALL=C /usr/bin/grep -Fq 'phoenix-version:${source.version};' "$out/lib/libphoenix.dylib"

    runHook postInstall
  '';

  # Set a clean store install_name (cargo embeds the build-dir path) and re-sign
  # after Darwin fixups so AMFI accepts the final Mach-O without complaints,
  # matching upstream's macOS release step.
  postFixup = ''
    chmod u+w "$out/lib/libphoenix.dylib"
    install_name_tool -id "$out/lib/libphoenix.dylib" "$out/lib/libphoenix.dylib"
    /usr/bin/codesign --force --sign - "$out/lib/libphoenix.dylib"
    chmod a-w "$out/lib/libphoenix.dylib"
    /usr/bin/codesign --verify --strict "$out/lib/libphoenix.dylib"
  '';

  meta = {
    description = "Sunbird plugin runtime / access-gate loader for macOS Phoenix (upstream PR #67)";
    homepage = "https://github.com/sunbird-tools/sunbird/pull/67";
    license = lib.licenses.eupl12;
    platforms = [ "aarch64-darwin" ];
  };
}
