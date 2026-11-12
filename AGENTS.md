# AGENTS.md

## Purpose

This repository packages Scala/JVM projects and their build inputs as Nix derivations. The primary goal is to build
these projects **fully offline**: the build and install phases must never resolve dependencies from Maven Central or any
other network repository.

The repository is managed as one Nix flake. A package declaration lives at
`by_name/<alphabet>/<package_name>/package.nix`.

The non-negotiable rules:

1. A package declaration lives at `by_name/<alphabet>/<package_name>/package.nix`.
2. A `package.nix` may declare multiple versions. It must evaluate to an attrset mapping raw upstream versions to
   derivations. Always design for adding more versions.
3. `flake.nix` discovers packages and versions automatically. Do not maintain a manual list anywhere.
4. Builds must be hermetic and offline. Do not add steps that contact Maven Central or another package repository.

## Repository layout

```
flake.nix
flake.lock
by_name/
  <alphabet>/
    <package_name>/
      package.nix          # required
      common.nix           # optional: build logic shared by all versions
      patches/             # optional
      scripts/             # optional
```

Example:

```
by_name/
  j/
    jackson-core/
      package.nix
      common.nix
```

A package directory may expose several versions. For example, the `jackson-core` declaration may expose
`jackson-core_2_17_0` and `jackson-core_2_23_0`.

### Naming rules

- `<package_name>` is the package identity. It is lowercase kebab-case.
- `<alphabet>` is the first character of `<package_name>`, lowercased. For example, `jackson-core` lives in
  `by_name/j/jackson-core/package.nix`.
- The public binding for a versioned package is `<package_name>_<sanitized_version>`, where every `.` in the version is
  replaced by `_`. Other characters are preserved, so date-style versions such as `2024-01-01` keep their form.
  - `2.23.0` becomes `jackson-core_2_23_0`
  - `1.0.0-RC1` becomes `jackson-core_1_0_0-RC1`
  - `2024-01-01` becomes `jackson-core_2024-01-01`
- The keys of the `package.nix` attrset are these public binding names. The derivation value stores the raw upstream
  version, for example key `"jackson-core_2_23_0"` with `version = "2.23.0";`.
- Binding names must be unique across the repository. A collision is an error, not something to resolve by ordering.
- Each derivation's `version` must match the version suffix in its binding key, and its `pname` should be the package
  directory name so Nix derivation names stay predictable.

### Package directory contents

- Exactly one `package.nix` per package directory. Do not use `default.nix`; the flake discovery only looks for
  `package.nix`.
- Additional files local to the package are allowed: `common.nix`, patches, wrapper scripts, fixture files, and so on.
- Packages must be self-contained. Do not reach into another package's directory. If shared logic is truly needed, add
  it under a top-level `lib/` and document it in this file first.
- Do not vendor jars, POMs, `~/.m2` contents, or build outputs.

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
- `package.nix` lists every version and passes only the version-specific inputs, usually `version`, `src`, and patches.

This keeps the build procedure in one place while making each supported version explicit. Keep the
`do not use default.nix` rule: the entry point is always `package.nix`.

## Multiple versions

Always assume more versions will be added later.

- Add a new version as a new entry in the `package.nix` attrset.
- Reuse `common.nix` rather than copying the whole build procedure.
- Only repeat version-specific details: source, patches, and flags that genuinely differ.
- Do not remove an existing version unless the user explicitly asks.
- If shared build logic changes, rebuild every version, not just the one you were working on.

## Build implementation

The concrete build strategy for Scala/JVM projects is still under investigation. Do not lock the repository into a Maven
Central-dependent flow yet.

Until that investigation is complete:

- Do not assume Maven Central, sbt repositories, or any online artifact repository is available during the build.
- Do not make `mvnHash`-style Maven Central dependency fetching the build strategy.
- Dependencies must be pinned and available from Nix-provided inputs or a pinned offline cache.
- Source fetching through Nix fixed-output fetchers is fine; dependency resolution during `buildPhase` or `installPhase`
  is not.
- Keep build logic shared in `common.nix` so the eventual offline strategy can be applied to every version.

## Reference `package.nix`

This example declares two versions and reuses one build function. Replace the placeholder build body with the offline
implementation once the build strategy is decided.

```nix
{
  pkgs,
  ...
}:

let
  buildVersion =
    { version, src }:
    pkgs.stdenv.mkDerivation {
      pname = "jackson-core";
      inherit version src;

      # Offline build implementation goes here. This must not contact Maven
      # Central or any other network repository.
      # ...
    };
in
{
  "jackson-core_2_23_0" = buildVersion {
    version = "2.23.0";
    src = pkgs.fetchFromGitHub {
      owner = "FasterXML";
      repo = "jackson-core";
      tag = "jackson-core-2.23.0";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
  };

  "jackson-core_2_17_0" = buildVersion {
    version = "2.17.0";
    src = pkgs.fetchFromGitHub {
      owner = "FasterXML";
      repo = "jackson-core";
      tag = "jackson-core-2.17.0";
      hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    };
  };
}
```

If the shared build function grows, move `buildVersion` into `common.nix`:

```nix
# common.nix
{ pkgs }:
{ version, src }:
pkgs.stdenv.mkDerivation {
  pname = "jackson-core";
  inherit version src;

  # Offline build implementation goes here.
}
```

Then import it from `package.nix`:

