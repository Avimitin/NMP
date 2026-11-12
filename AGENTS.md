# AGENTS.md

## Purpose

This repository packages Scala/JVM projects as Nix derivations built from upstream source. It is a
Linux-distribution-style package set: each package fetches source from an upstream VCS (usually GitHub), builds it with
Nix, and installs a Maven-compatible artifact that can replace what a user would otherwise download from Maven Central.
A package may also be a build tool rather than an artifact; those follow
[Build tools and bootstrap seeds](#build-tools-and-bootstrap-seeds).

Maven Central is **not** a build input. A consumer's `mtf.lock.json` or similar lock file is an inventory of the
coordinates and versions that a project needs; it is not permission to download those artifacts at build time.

The repository is managed as one Nix flake. A package declaration lives at
`by_name/<alphabet>/<package_name>/package.nix`. The flake and `overlay.nix` expose the same bindings, so downstream
consumers can import the package set into their own nixpkgs instance.

The non-negotiable rules:

1. A package declaration lives at `by_name/<alphabet>/<package_name>/package.nix`.
2. A `package.nix` may declare multiple versions. It must evaluate to an attrset mapping public versioned binding names
   to derivations. Always design for adding more versions.
3. `flake.nix` discovers packages and versions automatically. Do not maintain a manual list anywhere.
4. Fetch source from the upstream VCS and build it. Do not use prebuilt jars, POMs, or other Maven Central artifacts as
   build inputs.
5. Builds must be hermetic and offline. Dependency resolution during `buildPhase` or `installPhase` must not contact
   Maven Central or any other network repository.
6. Each artifact package must install a Maven-compatible jar and POM under the artifact's real Maven coordinates.
7. A package may be a build tool instead of an artifact. Tool packages install a runnable program and follow
   [Build tools and bootstrap seeds](#build-tools-and-bootstrap-seeds).
8. A package whose input is a prebuilt upstream release instead of source is named `<package_name>-bin`, both in the
   directory and in every binding. Bootstrap seeds always follow this.

## Repository layout

```
flake.nix
flake.lock
overlay.nix              # exposes the package set as pkgs.nmp
by_name/
  <alphabet>/
    <package_name>/
      package.nix          # required
      common.nix           # optional: build logic shared by all versions
      pom.xml.in           # optional: POM template consumed by replaceVars
      patches/             # optional
      scripts/             # optional
```

Example:

```
by_name/
  s/
    scala3-interfaces/
      package.nix
```

A package directory may expose several versions. For example, a `jackson-core` declaration may expose
`jackson-core_2_17_0` and `jackson-core_2_23_0`.

### Naming rules

- `<package_name>` is the package identity. It is lowercase kebab-case and is normally based on the upstream Maven
  `artifactId`.
- A package built from a prebuilt upstream release carries the `-bin` suffix: `by_name/s/sbt-bin/package.nix` with
  binding `sbt-bin_1_11_6`. The suffix records provenance; the installed program keeps its real name
  (`meta.mainProgram = "sbt"`).
- `<alphabet>` is the first character of `<package_name>`, lowercased. For example, `jackson-core` lives in
  `by_name/j/jackson-core/package.nix`.
- The Maven `groupId` is part of the artifact coordinate but is not part of the directory name. Record it in the
  derivation's Maven output layout and generated POM.
- The public binding for a versioned package is `<package_name>_<sanitized_version>`, where every `.` in the version is
  replaced by `_`. Other characters are preserved, so date-style versions such as `2024-01-01` keep their form.
  - `2.23.0` becomes `jackson-core_2_23_0`
  - `1.0.0-RC1` becomes `jackson-core_1_0_0-RC1`
  - `2024-01-01` becomes `jackson-core_2024-01-01`
- The keys of the `package.nix` attrset are these public binding names. The derivation value stores the raw upstream
  version, for example key `"jackson-core_2_23_0"` with `version = "2.23.0";`.
- The overlay exposes the bindings as `pkgs.nmp.<binding>`; the flake exposes the same bindings as
  `packages.<system>.<binding>`.
- Binding names must be unique across the repository. A collision is an error, not something to resolve by ordering.
- Each derivation's `version` must match the version suffix in its binding key, and its `pname` should be the package
  directory name so Nix derivation names stay predictable.

### Package directory contents

- Exactly one `package.nix` per package directory. Do not use `default.nix`; the flake discovery only looks for
  `package.nix`.
- Additional files local to the package are allowed: `common.nix`, patches, wrapper scripts, fixture files, and so on.
- Do not write multi-line file contents as heredocs inside `package.nix`. Keep them in a template file next to the
  package and render it with `replaceVars` (for example `./pom.xml.in`).
- Packages must be self-contained. Do not reach into another package's directory. If shared logic is truly needed, add
  it under a top-level `lib/` and document it in this file first.
- Do not vendor upstream jars, upstream POMs, `~/.m2` contents, or build outputs. A POM generated by the derivation from
  source metadata is a build output and is allowed.

## Package declaration shape

`package.nix` is called with `pkgs.callPackage`. It must evaluate to an attrset:

```nix
{
  "<package_name>_<sanitized_version>" = <derivation>;
  # more versions...
}
```

- Always return an attrset, even when the package currently has only one version. This keeps adding versions from
  requiring a change to the flake.
- Each key is a public versioned binding. The value's `version` attribute is the raw upstream version, for example key
  `"jackson-core_2_23_0"` with `version = "2.23.0";`.
- Beyond this mechanical shape, package declarations are freestyle.

### Freestyle declarations

Agents may structure package files as needed. The recommended pattern when several versions share most of the build
procedure is:

- `common.nix` exports the shared build function.
- `package.nix` lists every version and passes only the version-specific inputs, usually `version`, VCS `rev`/`hash`,
  and patches.

This keeps the build procedure in one place while making each supported version explicit. Keep the
`do not use default.nix` rule: the entry point is always `package.nix`.

## Multiple versions

Always assume more versions will be added later.

- Add a new version as a new entry in the `package.nix` attrset.
- Reuse `common.nix` rather than copying the whole build procedure.
- Only repeat version-specific details: source, patches, and flags that genuinely differ.
- Do not remove an existing version unless the user explicitly asks.
- If shared build logic changes, rebuild every version, not just the one you were working on.

## Maven-compatible output

Every package must install its artifact under the real Maven coordinate:

```text
$out/share/maven/<groupId with / separators>/<artifactId>/<version>/<artifactId>-<version>.jar
$out/share/maven/<groupId with / separators>/<artifactId>/<version>/<artifactId>-<version>.pom
```

Also install a convenience symlink:

```text
$out/share/java/<artifactId>-<version>.jar
```

The symlink lets the Nix Java setup hook discover the jar in `buildInputs`; the Maven-layout copy is what a local Maven
repository or downstream packaging step consumes.

Rules:

- The `groupId`, `artifactId`, and `version` in the POM must match the installed Maven path exactly.
- Generate the POM from source metadata or a small local template. Do not fetch the published POM from Maven Central.
- The POM must describe real runtime dependencies only. Those dependencies must be available as Nix packages or pinned
  offline inputs.
- Preserve the upstream Java class-file compatibility where it is known. For example, compile a Java 8 artifact with
  `javac --release 8`.
- Preserve required resources and manifest entries from upstream when they are part of the artifact contract.
- Do not install an unversioned jar as the primary output.

## Source and build rules

- Fetch source from the upstream VCS, pinned to a release tag or commit with a verified hash. `fetchgit`,
  `fetchFromGitHub`, and `fetchurl` for VCS archives are acceptable. Use sparse checkout when only one module is needed.
- Do not use a prebuilt jar, published POM, or artifact downloaded from Maven Central as a build input. The only Maven
  Central interaction allowed is reviewing coordinates and versions; the build itself must not download artifacts.
- A consumer lock file such as `mtf.lock.json` is an inventory of what a downstream project needs. It is not a source of
  artifacts and must not be used to fetch jars or POMs during the build.
- Dependencies must be pinned and available from Nix-provided inputs or a pinned offline cache. Resolution during
  `buildPhase` or `installPhase` must not reach Maven Central, sbt repositories, or any other network repository.
- Prefer the upstream build system when it can run offline with Nix-supplied dependencies. If it cannot, build the
  required module directly with the appropriate compiler and explicit inputs.
- Do not make `mvnHash`-style Maven Central dependency fetching the build strategy.
- Keep shared build logic in `common.nix` so every version uses the same offline procedure.

## Build tools and bootstrap seeds

A package may be a build tool instead of an artifact. `sbt` is the current example; it is packaged as `sbt-bin` because
it is taken from an upstream release archive. It has no library contract for us, and its release is a launcher script
plus `sbt-launch.jar`. Tool packages live under the same `by_name` tree but must:

- Install a runnable program as `$out/bin/<mainProgram>` instead of the Maven layout.
- Set `meta.mainProgram` and describe the tool in `meta.description`.
- Be named `<package_name>-bin` and marked as a bootstrap seed when the tool is taken from a prebuilt upstream release.

A bootstrap seed uses a prebuilt upstream release as a fixed-output input because the project cannot be built without
itself. This is only acceptable for a self-hosting build tool, and it must be marked honestly:

```nix
passthru.bootstrapSeed = true;
meta.sourceProvenance = with lib.sourceTypes; [ binaryBytecode ];
```

Seeds are tools, never artifacts: they are not installed into `share/maven`, not listed as POM dependencies, and not
presented as something a consumer resolves.

Why `sbt-bin` needs one: sbt is self-hosting. `sbt/sbt` at `v1.11.6` declares `sbt.version=1.11.4` in
`project/build.properties`, and upstream's own instructions say to build sbt from source with a stable binary sbt. A
fully source-built sbt therefore needs the whole `org.scala-sbt` module graph (`launcher`, `compiler-interface`, `zinc`,
`io`, `librarymanagement`, `util-*`), and each of those modules is also built with sbt. Rebuilding that graph is its own
project; the seed is its entry point. Use the seed to build the modules from source, then replace the seed with the
result.

## Reference `package.nix`

The complete working example is `by_name/s/scala3-interfaces/package.nix`. The essential shape is:

```nix
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
    { version, rev, hash }:
    let
      pom = replaceVars ./pom.xml.in { inherit version; };
    in
    stdenvNoCC.mkDerivation (finalAttrs: {
      pname = "example";
      inherit version;

      src = fetchgit {
        url = "https://github.com/example/example.git";
        inherit rev hash;
        sparseCheckout = [ "src" ];
      };

      nativeBuildInputs = [ jdk17_headless zip ];
      dontConfigure = true;

      buildPhase = ''
        runHook preBuild
        mkdir classes
        find src -name '*.java' -print0 | xargs -0 javac --release 8 -d classes
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        mavenDir="$out/share/maven/org/example/example/${version}"
        mkdir -p "$mavenDir" "$out/share/java"
        (cd classes && zip -X -q -r "$mavenDir/${finalAttrs.pname}-${version}.jar" .)
        ln -s "$mavenDir/${finalAttrs.pname}-${version}.jar" \
          "$out/share/java/${finalAttrs.pname}-${version}.jar"
        install -Dm644 ${pom} "$mavenDir/${finalAttrs.pname}-${version}.pom"
        runHook postInstall
      '';

      meta = {
        description = "Example package";
        homepage = "https://github.com/example/example";
        license = lib.licenses.asl20;
        sourceProvenance = with lib.sourceTypes; [ fromSource ];
        platforms = lib.platforms.unix;
      };
    });
in
{
  "example_1_2_3" = mkPackage {
    version = "1.2.3";
    rev = "<commit-sha>";
    hash = "sha256-...";
  };
}
```

For a multi-version package, add another binding that calls `mkPackage` with a different `version`, `rev`, and `hash`.
When the build procedure grows, move `mkPackage` into `common.nix` and import it from `package.nix`.

## Flake and overlay contract

The flake must:

- Discover every `by_name/*/*/package.nix` without a hand-written list.
- Route discovery and validation through `overlay.nix`, so the flake and downstream consumers share one implementation.
- Validate that the first directory under `by_name/` matches the package name's first letter.
- Expect each `package.nix` to return an attrset of public binding name to derivation.
- Expose those bindings as `packages.<system>."<package_name>_<sanitized_version>"`.
- Expose the same set as `overlays.default`.
- Reject binding keys that do not start with `<package_name>_`.
- Not expose an unversioned alias; a package may have several concurrent versions.
- Fail on duplicate binding names.
- Keep `flake.lock` committed.
- Gate unfree packages behind the `NIXPKGS_ALLOW_UNFREE` environment variable.

The overlay must:

- Expose the set as `pkgs.nmp`, not merged into the top level.
- Apply the same shard, binding-name, and duplicate validation as the flake.
- Stay usable standalone with `import nixpkgs { overlays = [ (import ./overlay.nix) ]; }`.

Reference implementations:

- `overlay.nix` — package discovery, shard and binding-name validation, duplicate detection, and the `pkgs.nmp`
  namespace.
- `flake.nix` — per-system instantiation, `packages`, `overlays.default`, and the `formatter`.

A Nix overlay's attribute names must be known before any package is evaluated, but binding names are only discoverable
by calling each `package.nix`, so a flattened overlay would recurse infinitely.

Bindings are accessed through that namespace:

```sh
nix build '.#"jackson-core_2_23_0"'
nix build '.#"sbt-bin_1_11_6"'
```

Downstream flakes consume the overlay:

```nix
import nixpkgs { overlays = [ (import ./overlay.nix) ]; }
# then: pkgs.nmp."jackson-core_2_23_0"
```

## Unfree and proprietary packages

Do not add commercial or closed-source packages unless the user explicitly requests one.

When the user does request one:

- Mark the derivation with an unfree license, for example `meta.license = lib.licenses.unfree;`.
- Keep the flake's `config.allowUnfree` gated by `NIXPKGS_ALLOW_UNFREE`; never hard-code `allowUnfree = true`.
- Build with the guard enabled and impure evaluation, because the environment variable must be readable:

  ```sh
  NIXPKGS_ALLOW_UNFREE=1 nix build --impure '.#"<package_name>_<sanitized_version>"'
  ```

- Do not add an unfree package as a dependency of an open-source package unless the user explicitly requests that too.

## Adding a new package

1. Pick `<package_name>` from the upstream Maven `artifactId` and confirm its first letter. Find the upstream VCS
   repository and the tag or commit for each version. Create `by_name/<alphabet>/<package_name>/package.nix`.
2. If a consumer lock file such as `mtf.lock.json` exists, use it to identify the required versions and coordinates. Do
   not use it to fetch jars or POMs during the build.
3. Determine all build dependencies and make them available as Nix inputs. The build must not resolve anything from
   Maven Central or another online repository.
4. Implement the source build. Use `common.nix` if the procedure will be shared by multiple versions.
5. Write `package.nix` as an attrset of versioned binding name to derivation. Include at least one version entry.
6. Pin every VCS source and fixed-output input with a hash. Bootstrap any hash from the Nix build error (`got:` value);
   never guess it.
7. For an artifact package, install the jar and POM under the real Maven coordinate and symlink the jar into
   `$out/share/java`. For a build tool, install `$out/bin/<mainProgram>` instead.
8. Build every exposed binding, not just the newest version.
9. Run the validation commands below and commit.

## Adding a version to an existing package

1. Add a new versioned binding key to `package.nix` with a call to the shared build function.
2. Pass only the version-specific inputs: `version`, VCS `rev`/`hash`, patches, and flags. Keep the installed Maven
   coordinate consistent with the new version.
3. Do not remove or rewrite existing version entries unless the user explicitly asks.
4. Rebuild every version if you changed `common.nix` or another shared file.
5. Run the validation commands below.

## Validation

Run at least:

```sh
nix build '.#"<package_name>_<sanitized_version>"'
nix flake check
nix fmt
```

If the repository contains unfree packages, run the flake check with the same guard:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix flake check --impure
```

Useful inspection commands:

```sh
nix flake show
nix eval --json .#packages.x86_64-linux --apply builtins.attrNames
nix path-info -r '.#"<package_name>_<sanitized_version>"'
find result/share/maven -type f
ls -l result/share/java
git status
```

For a package that is intentionally unfree, run the build with the unfree guard:

```sh
NIXPKGS_ALLOW_UNFREE=1 nix build --impure '.#"<package_name>_<sanitized_version>"'
```

Definition of done for a package change:

- [ ] Path, directory name, and shard agree.
- [ ] `package.nix` returns an attrset of versioned binding name to derivation.
- [ ] Every declared version builds as its own binding.
- [ ] Binding names follow `<package_name>_<sanitized_version>` and are unique.
- [ ] Packages built from a prebuilt release instead of source use the `-bin` suffix in the directory and binding names.
- [ ] Source comes from the upstream VCS, not from a Maven Central jar or POM.
- [ ] The build and install phases do not access Maven Central or any other network service.
- [ ] Every fixed-output hash was generated from a Nix build, not guessed.
- [ ] Artifact packages install the jar and POM under the correct `groupId`/`artifactId`/`version` Maven path.
- [ ] Artifact packages symlink `$out/share/java/<artifactId>-<version>.jar` to the Maven-layout jar.
- [ ] Tool packages install `$out/bin/<mainProgram>`; bootstrap seeds are marked with `passthru.bootstrapSeed` and
      binary source provenance.
- [ ] The POM lists only real runtime dependencies available as Nix inputs.
- [ ] Java class-file compatibility matches upstream where known.
- [ ] Adding another version would only require a new entry and version-specific inputs.
- [ ] Unfree packages were explicitly requested and are gated by `NIXPKGS_ALLOW_UNFREE`.
- [ ] `nix flake check` and `nix fmt` pass.
- [ ] No `result` symlink, build output, or vendored dependency is committed.

## Troubleshooting

- **Hash mismatch on a fetched input**: update the hash with the `got:` value from the error. Do not use `--no-check`.
- **The build tries to reach Maven Central or another repository**: make the build offline. Fetch source from the
  upstream VCS and make every dependency a Nix input; do not weaken the sandbox.
- **The package was built from a downloaded jar/POM**: replace it with a source build from the upstream VCS. A lock file
  is inventory, not a source of artifacts.
- **Maven consumers cannot resolve the artifact**: check the `groupId` path, `artifactId`, and version in both the
  installed Maven layout and the generated POM. Ensure the jar is also symlinked into `$out/share/java`.
- **Class-file version differs from upstream**: compile with the matching `javac --release` level when it is known.
- **A declared version is missing from `packages`**: check that it is a key in the `package.nix` attrset, and that the
  resulting binding name does not collide.
- **Binding name is wrong**: only `.` is replaced with `_`. Hyphens and date separators are preserved.
- **The flake rejects an unfree package**: the package was not explicitly requested, or `NIXPKGS_ALLOW_UNFREE=1` and
  `--impure` were not used.
- **Directory shard mismatch**: move the package under the directory named by its first letter.
- **A package built from a prebuilt release has no `-bin` suffix**: rename the directory and every binding to
  `<package_name>-bin`; the installed program name is unaffected.
- **Shared build change breaks older versions**: fix `common.nix` and rebuild every declared version.
- **A package cannot be built without a prebuilt tool**: that tool is a bootstrap seed. Mark it with
  `passthru.bootstrapSeed` and binary source provenance, keep it out of the Maven outputs, and use it only to build the
  source artifacts.
- **`pkgs.nmp` is missing**: the overlay was not applied, or a `package.nix` failed to evaluate. Evaluating
  `packages.<system>` first runs the same discovery and validation code.

## Git hygiene

- Commit `flake.nix`, `flake.lock`, `overlay.nix`, and package files together in focused changes.
- Do not commit generated `result` symlinks or build output.
- Do not edit `flake.lock` by hand; use `nix flake update` when updating inputs.
- Do not vendor upstream jars/POMs, dependency caches, or `~/.m2` into the repository. Generated POMs belong to the
  build output, not the source tree.
