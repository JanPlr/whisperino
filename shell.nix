{ pkgs ? import <nixpkgs> {} }:

# Darwin/nix-darwin host. Swift and the Apple SDK come from Xcode CLT
# (`xcode-select --install`); Nix cannot ship a working Metal toolchain.
pkgs.mkShell {
  name = "whisperino";
  packages = with pkgs; [
    git
    curl
    cmake
    ninja
    python3
  ];

  shellHook = ''
    echo "Whisperino dev shell"
    echo "  Swift: $(swift --version 2>/dev/null | head -1 || echo 'missing — install Xcode CLT')"
    echo "  First build downloads transcribe.cpp's Metal xcframework via SwiftPM."
    echo "  Speech models download from Hugging Face the first time you pick them in the app."
  '';
}
