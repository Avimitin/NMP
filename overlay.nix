# Overlay exposing the NMP package set inside an existing nixpkgs instance.
#
# Usage:
#
#   import nixpkgs { overlays = [ (import ./overlay.nix) ]; }
#
# Each declared version is then available as `pkgs.nmp.<binding>`, where
# `<binding>` is `<package_name>_<sanitized_version>`.
#
# The overlay deliberately exposes a single `nmp` namespace instead of merging
# the bindings into the top level. A Nix overlay's attribute names must be known
# without evaluating any package, and these bindings are only discoverable by
# calling each `package.nix`, so a flattened overlay would recurse infinitely.
#
# Discovery, shard validation, binding-name validation and duplicate detection
# all live here so the flake and downstream consumers share one implementation.
final: prev:

let
  lib = prev.lib;

  root = ./by_name;

  packageFiles =
    if builtins.pathExists root then
      builtins.filter (path: builtins.baseNameOf (toString path) == "package.nix") (
        lib.filesystem.listFilesRecursive root
      )
    else
      [ ];

  packageName = path: builtins.baseNameOf (builtins.dirOf (toString path));
  packageShard = path: builtins.baseNameOf (builtins.dirOf (builtins.dirOf (toString path)));

  versionsFor =
    path:
    let
      name = packageName path;
      expectedShard = builtins.substring 0 1 name;
      actualShard = packageShard path;
      # `callPackage` injects `override`, `overrideDerivation` and
      # `overrideAttrs` into the returned attrset. They are not package bindings.
      versions = removeAttrs (final.callPackage path { }) [
        "override"
        "overrideDerivation"
        "overrideAttrs"
      ];
      invalidNames = builtins.filter (binding: !(lib.hasPrefix "${name}_" binding)) (
        builtins.attrNames versions
      );
    in
    if actualShard != expectedShard then
      throw "by_name: ${name} must be in by_name/${expectedShard}/${name}, found by_name/${actualShard}/${name}"
    else if invalidNames != [ ] then
      throw "package ${name}: bindings must be named ${name}_<sanitized_version>, got: ${lib.concatStringsSep ", " invalidNames}"
    else
      versions;

  versionSets = map versionsFor packageFiles;

  allNames = builtins.concatMap builtins.attrNames versionSets;
  duplicates = lib.unique (
    builtins.filter (name: lib.count (other: other == name) allNames > 1) allNames
  );
in
{
  nmp =
    if duplicates != [ ] then
      throw "duplicate package bindings: ${lib.concatStringsSep ", " duplicates}"
    else
      lib.mergeAttrsList versionSets;
}
