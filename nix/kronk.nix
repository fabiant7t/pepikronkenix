{ lib
, buildGoModule
, fetchFromGitHub
, makeWrapper
, libffi
, stdenv
}:

buildGoModule rec {
  pname = "kronk";
  version = "1.23.7";

  src = fetchFromGitHub {
    owner = "ardanlabs";
    repo = "kronk";
    rev = "v${version}";
    hash = "sha256-kEGi5nxEEigS5zfokBOa2cCFLSEh3EVaZkzqe+SJTfk=";
  };

  vendorHash = "sha256-0urdQuVhVN1iMo5/KTPdl2FqDXCuYj4WSaKq8fT1c+o=";

  subPackages = [ "cmd/kronk" ];

  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ libffi ];

  # github.com/jupiterrider/ffi dlopens libffi.so.8 at runtime. The Go
  # binary itself does not record this as an ELF dependency, so make it
  # discoverable from the wrapper.
  postInstall = ''
    wrapProgram $out/bin/kronk \
      --prefix LD_LIBRARY_PATH : ${lib.makeLibraryPath [ libffi stdenv.cc.cc.lib ]}
  '';

  meta = {
    description = "Local LLM inference server with OpenAI-compatible endpoints";
    homepage = "https://github.com/ardanlabs/kronk";
    license = lib.licenses.asl20;
    mainProgram = "kronk";
    platforms = lib.platforms.linux;
  };
}
