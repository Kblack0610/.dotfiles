# Package Manager Configuration for Arch Linux
PACKAGE_MANAGER="pacman"
PACKAGE_INSTALL_CMD="sudo pacman -S --noconfirm"
PACKAGE_UPDATE_CMD="sudo pacman -Syu --noconfirm"
PACKAGE_SEARCH_CMD="pacman -Ss"
AUR_HELPER="yay"  # or paru

function install_system_settings() {
  echo "Installing system settings"
  #need system settings too
  mkdir -p ~/Media/Pictures
  mkdir -p ~/Media/Videos
  mkdir -p ~/Media/Music

  #delete all unecessary dirs
}

function install_reqs() {
	seconds_to_sleep=1
	exit_code=1
	echo "Installing requirements."
	#Base requirements
	$PACKAGE_UPDATE_CMD &> /dev/null 

  #not necessary but reqs for my tools
	$PACKAGE_INSTALL_CMD vim &> /dev/null
	$PACKAGE_INSTALL_CMD wget &> /dev/null
	$PACKAGE_INSTALL_CMD curl &> /dev/null
	$PACKAGE_INSTALL_CMD fuse2 &> /dev/null
	$PACKAGE_INSTALL_CMD neofetch &> /dev/null


  #Screenshots - maim equivalent on Arch
  $PACKAGE_INSTALL_CMD maim &> /dev/null

	# Node.js installation for Arch
	$PACKAGE_INSTALL_CMD nodejs npm &> /dev/null

	echo "requirements installed"

	sleep "$seconds_to_sleep"
	return "$exit_code"
}

function install_tools() {
	echo "Installing tools"

	#install tools
	$PACKAGE_INSTALL_CMD autojump &> /dev/null
	$PACKAGE_INSTALL_CMD glances &> /dev/null

	$PACKAGE_INSTALL_CMD rofi &> /dev/null
	echo "tools installed"
}

function install_git() {
	echo "Installing git"

	#install git
	$PACKAGE_INSTALL_CMD git &> /dev/null
	git config --global user.name Kenneth 
	git config --global user.email kblack0610@gmail.com
	git config --global credential.helper store

	if [ ! -f ~/.ssh/id_ed25519 ]; then
		echo "git ssh doesn't exists, downloading"
		cp ~/tmp/git_ssh ~/.ssh/id_ed25519 && \
		ssh-keygen -t ed25519 -C "kblack0610@example.com" && \
		eval "$(ssh-agent -s)" && \
		ssh-add ~/.ssh/id_ed25519 && \
		echo "git ssh installed"
	else
		echo "git ssh already exists"
	fi

	echo "git installed"
}

function install_nerd_fonts() {
  declare -a fonts=(
      Hack
      SymbolsOnly
      # BitstreamVeraSansMono
      # CodeNewRoman
      # DroidSansMono
      # FiraCode
      # FiraMono
      # Go-Mono
      # Hermit
      # Meslo
      # Noto
      # Overpass
      # ProggyClean
      # RobotoMono
      # SourceCodePro
      # SpaceMono
      # Ubuntu
      # UbuntuMono
  )

  version='2.1.0'
  fonts_dir="${HOME}/.local/share/fonts"

  if [[ ! -d "$fonts_dir" ]]; then
      mkdir -p "$fonts_dir"
  fi

  for font in "${fonts[@]}"; do
      zip_file="${font}.zip"
      download_url="https://github.com/ryanoasis/nerd-fonts/releases/download/v${version}/${zip_file}"
      echo "Downloading $download_url"
      wget "$download_url"
      unzip "$zip_file" -d "$fonts_dir"
      rm "$zip_file"
  done

 find "$fonts_dir" -name '*Windows Compatible*' -delete

  cd ~/.dotfiles

  stow .
  
  fc-cache -fv
}

function install_prompt_reqs() {
	echo "Installing prompt requirements"
	#bash requirements
	$PACKAGE_INSTALL_CMD cowsay &> /dev/null
	$PACKAGE_INSTALL_CMD fortune-mod &> /dev/null
	$PACKAGE_INSTALL_CMD feh &> /dev/null
	echo "prompt requirements installed"
}