```nix
{
  pkgs,
  ...
}:

let
  buildVersion = import ./common.nix { inherit pkgs; };
in
{
  # "<package_name>_<sanitized_version>" entries...
}
```

## Flake contract

The flake must:

- Discover every `by_name/*/*/package.nix` without a hand-written list.
- Validate that the first directory under `by_name/` matches the package name's first letter.
- Call each `package.nix` and expect an attrset of public binding name to derivation.
- Expose those bindings directly as `packages.<system>."<package_name>_<sanitized_version>"`.
- Reject binding keys that do not start with `<package_name>_`.
- Not expose an unversioned alias; a package may have several concurrent versions.
- Fail on duplicate binding names.
- Keep `flake.lock` committed.
- Gate unfree packages behind the `NIXPKGS_ALLOW_UNFREE` environment variable.

Reference `flake.nix`:

```nix
{
  description = "Offline Nix builds for Scala/JVM projects";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      forAllSystems = lib.genAttrs systems;

      packageFiles =
        let
          root = ./by_name;
        in
        if builtins.pathExists root then
          builtins.filter
            (path: builtins.baseNameOf (toString path) == "package.nix")
            (lib.filesystem.listFilesRecursive root)
        else
          [ ];

      packageName = path: builtins.baseNameOf (builtins.dirOf (toString path));
      packageShard = path:
        builtins.baseNameOf (builtins.dirOf (builtins.dirOf (toString path)));

      packagesFor =
        pkgs:
        let
          versionSets = map
            (
              path:
              let
                name = packageName path;
                expectedShard = builtins.substring 0 1 name;
                actualShard = packageShard path;
                versions = pkgs.callPackage path { inherit pkgs; };
                invalidNames = builtins.filter
                  (binding: !(lib.hasPrefix "${name}_" binding))
                  (builtins.attrNames versions);
              in
              if actualShard != expectedShard then
                throw "by_name: ${name} must be in by_name/${expectedShard}/${name}, found by_name/${actualShard}/${name}"
              else if invalidNames != [ ] then
                throw "package ${name}: bindings must be named ${name}_<sanitized_version>, got: ${lib.concatStringsSep ", " invalidNames}"
              else
                versions
            )
            packageFiles;

          allNames = builtins.concatMap builtins.attrNames versionSets;
          duplicates = lib.unique (
            builtins.filter (name: lib.count (other: other == name) allNames > 1) allNames
          );
        in
        if duplicates != [ ] then
          throw "duplicate package bindings: ${lib.concatStringsSep ", " duplicates}"
        else
          lib.mergeAttrsList versionSets;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = builtins.getEnv "NIXPKGS_ALLOW_UNFREE" == "1";
          };
        in
        packagesFor pkgs
      );

      formatter = forAllSystems (
        system: (import nixpkgs { inherit system; }).nixfmt-rfc-style
      );
    };
}
```

Bindings are accessed by their full name:

```sh
nix build '.#"jackson-core_2_23_0"'
nix build '.#"jackson-core_2_17_0"'
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

1. Pick `<package_name>` from the upstream artifact and confirm its first letter. Create
   `by_name/<alphabet>/<package_name>/package.nix`.
2. Identify the versions to support and how the build can obtain all dependencies without Maven Central or other network
   access.
3. Implement the offline build. Use `common.nix` if the procedure will be shared by multiple versions.
4. Write `package.nix` as an attrset of versioned binding name to derivation. Include at least one version entry.
5. Pin every source and fixed-output input with a hash. Bootstrap any hash from the Nix build error (`got:` value);
   never guess it.
6. Build every exposed binding, not just the newest version.
7. Run the validation commands below and commit.

## Adding a version to an existing package

1. Add a new versioned binding key to `package.nix` with a call to the shared build function.
2. Pass only the version-specific inputs: `version`, `src`, patches, and flags.
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
- [ ] The build and install phases do not access Maven Central or any other network service.
- [ ] Every fixed-output hash was generated from a Nix build, not guessed.
- [ ] Adding another version would only require a new entry and version-specific inputs.
- [ ] Unfree packages were explicitly requested and are gated by `NIXPKGS_ALLOW_UNFREE`.
- [ ] `nix flake check` and `nix fmt` pass.
- [ ] No `result` symlink, build output, or vendored dependency is committed.

## Troubleshooting

- **Hash mismatch on a fetched input**: update the hash with the `got:` value from the error. Do not use `--no-check`.
- **The build tries to reach Maven Central or another repository**: make the build offline. Add the required input to
  Nix or a pinned offline cache; do not weaken the sandbox.
- **A declared version is missing from `packages`**: check that it is a key in the `package.nix` attrset, and that the
  resulting binding name does not collide.
- **Binding name is wrong**: only `.` is replaced with `_`. Hyphens and date separators are preserved.
- **The flake rejects an unfree package**: the package was not explicitly requested, or `NIXPKGS_ALLOW_UNFREE=1` and
  `--impure` were not used.
- **Directory shard mismatch**: move the package under the directory named by its first letter.
- **Shared build change breaks older versions**: fix `common.nix` and rebuild every declared version.

## Git hygiene

- Commit `flake.nix`, `flake.lock`, and package files together in focused changes.
- Do not commit generated `result` symlinks or build output.
- Do not edit `flake.lock` by hand; use `nix flake update` when updating inputs.
- Do not vendor dependency caches or `~/.m2` into the repository.
