{ newScope, dwnConfig, clojureLib, lib, writeText }:
let
  callPackage = newScope thisns;
  mkUnits = callPackage ./src/systemd/gen.nix { };
  thisns = clojureLib // rec {
    inherit dwnConfig callPackage;
    inherit (dwnConfig) devMode;
    inherit (leiningenLib) fromLein;

    callProject = project: args:
      # (callPackage project args) (dwnConfig.binder or clojureLib.shellBinder);
      lib.warn "DEPRECATED usage of callProject, just use callPackage"
               (callPackage project args);

    clojure = callPackage ./build-clojure.nix { };
    leiningenLib = callPackage ./src/nix/lib/leiningen.nix {};

    dwn = callPackage ./project.nix { };
    dwnSystemd = callPackage ./src/systemd {
      dwnLauncher = dwn.meta.dwn.launchers.boot;
      inherit (dwnConfig) varDirectory;
    };
    nrepl = callPackage ./nrepl-project.nix {
      inherit (dwn.meta.dwn) providedVersions;
    };
    leinReader = callPackage ./lein.reader/project.nix { devMode = false; };
    deps = {
      expander = callPackage ./deps.expander { devMode = false; };
      aether = callPackage ./deps.aether { devMode = false; };
    };
    juds = callPackage ./juds.nix {};
    descriptors = lib.listToAttrs (map (name:
        lib.nameValuePair
          name
          (writeText name
            (lib.getAttr name thisns).meta.dwn.descriptor))
      [ "dwn" "nrepl" ]);
    dwnTool = callPackage ./dwn-tool.nix {};
    sysTD = let
        launcher = dwn.meta.dwn.launchers.boot;
        socket = "${dwnConfig.varDirectory}/dwn.socket";
    in mkUnits {
      services = {
        dwn = {
          description = "`dwn` clojure runner";
          serviceConfig = {
            Type="simple";
            ExecStart="${launcher} ${socket}";
            ExecPostStart="/bin/sh -c 'while [ ! -S ${socket} ]; do sleep 0.2; done'";
          };
        };
      };
    };
  };
in thisns
