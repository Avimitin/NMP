{
  lib,
  stdenvNoCC,
  fetchgit,
  jdk17_headless,
  replaceVars,
  zip,
  ...
}:

let
  mkPackage =
    {
      version,
      rev,
      hash,
    }:
    let
      pom = replaceVars ./pom.xml.in {
        inherit version;
      };
    in
    stdenvNoCC.mkDerivation (finalAttrs: {
      pname = "scala3-interfaces";
      inherit version;

      src = fetchgit {
        url = "https://github.com/scala/scala3.git";
        inherit rev hash;
        sparseCheckout = [ "interfaces" ];
      };

      nativeBuildInputs = [
        jdk17_headless
        zip
      ];

      dontConfigure = true;

      buildPhase = ''
        runHook preBuild

        mkdir classes
        find interfaces/src -name '*.java' -print0 \
          | xargs -0 javac --release 8 -encoding UTF-8 -d classes

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall

        mavenDir="$out/share/maven/org/scala-lang/scala3-interfaces/${version}"
        mkdir -p "$mavenDir" "$out/share/java"

        mkdir -p classes/META-INF
        printf 'Manifest-Version: 1.0\n\n' > classes/META-INF/MANIFEST.MF

        # Keep the jar reproducible: zip stores file mtimes.
        find classes -exec touch -d '1980-01-01 00:00:00 UTC' {} +

        (cd classes && zip -X -q -r "$mavenDir/${finalAttrs.pname}-${version}.jar" .)

        ln -s "$mavenDir/${finalAttrs.pname}-${version}.jar" \
          "$out/share/java/${finalAttrs.pname}-${version}.jar"

        install -Dm644 ${pom} "$mavenDir/${finalAttrs.pname}-${version}.pom"

        runHook postInstall
      '';

      meta = {
        description = "Scala 3 compiler interfaces";
        homepage = "https://github.com/scala/scala3";
        license = lib.licenses.asl20;
        sourceProvenance = with lib.sourceTypes; [ fromSource ];
        platforms = lib.platforms.unix;
      };
    });
in
{
  "scala3-interfaces_3_8_4" = mkPackage {
    version = "3.8.4";
    rev = "7d4833b619d31ea9acac97fccf1e74b42b89c49f";
    hash = "sha256-NiWyz8xsrdSS7gq4mFZMvaRbGwSyqNF9JoBqVQRocIk=";
  };
}
