class Maclidawake < Formula
  desc "Keep a closed-lid MacBook running temporarily, then restore sleep"
  homepage "https://github.com/EdgarZhong/MacLidAwake"
  license "MIT"

  url "https://github.com/EdgarZhong/MacLidAwake/releases/download/v1.0.0/maclidawake-v1.0.0-macos.tar.gz"
  sha256 "a536d01952a01d408ac36cc4d663047374d8615da3bed03b2c283095b006aa72"

  depends_on macos: :ventura

  def install
    bin.install "lidgo"
    zsh_completion.install "_lidgo"
  end

  test do
    assert_match "MacLidAwake", shell_output("#{bin}/lidgo help")
  end
end
