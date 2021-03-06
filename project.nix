{ project, callPackage, lib, devMode, juds, clojure }:

project rec {

  name = "webnf.dwn";

  inherit devMode;

  cljSourceDirs = [ ./src/clj ];
  javaSourceDirs = [ ./src/jvm ];

  mainNs = {
    boot = "webnf.dwn.boot";
  };
  aot = lib.optionals (! devMode) [ "webnf.dwn.boot" ];
  compilerOptions = {
    directLinking = true;
    elideMeta = [ ":line" ":file" ":doc" ":added" ];
  };

  dependencies = [
    ["org.clojure" "clojure" "1.9.0-CUSTOM"]
    ["org.clojure" "test.check" "0.9.0"]
    ["org.clojure" "tools.logging" "0.3.1"]
    ["com.stuartsierra" "component" "0.3.2"]
    ["webnf.deps" "logback" "0.2.0-alpha2"]
    ["webnf" "juds" "dirs" "CUSTOM"]
  ];

  overlayRepo = {
    "webnf"."juds"."dirs".""."CUSTOM" = {
      dirs = [ "${juds}/lib" ];
    };
    "org.clojure"."clojure"."jar".""."1.9.0-CUSTOM" = clojure.meta.dwn.repoEntry;
  };

  closureRepo = ./dwn.repo.edn;

}
