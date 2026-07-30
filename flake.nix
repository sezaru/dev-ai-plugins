{
  description = "dev-ai-plugins — dependency environments for the marketplace plugins";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (nixpkgs) lib;

    systems = ["x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin"];
    forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});

    pluginsDir = ./plugins;

    # Auto-discover plugins that declare their deps in `plugins/<name>/nix/deps.nix`.
    # Adding a plugin (or a deps.nix) needs no edit here — its `<name>-deps` package
    # appears automatically.
    pluginNames = let
      entries = builtins.readDir pluginsDir;
    in
      builtins.filter
      (name:
        entries.${name}
        == "directory"
        && builtins.pathExists (pluginsDir + "/${name}/nix/deps.nix"))
      (builtins.attrNames entries);

    depsFor = pkgs: name: import (pluginsDir + "/${name}/nix/deps.nix") pkgs;
  in {
    # Per-plugin dependency bundles + an aggregate `default` with every plugin's deps.
    # Enable a plugin's deps by adding its `<name>-deps` package to your devenv/home config.
    packages = forAllSystems (pkgs: let
      perPlugin = builtins.listToAttrs (map (name: {
          name = "${name}-deps";
          value = pkgs.buildEnv {
            name = "${name}-deps";
            paths = depsFor pkgs name;
          };
        })
        pluginNames);

      allDeps = pkgs.buildEnv {
        name = "dev-ai-plugins-all-deps";
        paths = builtins.concatLists (map (depsFor pkgs) pluginNames);
      };
    in
      perPlugin // {default = allDeps;});

    # `nix develop` → a shell with every plugin's deps on PATH.
    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        packages = builtins.concatLists (map (depsFor pkgs) pluginNames);
      };
    });

    # Programmatic access for consumers who want to compose deps themselves.
    lib = {
      inherit pluginNames;
      depsFor = system: name: depsFor nixpkgs.legacyPackages.${system} name;
    };

    formatter = forAllSystems (pkgs: pkgs.alejandra);
  };
}
