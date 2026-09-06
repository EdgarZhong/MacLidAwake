class Maclidawake < Formula
  desc "Keep a closed-lid MacBook running temporarily, then restore sleep"
  homepage "https://github.com/EdgarZhong/MacLidAwake"
  license "MIT"

  # HEAD-only until the first tagged release. Add a release URL and verified
  # sha256 here when v0.1.0 is published.
  head "https://github.com/EdgarZhong/MacLidAwake.git", branch: "main"

  depends_on macos: :ventura

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/lidgo"
    zsh_completion.install "completions/_lidgo"
  end

  test do
    assert_match "MacLidAwake", shell_output("#{bin}/lidgo help")
  end
end
