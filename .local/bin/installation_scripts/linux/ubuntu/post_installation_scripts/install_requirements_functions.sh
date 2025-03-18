function install_system_settings() {
  echo "Installing system settings"
  #need system settings too
  mkdir ~/Media/Pictures
  mkdir ~/Media/Videos
  mkdir ~/Media/Music

  #delete all unecessary dirs
}

function install_reqs() {
	seconds_to_sleep=1
	exit_code=1
	echo "Installing requirements."
	#Base requirements
	yes | sudo apt update -y &> /dev/null 
	yes | sudo apt upgrade -y &> /dev/null

  #not necessary but reqs for my tools
	yes | sudo apt install vim -y &> /dev/null
	yes | sudo apt install wget -y &> /dev/null
	yes | sudo apt install curl -y &> /dev/null

  yes | sudo apt install libfuse2 &> /dev/null
	yes | sudo apt install neofetch -y &> /dev/null

  #Screenshots
  yes | sudo apt install maim -y &> /dev/null

	curl -fsSL https://deb.nodesource.com/setup_21.x | sudo -E bash - &&\
	sudo apt-get install -y nodejs -y &> /dev/null

	echo "requirements installed"

	sleep "$seconds_to_sleep"
	return "$exit_code"
}


function install_tools() {
	echo "Installing tools"

	#install tools
	yes | sudo apt install autojump -y &> /dev/null
	yes | sudo apt install glances -y &> /dev/null

	echo "tools installed"
}

function install_git() {
	echo "Installing git"

	#install git
	yes | sudo apt install git -y &> /dev/null
	git config --global user.name Kenneth 
	git config --global user.email kblack0610@gmail.com
	git config --global credential.helper store

	if [ ! -f ~/.ssh/id_ed25519 ]; then
		echo "git ssh doesn't exists, downloading"
		cp ~/tmp/git_ssh ~/.ssh/id_ed25519 && \\
		ssh-keygen -t ed25519 -C "kblack0610@example.com" && \\
		eval "$(ssh-agent -s)" && \\
		ssh-add ~/.ssh/id_ed25519 && \\
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
	yes | sudo apt install cowsay -y &> /dev/null
	yes | sudo apt install fortune -y &> /dev/null
	yes | sudo apt install feh -y &> /dev/null
	echo "prompt requirements installed"
}
function install_zsh() {
	echo "Installing zsh"
	if ! command -v zsh &> /dev/null 
	then 
		echo "zsh could not be found, installing" 
		#install zsh
		yes | sudo apt install zsh -y &> /dev/null
	  echo "zsh installed"
	else
		echo "zsh already installed"
	fi
} 

function install_starship() {
	echo "Installing starship"
	if ! command -v starship &> /dev/null 
	then 
		echo "starship could not be found, installing" 
		#install starship
		yes | curl -sS https://starship.rs/install.sh | sh
	  echo "starship installed"
	else
		echo "starship already installed"
	fi
}

function install_oh_my_zsh() {
	echo "Installing oh-my-zsh"
	if ! command -v zsh &> /dev/null 
	then 
		echo "oh-my-zsh could not be found, installing" 
		#install oh-my-zsh
		sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
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
		#install kitty
		curl -l https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin 
		yes | mkdir ~/.local/bin
		# -- desktop integration for kitty
		# create symbolic links to add kitty and kitten to path (assuming ~/.local/bin is in
		# your system-wide path)
		ln -sf ~/.local/kitty.app/bin/kitty ~/.local/kitty.app/bin/kitten ~/.local/bin/ 
		# place the kitty.desktop file somewhere it can be found by the os
		cp ~/.local/kitty.app/share/applications/kitty.desktop ~/.local/share/applications/ 
		# if you want to open text files and images in kitty via your file manager also add the kitty-open.desktop file
		cp ~/.local/kitty.app/share/applications/kitty-open.desktop ~/.local/share/applications/ 
		# update the paths to the kitty and its icon in the kitty.desktop file(s)
		sed -i "s|icon=kitty|icon=/home/$user/.local/kitty.app/share/icons/hicolor/256x256/apps/kitty.png|g" ~/.local/share/applications/kitty*.desktop 
		sed -i "s|exec=kitty|exec=/home/$user/.local/kitty.app/bin/kitty|g" ~/.local/share/applications/kitty*.desktop 
		exit 1
	fi 

	echo "kitty installed"
}

function install_lazygit(){
	echo 'Install lazygit'

	LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*') 
	curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" 
	tar xf lazygit.tar.gz lazygit 
	sudo install lazygit /usr/local/bin
	echo "Lazygit installed"
}

function install_flatpak(){
	echo "Installing flatpak"
	yes | sudo apt install flatpak -y &> /dev/null
	yes | flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

	echo "flatpak installed"
}

function install_nvim(){
	echo "Installing nvim"

	#install neovim
	sudo snap install nvim --classic 
	# flatpak install flathub io.neovim.nvim
	# flatpak run io.neovim.nvim

	#install my neovim requirements
	# --- packer
	#git clone --depth 1 https://github.com/wbthomason/packer.nvim\ ~/.local/share/nvim/site/pack/packer/start/packer.nvim 
	# --- ripgrep
	yes | sudo apt-get install ripgrep -y &> /dev/null  
	yes | sudo apt-get install fzf -y &> /dev/null
	yes | sudo apt-get install xsel -y &> /dev/null

	echo "nvim installed"
}

function install_tmux(){
    sudo apt install -y tmux
	echo "tmux installed"
}
function install_browser(){
	echo "Installing floorp browser"
	if ! command -v floorp &> /dev/null 
	then 
		echo "browser could not be found, installing" 
		flatpak install flathub one.ablaze.floorp
	  echo "browser installed"
	else
		echo "browser already installed"
	fi
}

function install_stow(){
	echo "Installing stow"
	#install stow
	yes | sudo apt install stow  
	echo "stow installed"
}	

function install_i3(){
	echo "Installing i3"
	if ! command -v i3 &> /dev/null 
	then 
		echo "i3 could not be found, installing" 
		#install i3
		yes | sudo apt install i3-wm  &> /dev/null
		yes | sudo apt install rofi  &> /dev/null
	  echo "i3 installed"
	  i3-msg restart
	else
		echo "i3 already installed"
	fi
}

function install_dotfiles(){
	echo "Installing dotfiles"
	#install dotfiles
	if [ ! -f ~/.zshrc ] && [ ! -f ~/.config/i3/config ]; then
		echo "dotfiles not stowed, installing"
		rm ~/.bashrc
		rm ~/.config/i3/config
		# git clone git@github.com:Kblack0610/.dotfiles.git ~/.dotfiles 
		cd ~/.dotfiles
		stow . 
	  echo "dotfile installed"
	else
		echo "dotfiles already installed"
	fi
}
 

