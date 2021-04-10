# dotfiles

System configuration files I've honed to get my machines to my liking. Much of the work is heavily borrowed from others
that I've come across on GitHub and elsewhere (many thanks goes out to them). These files are primarily focused towards
configuring macOS, however, recently I've made a major effort to automate Linux setup as well.

## 💾 Installation

```shell
$ # I typically run this from the $HOME directory
$ git clone https://github.com/cjhutchi/dotfiles $HOME/.dotfiles
$ cd $HOME/.dotfiles
$ ./bootstrap.sh
```

## 🛠 Tools (Optional)

```shell
$ # I have some optional scripts that add some default software depending on the system
$ # which can be found in the scripts folder.
$
$ # On macOS
$ scripts/install-macos.sh
$
$ # On Linux (only Debian-like for now)
$ scripts/install-linux.sh
```
