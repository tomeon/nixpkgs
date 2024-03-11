{ lib
, fetchFromGitHub
, rustPlatform
}:
let
  pname = "docuum";
  version = "0.23.1";
in
rustPlatform.buildRustPackage {
  inherit pname version;

  src = fetchFromGitHub {
    owner = "stepchowfun";
    repo = pname;
    rev = "v${version}";
    hash = "sha256-jZJkI4rk/8O6MsHjuDqmIiRc1LJpTajk/rSUVYnHiOs=";
  };

  cargoHash = "sha256-qBigfW0W3t0a43y99H22gmKBnhsu08Yd1CTTatsRfRs=";

  # Some tests expect colorization to be disabled:
  # https://github.com/stepchowfun/docuum/blob/bba67a172b707bbad732bcac03231850d5be8b9d/src/format.rs#L28
  # Upstream code that runs the test suite does this by setting the `NO_COLOR`
  # environment variable:
  # https://github.com/stepchowfun/docuum/blob/bba67a172b707bbad732bcac03231850d5be8b9d/toast.yml#L151-L153
  # https://github.com/stepchowfun/docuum/blob/bba67a172b707bbad732bcac03231850d5be8b9d/.github/workflows/ci.yml#L100
  # https://github.com/stepchowfun/docuum/blob/bba67a172b707bbad732bcac03231850d5be8b9d/.github/workflows/ci.yml#L107
  preCheck = ''
    export NO_COLOR=true
  '';

  meta = {
    description = "Least-recently-used (LRU) eviction of Docker images";
    homepage = "https://github.com/stepchowfun/docuum";
    license = lib.licenses.mit;
    mainProgram = "docuum";
    maintainers = [ lib.maintainers.tomeon ];
  };
}