function install_zsh() {
	echo "Installing zsh"
	if ! command -v zsh &> /dev/null 
	then 
		echo "zsh could not be found, installing" 
		#install zsh
		$PACKAGE_INSTALL_CMD zsh &> /dev/null
	  echo "zsh installed"
	else
		echo "zsh already installed"
	fi

  if(echo $SHELL | grep bash); then
		echo "zsh not default shell, setting"
	  #set zsh as default shell
    chsh -s $(which zsh)
  fi
} 

function install_starship() {
	echo "Installing starship"
	if ! command -v starship &> /dev/null 
	then 
		echo "starship could not be found, installing" 
		#install starship
		curl -sS https://starship.rs/install.sh | sh
	  echo "starship installed"
	else
		echo "starship already installed"
	fi
}

function install_oh_my_zsh() {
	echo "Installing oh-my-zsh"
	if [ ! -d ~/.oh-my-zsh ]; then
		echo "oh-my-zsh could not be found, installing" 
		#install oh-my-zsh
		sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
		# install zsh-autosuggestions
		git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
	  echo "oh-my-zsh installed"
	else
		echo "oh-my-zsh already installed"
	fi
}

function install_kitty() {
	echo "Installing kitty"
	if ! command -v kitty &> /dev/null 
	then 
		echo "kitty could not be found, installing" 
		#install kitty - Arch has it in official repos
		$PACKAGE_INSTALL_CMD kitty &> /dev/null
	  echo "kitty installed"
	else
		echo "kitty already installed"
	fi
}

function install_lazygit(){
	echo 'Install lazygit'

	# Lazygit is available in Arch repos
	$PACKAGE_INSTALL_CMD lazygit &> /dev/null
	echo "Lazygit installed"
}

function install_flatpak(){
	echo "Installing flatpak"
	$PACKAGE_INSTALL_CMD flatpak &> /dev/null
	flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

	echo "flatpak installed"
}

function install_nvim(){
	echo "Installing nvim"

	#neovim requirements
  $PACKAGE_INSTALL_CMD base-devel cmake unzip ninja tree-sitter &> /dev/null
	$PACKAGE_INSTALL_CMD ripgrep &> /dev/null  
	$PACKAGE_INSTALL_CMD fzf &> /dev/null
	$PACKAGE_INSTALL_CMD xsel &> /dev/null

  # Install neovim from official repos (Arch usually has latest)
	$PACKAGE_INSTALL_CMD neovim &> /dev/null

	echo "nvim installed"
}

function install_tmux(){
  $PACKAGE_INSTALL_CMD tmux &> /dev/null
	echo "tmux installed"
}

# going back to firefox on linux
function install_browser(){
	echo "Installing firefox browser"
	if ! command -v firefox &> /dev/null 
	then 
		echo "browser could not be found, installing" 
		$PACKAGE_INSTALL_CMD firefox &> /dev/null
	  echo "browser installed"
	else
		echo "browser already installed"
	fi
}

function install_stow(){
	echo "Installing stow"
	#install stow
	$PACKAGE_INSTALL_CMD stow &> /dev/null
	echo "stow installed"
}	

# function install_dotfiles(){
# 	echo "Installing dotfiles"
# 	#install dotfiles
# 	# if [ ! -f ~/.zshrc ] && [ ! -f ~/.config/i3/config ]; then
# 		echo "dotfiles not stowed, installing"
# 		rm -f ~/.bashrc
# 		rm -f ~/.config/i3/config
# 		rm -f ~/.zshrc
# 		# git clone git@github.com:Kblack0610/.dotfiles.git ~/.dotfiles 
# 		cd ~/.dotfiles
# 		stow . 
# 	  echo "dotfile installed"
# 	# else
# 		# echo "dotfiles already installed"
# 	# fi
# }

# function install_aur_helper(){
# 	echo "Installing AUR helper (yay)"
# 	if ! command -v yay &> /dev/null 
# 	then 
# 		echo "yay could not be found, installing" 
# 		cd /tmp
# 		git clone https://aur.archlinux.org/yay.git
# 		cd yay
# 		makepkg -si --noconfirm
# 		cd ~/.dotfiles
# 	  echo "yay installed"
# 	else
# 		echo "yay already installed"
# 	fi
# } 
