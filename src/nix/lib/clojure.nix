{ stdenv, newScope, jdk, lib, writeScript, writeText, fetchurl, runCommand
, copyPathToStore }:

let callPackage = newScope thisns;
    lib' = lib // {
      types = lib.types // {
        symbol = lib.mkOptionType {
          name = "symbol";
          merge = lib.mergeOneOption;
          check = s: ! lib.hasPrefix ":" s;
        };
        keyword = lib.mkOptionType {
          name = "keyword";
          merge = lib.mergeOneOption;
          check = lib.hasPrefix ":";
        };
      };
    };
    thisns = { inherit callPackage; } // rec {
  defaultMavenRepos = [ http://repo1.maven.org/maven2
                        https://clojars.org/repo ];
  dwn = callPackage ./dwn.nix {};
  edn = callPackage ./edn.nix {};

  inherit (edn) asEdn toEdn toEdnPP;
  inherit (edn.syntax) tagged hash-map keyword-map list vector set symbol keyword string int bool nil;
  inherit (edn.data) get get-in eq nth nix-str nix-list extract;

  inherit (callPackage ./compile.nix {}) jvmCompile cljCompile;

  lib = lib';

  shellBinder = rec {

    classLauncher = { name, classpath, class, jvmArgs ? []
                    , prefixArgs ? [], suffixArgs ? [], debug ? false }:
      writeScript name ''
        #!/bin/sh
        ${if debug then "set -vx" else ""}
        exec ${jdk.jre}/bin/java \
          -cp ${renderClasspath classpath} \
          ${toString jvmArgs} \
          ${class} \
          ${toString prefixArgs} \
          "$@" ${toString suffixArgs}
      '';

    scriptLauncher = { name, classpath, codes, jvmArgs ? [], debug ? false }:
      classLauncher {
        inherit name classpath jvmArgs debug;
        class = "clojure.main";
        prefixArgs = [ "-e" ''
          "$(cat <<CLJ62d3c200-34d4-49e5-a64d-f6eaf59b4715
          ${lib.concatStringsSep "\n\n;; ----\n\n" codes}
          CLJ62d3c200-34d4-49e5-a64d-f6eaf59b4715
          )"
        '' ];
      };

    mainLauncher = { name, classpath, namespace, jvmArgs ? []
                   , prefixArgs ? [], suffixArgs ? [], debug ? false }:
      classLauncher {
        inherit name classpath jvmArgs suffixArgs debug;
        class = "clojure.main";
        prefixArgs = [ "-m" namespace ] ++ prefixArgs;
      };

  };

  descriptorPaths = desc:
    let pkg = lib.elemAt desc 2;
    in if pkg == "dirs"
      then lib.elemAt desc 5
      else if pkg == "jar"
      then [ (lib.elemAt desc 5) ]
      else throw "Unknown packaging '${pkg}'";

  classesFor = args@{
      name
    , cljSourceDirs ? []
    , javaSourceDirs ? []
    , resourceDirs ? []
    , aot ? []
    , compilerOptions ? {}
    , providedVersions ? []
    , ...
  }: let
    baseClasspath = resourceDirs ++ dependencyClasspath args ++ (
      lib.concatLists (map descriptorPaths providedVersions)
    );
    javaClasses = if lib.length javaSourceDirs > 0
      then [ (jvmCompile {
        name = name + "-java-classes";
        classpath = baseClasspath;
        sources = javaSourceDirs;
      }) ] else [];
    cljClasses = if (lib.length cljSourceDirs > 0) && (lib.length aot > 0)
      then [ (cljCompile {
        name = name + "-clj-classes";
        classpath = cljSourceDirs ++ javaSourceDirs ++ javaClasses ++ baseClasspath;
        inherit aot;
        options = compilerOptions;
      }) ] else [];
  in cljClasses ++ javaClasses;

  artifactClasspath = args@{
      cljSourceDirs ? []
    , resourceDirs ? []
    , devMode ? false
    , ...
  }:   (map (sourceDir devMode) cljSourceDirs)
    ++ (classesFor args)
    ++ (map (sourceDir devMode) resourceDirs);

  classpathFor = args: artifactClasspath args ++ dependencyClasspath args;

  expandDependencies = { name
                       , dependencies ? []
                       , overlayRepo ? {}
                       , fixedVersions ? []
                       , providedVersions ? []
                       , fixedDependencies ? null # bootstrap hack
                       , closureRepo ? throw "Please pre-generate the repository add attribute `closureRepo = ./repo.edn;` to project `${name}`"
                       , ... }:
    let expDep = depsExpander
           closureRepo dependencies fixedVersions providedVersions overlayRepo; in
    if isNull fixedDependencies
    then import expDep #(builtins.trace (toString expDep) expDep)
    else fixedDependencies;

  dependencyClasspath = args@{ mavenRepos ? defaultMavenRepos
                             , ... }:
    lib.concatLists (map (mvnResolve mavenRepos) (expandDependencies args));

  mergeRepos = lib.recursiveUpdate;
  clojureCustom = callPackage ../../../build-clojure.nix {};

  closureRepoGenerator = { dependencies ? []
                         , mavenRepos ? defaultMavenRepos
                         , fixedVersions ? []
                         , overlayRepo ? {}
                         , ... }:
    aetherDownloader
      mavenRepos
      (dependencies ++ fixedVersions)
      overlayRepo;

  aetherDownloader = repos: deps: overlay: writeScript "repo.edn.sh" ''
    #!/bin/sh
    if [ -z "$1" ]; then
      echo "$0 <filename.out.edn>"
      exit 1
    fi
    launcher="${callPackage ../../../deps.aether { devMode = false; }}"
    ednDeps=$(cat <<EDNDEPS
    ${toEdn deps}
    EDNDEPS
    )
    ednRepos=$(cat <<EDNREPOS
    ${toEdn repos}
    EDNREPOS
    )
    ednOverlay=$(cat <<EDNOVERLAY
    ${toEdn overlay}
    EDNOVERLAY
    )
    exec "$launcher" "$1" "$ednDeps" "$ednRepos" "$ednOverlay"
  '';
  depsExpander = repo: deps: fixedVersions: providedVersions: overlayRepo: runCommand "deps.nix" {
    inherit repo;
    ednDeps = toEdn deps;
    ednFixedVersions = toEdn fixedVersions;
    ednProvidedVersions = toEdn providedVersions;
    ednOverlayRepo = toEdn overlayRepo;
    launcher = callPackage ../../../deps.expander { devMode = false; };
  } ''
    #!/bin/sh
    ## set -xv
    exec $launcher $out "$repo" "$ednDeps" "$ednFixedVersions" "$ednProvidedVersions" "$ednOverlayRepo";
  '';

  artifactDescriptor = mavenRepos: args@{ coordinate
                                        , dirs ? null
                                        , ...}:
    coordinate ++ (if "dirs" == lib.elemAt coordinate 2
      then [dirs]
      else mvnResolve mavenRepos args
    );

  projectDescriptor = args@{
                        name
                      , group ? name
                      , version ? "0-SNAPSHOT"
                      , mainNs ? {}
                      , components ? {}
                      , mavenRepos ? defaultMavenRepos
                      , providedVersions ? []
                      , ... }:
                      binder@{
                        parentLoader ? keyword "webnf.dwn" "app-loader"
                      , ...}:
  let containerName = keyword name "container"; in
  keyword-map ({
      "${name}/container" = dwn.container {
        loaded-artifacts = map (artifactDescriptor mavenRepos) ([{
          coordinate = [ group name "dirs" "" version];
          dirs = artifactClasspath args;
        }] ++ expandDependencies args);
        parent-loader = parentLoader;
        provided-versions = providedVersions;
      };
    } // lib.listToAttrs (projectNsLaunchers name containerName mainNs binder
                       ++ projectComponents name containerName components binder));

  projectNsLaunchers = prjName: container: mainNs: { mainArgs ? {}, ... }:
  lib.mapAttrsToList (
      name: ns: {
        name = "${prjName}/${name}";
        value = dwn.ns-launcher {
          inherit container;
          main = symbol null ns;
          args = mainArgs.${name} or [];
        };
      }
  ) mainNs;

  projectComponents = prjName: container: components: { componentConfig ? {}, ... }:
  lib.mapAttrsToList (
      name: { factory, options ? {} }: {
        name = "${prjName}/${name}";
        value = dwn.component {
          inherit factory container;
          config = mkConfig options componentConfig.${name} or {};
        };
      }
  ) components;

  mkConfig = optionsDecl: options: options; ## FIXME validate, fill defaults

  subProjectOverlay = prjs:
    lib.fold mergeRepos {}
      (map (prj: with prj.passthru.dwn; {
                   "${group}"."${artifact}"."${extension}"."${classifier}"."${version}" = {
                     inherit dirs dependencies;
                   };
                 })
           prjs);

  subProjectFixedVersions = prjs:
    (map (prj: with prj.passthru.dwn; [group artifact extension classifier version])
         prjs);

  project = args0@{
              name
            , group ? name
            , version ? "0-SNAPSHOT"
            , extension ? "dirs"
            , classifier ? ""
            , dependencies ? []
            , fixedVersions ? []
            , providedVersions ? []
            , closureRepo ? null
            , overlayRepo ? {}
            , mainNs ? {}
            , jvmArgs ? []
            , mavenRepos ? defaultMavenRepos
            , subProjects ? []
            , ... }:
            { mainLauncher, ... }@binder:
    let
      args = args0 // {
        overlayRepo = mergeRepos (subProjectOverlay subProjects) overlayRepo;
        fixedVersions = fixedVersions ++ subProjectFixedVersions subProjects;
      };
      classpath = classpathFor args;
      launchers = lib.mapAttrs (
          launcherName: nsName:
            mainLauncher {
              inherit classpath jvmArgs;
              name = launcherName;
              namespace = nsName;
            }
        ) mainNs;
      descriptor = toEdnPP (projectDescriptor args binder);
    in stdenv.mkDerivation {
      inherit classpath descriptor;
      name = "${name}-${version}";
      passthru = lib.recursiveUpdate passthru {
        dwn = {
          artifact = name;
          inherit group extension classifier version;
          inherit launchers subProjects;
          inherit mainNs jvmArgs mavenRepos;
          inherit dependencies fixedVersions providedVersions closureRepo;
          expandedDependencies = expandDependencies args;
          dirs = if extension == "dirs" then artifactClasspath args else null;
          jar = if extension == "jar" then throw "Not implemented: ${extension}" else null;
          classes = classesFor args;
        };
      };
      meta.dwn = (lib.warn "Deprecated usage of <project>.meta.dwn ; use <project>.dwn instead" {
        inherit launchers descriptor;
        providedVersions = map (artifactDescriptor mavenRepos) ([{
          coordinate = [ name name "dirs" "" "0" ];
          dirs = artifactClasspath args;
        }] ++ expandDependencies args);
      });
      launcherScripts = lib.attrValues launchers;
      closureRepoGenerator = closureRepoGenerator args;
      buildCommand = ''
        mkdir -p $out/bin $out/share/dwn/classpath
        for l in $launcherScripts; do
          cp $l $out/bin/$(stripHash $l)
        done
        for c in $classpath; do
          local targetOrig=$out/share/dwn/classpath/$(stripHash $c)
          local target=$targetOrig
          local cnt=0
          while [ -L $target ]; do
            target=$targetOrig-$cnt
            cnt=$(( cnt + 1 ))
          done
          ln -s $c $target
        done
        echo "$descriptor" > $out/share/dwn.edn
      '';
    };

  combinePathes = name: pathes: runCommand name { inherit pathes; } ''
    mkdir -p out
    for p in $pathes; do
      cp -nR $p/${"*"} out
      chmod -R +w out
    done
    cp -R out $out
  '';

  sourceDir = devMode: dir:
    if devMode
    then toString dir
    else copyPathToStore dir;

  mvnResolve = mavenRepos: { resolved-version ? null, coordinate, sha1 ? null, dirs ? null, jar ? null, ... }:
    let version = lib.elemAt coordinate 4;
        classifier = lib.elemAt coordinate 3;
        extension = lib.elemAt coordinate 2;
        name    = lib.elemAt coordinate 1;
        group   = lib.elemAt coordinate 0;
    in
    if "dirs" == lib.elemAt coordinate 2 then
      if isNull dirs then throw "Dirs for ${toString coordinate} not found" else dirs
    else if "jar" == lib.elemAt coordinate 2
         && isNull sha1 then
      if isNull jar then throw "Jar file for ${toString coordinate} not found" else [ jar ]
    else [ ((fetchurl {
      name = "${name}-${version}.${extension}";
      urls = mavenMirrors mavenRepos group name extension classifier version
                          (if isNull resolved-version then version else resolved-version);
      inherit sha1;
            # prevent nix-daemon from downloading maven artifacts from the nix cache
    }) // { preferLocalBuild = true; }) ];

  mavenMirrors = mavenRepos: group: name: extension: classifier: version: resolvedVersion: let
    dotToSlash = lib.replaceStrings [ "." ] [ "/" ];
    tag = if classifier == "" then "" else "-" + classifier;
    mvnPath = baseUri: "${baseUri}/${dotToSlash group}/${name}/${version}/${name}-${resolvedVersion}${tag}.${extension}";
  in # builtins.trace "DOWNLOADING '${group}' '${name}' '${extension}' '${classifier}' '${version}' '${resolvedVersion}'"
       (map mvnPath mavenRepos);

  renderClasspath = classpath: lib.concatStringsSep ":" classpath;

};
in thisns
