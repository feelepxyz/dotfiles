# dotfiles

```bash
git clone https://github.com/feelepxyz/dotfiles.git ~/.dotfiles && cd ~/.dotfiles
STRAP_GIT_NAME='name' STRAP_GIT_EMAIL='email' STRAP_GITHUB_USER='user' script/strap
```

## Manual setup (for now)

- [ ] Open iTerm and install the theme

```bash
open $HOME/.dotfiles/iterm/Solarized\ Dark.itermcolors
```

- [ ] Trust the gpg key

```bash
gpg --edit-key $KEYID
```

- [ ] Sign in to the 1Passsword app
- [ ] Extract files from 1Passsword

```
$HOME/.dotfiles/scripts/extract-onepassword-secrets
```

- [ ] Sign in to the App Store
- [ ] Install apps from the App store `brew bundle --file ~/.Brewfile.mas`
- [ ] Save `~/Desktop/FileVault\ Recovery\ Key.txt` in 1Passsword
- [ ] Create a work and personal profile in Chrome
- [ ] Sign in to Google Drive
- [ ] Sign in to Dropbox
- [ ] Sign in to Todoist
- [ ] Sign in to Slack
- [ ] Configure screen sharing in zoom
- [ ] Configure keyboard shortcut in Raycast
- [ ] Configure Dropshare with Drive
- [ ] Open vaults in Obsidian
- [ ] Open Docker to install cli tools
- [ ] Sign in to GitHub in VSCode and sync settings
- [ ] Open Apple Music and point library to Drive folder by alt-clicking on the app
- [ ] Setup apps in Dock
    - [ ] Chrome
    - [ ] VSCode
    - [ ] iTerm
    - [ ] Obsidian
    - [ ] Todoist
    - [ ] Spotify
    - [ ] Music
- [ ] Setup work vpn
