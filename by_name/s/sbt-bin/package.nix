{
  lib,
  stdenvNoCC,
  fetchurl,
  jdk17_headless,
  makeWrapper,
  ncurses,
  ...
}:

let
  mkPackage =
    { version, hash }:
    stdenvNoCC.mkDerivation (finalAttrs: {
      # `-bin`: the input is an upstream release archive, not source.
      pname = "sbt-bin";
      inherit version;

      src = fetchurl {
        url = "https://github.com/sbt/sbt/releases/download/v${version}/sbt-${version}.tgz";
        inherit hash;
      };

      nativeBuildInputs = [
        jdk17_headless
        makeWrapper
      ];

      dontConfigure = true;
      dontBuild = true;

      installPhase = ''
        runHook preInstall

        mkdir -p "$out/share/sbt" "$out/bin"
        cp -a . "$out/share/sbt"

        # Upstream also ships prebuilt native thin clients (`sbtn`) and a Windows
        # batch script. Only the JVM runner belongs to this package.
        find "$out/share/sbt/bin" -type f ! -name sbt ! -name sbt-launch.jar -delete

        # The launcher ignores the JAVA_HOME environment variable; it only
        # accepts the interpreter through its own `-java-home` option.
        echo "-java-home ${jdk17_headless.home}" >> "$out/share/sbt/conf/sbtopts"

        makeWrapper "$out/share/sbt/bin/sbt" "$out/bin/sbt" \
          --prefix PATH : "${lib.makeBinPath [ ncurses ]}"

        runHook postInstall
      '';

      doInstallCheck = true;
      installCheckPhase = ''
        runHook preInstallCheck

        # `--version --allow-empty` reports the runner version without resolving
        # any artifact, so the check itself stays offline.
        export HOME="$TMPDIR"
        "$out/bin/sbt" --version --allow-empty | grep -q "sbt runner version: ${version}"

        runHook postInstallCheck
      '';

      # sbt is self-hosting: its own build requires a working sbt. Until the
      # module graph is rebuilt from source, this package is a bootstrap seed.
      passthru.bootstrapSeed = true;

      meta = {
        description = "Build tool for Scala and Java (bootstrap seed from the upstream release)";
        homepage = "https://www.scala-sbt.org/";
        changelog = "https://github.com/sbt/sbt/releases/tag/v${version}";
        license = lib.licenses.asl20;
        sourceProvenance = with lib.sourceTypes; [ binaryBytecode ];
        platforms = lib.platforms.unix;
        mainProgram = "sbt";
      };
    });
in
{
  "sbt-bin_1_11_6" = mkPackage {
    version = "1.11.6";
    hash = "sha256-zkmV6GrPf91X23hZXNaRjAF4Gmp0EXDmQJrbpZfg2D0=";
  };
}
