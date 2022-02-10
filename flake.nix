{
  description = "Cardano Node";

  inputs = {
    # IMPORTANT: report any change to nixpkgs channel in nix/default.nix:
    nixpkgs.follows = "haskellNix/nixpkgs-2105";
    haskellNix = {
      url = "github:input-output-hk/haskell.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    utils.url = "github:numtide/flake-utils";
    iohkNix = {
      url = "github:input-output-hk/iohk-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    membench = {
      url = "github:input-output-hk/cardano-memory-benchmark";
      inputs.cardano-node-measured.follows = "/";
      inputs.cardano-node-process.follows = "/";
      inputs.cardano-node-snapshot.follows = "/";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Custom user config (default: empty), eg.:
    # { outputs = {...}: {
    #   # Cutomize listeming port of node scripts:
    #   nixosModules.cardano-node = {
    #     services.cardano-node.port = 3002;
    #   };
    # };
    customConfig.url = "github:input-output-hk/empty-flake";
  };

  outputs = { self, nixpkgs, utils, haskellNix, iohkNix, customConfig, membench }:
    let
      inherit (nixpkgs) lib;
      inherit (lib) head systems mapAttrs recursiveUpdate mkDefault
        getAttrs optionalAttrs nameValuePair attrNames;
      inherit (utils.lib) eachSystem mkApp flattenTree;
      inherit (iohkNix.lib) prefixNamesWith;
      removeRecurse = lib.filterAttrsRecursive (n: _: n != "recurseForDerivations");
      flatten = attrs: lib.foldl' (acc: a: if (lib.isAttrs a) then acc // (removeAttrs a [ "recurseForDerivations" ]) else acc) { } (lib.attrValues attrs);

      supportedSystems = import ./nix/supported-systems.nix;
      defaultSystem = head supportedSystems;

      overlays = [
        haskellNix.overlay
        iohkNix.overlays.haskell-nix-extra
        iohkNix.overlays.crypto
        iohkNix.overlays.cardano-lib
        iohkNix.overlays.utils
        (final: prev: {
          customConfig = recursiveUpdate
            (import ./nix/custom-config.nix final.customConfig)
            customConfig.outputs;
          gitrev = self.rev or "0000000000000000000000000000000000000000";
          commonLib = lib
            // iohkNix.lib
            // final.cardanoLib
            // import ./nix/svclib.nix { inherit (final) pkgs; };
        })
        (import ./nix/pkgs.nix)
      ];

    in
    eachSystem supportedSystems
      (system:
        let
          pkgs = import nixpkgs {
            inherit system overlays;
            inherit (haskellNix) config;
          };
          inherit (pkgs.haskell-nix) haskellLib;
          inherit (haskellLib) collectChecks' collectComponents';
          inherit (pkgs.commonLib) eachEnv environments;

          project = pkgs.cardanoNodeProject;
          projectPackages = haskellLib.selectProjectPackages project.hsPkgs;

          shell = import ./shell.nix { inherit pkgs; };
          devShells = {
            inherit (shell) devops;
            cluster = shell;
            profiled = pkgs.cardanoNodeProfiledProject.shell;
          };

          devShell = shell.dev;

          checks = flattenTree (collectChecks' projectPackages) //
          # Linux only checks:
          (optionalAttrs (system == "x86_64-linux") (
            prefixNamesWith "nixosTests/" (mapAttrs (_: v: v.${system} or v) pkgs.nixosTests)
          ))
          # checks run on default system only;
          // (optionalAttrs (system == defaultSystem) {
            hlint = pkgs.callPackage pkgs.hlintCheck {
              inherit (project.args) src;
            };
          });

          exes = flatten (collectComponents' "exes" projectPackages) // {
            inherit (pkgs) cardano-node-profiled cardano-node-eventlogged cardano-node-asserted tx-generator-profiled locli-profiled db-analyser cardano-ping db-converter;
          } // (flattenTree (pkgs.scripts // {
            # `tests` are the test suites which have been built.
            tests = collectComponents' "tests" projectPackages;
            # `benchmarks` (only built, not run).
            benchmarks = collectComponents' "benchmarks" projectPackages;
          }));

          packages = exes
          # Linux only packages:
          // optionalAttrs (system == "x86_64-linux") {
            "dockerImage/node" = pkgs.dockerImage;
            "dockerImage/submit-api" = pkgs.submitApiDockerImage;
            membenches = membench.outputs.packages.x86_64-linux.batch-report;
            snapshot = membench.outputs.packages.x86_64-linux.snapshot;
          }
          # Add checks to be able to build them individually
          // (prefixNamesWith "checks/" checks);

          apps = lib.mapAttrs (n: p: { type = "app"; program = p.exePath or "${p}/bin/${p.name or n}"; }) exes;

        in
        {

          inherit environments packages checks apps;

          legacyPackages = pkgs;

          # Built by `nix build .`
          defaultPackage = packages.cardano-node;

          # Run by `nix run .`
          defaultApp = apps.cardano-node;

          # This is used by `nix develop .` to open a devShell
          inherit devShell devShells;

          hydraJobs = optionalAttrs (system == "x86_64-linux")
            {
              linux = {
                native = packages // {
                  internal.roots.project = project.roots;
                };
                musl =
                  let
                    muslProject = project.projectCross.musl64;
                    projectPackages = haskellLib.selectProjectPackages muslProject.hsPkgs;
                  in
                  flatten (collectComponents' "exes" projectPackages) // {
                    internal.roots.project = muslProject.roots;
                  };
                windows =
                  let
                    windowsProject = project.projectCross.mingwW64;
                    projectPackages = haskellLib.selectProjectPackages windowsProject.hsPkgs;
                  in
                  flatten (collectComponents' "exes" projectPackages)
                  // (removeRecurse {
                    checks = collectChecks' projectPackages;
                    tests = collectComponents' "tests" projectPackages;
                    benchmarks = collectComponents' "benchmarks" projectPackages;
                    internal.roots.project = windowsProject.roots;
                  });
              };
            } // optionalAttrs (system == "x86_64-darwin") {
            macos = packages // {
              internal.roots.project = project.roots;
            };
          };
        }
      ) // {
      overlay = import ./overlay.nix self;
      nixosModules = {
        cardano-node = { pkgs, lib, ... }: {
          imports = [ ./nix/nixos/cardano-node-service.nix ];
          services.cardano-node.cardanoNodePkgs = lib.mkDefault self.legacyPackages.${pkgs.system};
        };
        cardano-submit-api = { pkgs, lib, ... }: {
          imports = [ ./nix/nixos/cardano-submit-api-service.nix ];
          services.cardano-submit-api.cardanoNodePkgs = lib.mkDefault self.legacyPackages.${pkgs.system};
        };
      };
    };
}
