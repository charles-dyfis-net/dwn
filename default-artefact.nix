((import <nixpkgs> {}).callPackage ./src/nix/lib/clojure.nix {})
.callPackage ./artefact.nix {}
