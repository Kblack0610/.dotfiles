
#TODO Split this into requirements, tools, applications, and applying dotfiles, git config, and stow

echo "Installing requirements."
#Base requirements
yes | sudo apt update && \\
yes | sudo apt upgrade && \\
yes | sudo apt install vim && \\
yes | sudo apt install wget && \\
yes | sudo apt install curl && \\
yes | sudo apt install snap && \\
yes | sudo apt install neofetch && \\
curl -fsSL https://deb.nodesource.com/setup_21.x | sudo -E bash - &&\
sudo apt-get install -y nodejs

echo "requirements installed"

read 

echo "Installing tools"

#install tools
yes | sudo apt install autojump && \\
yes | sudo apt install glances 

echo "tools installed"

read 

#install git
yes | sudo apt install git && \\
git config --global user.name Kenneth && \\ 
git config --global user.email kblack0610@gmail.com
git config --global credential.helper store

if ! test -f ~/.ssh/id_ed25519; then
	echo "git ssh doesn't exists, downloading"
	read
	cp ~/tmp/git_ssh ~/.ssh/id_ed25519 && \\
	ssh-keygen -t ed25519 -C "kblack0610@example.com" && \\
	eval "$(ssh-agent -s)" && \\
	ssh-add ~/.ssh/id_ed25519 && \\
fi

echo "Installing bash requirements"
#bash requirements
yes | sudo apt install cowsay && \\
yes | sudo apt install fortune && \\
yes | sudo apt install feh && \\

echo "Installing kitty"

if ! command -v kitty &> /dev/null 
then 
    	echo "kitty could not be found, installing" 
	#install kitty
	curl -l https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin && \\
	yes | mkdir ~/.local/bin
	# -- desktop integration for kitty
	# create symbolic links to add kitty and kitten to path (assuming ~/.local/bin is in
	# your system-wide path)
	ln -sf ~/.local/kitty.app/bin/kitty ~/.local/kitty.app/bin/kitten ~/.local/bin/ && \\
	# place the kitty.desktop file somewhere it can be found by the os
	cp ~/.local/kitty.app/share/applications/kitty.desktop ~/.local/share/applications/ && \\
	# if you want to open text files and images in kitty via your file manager also add the kitty-open.desktop file
	cp ~/.local/kitty.app/share/applications/kitty-open.desktop ~/.local/share/applications/ && \\
	# update the paths to the kitty and its icon in the kitty.desktop file(s)
	sed -i "s|icon=kitty|icon=/home/$user/.local/kitty.app/share/icons/hicolor/256x256/apps/kitty.png|g" ~/.local/share/applications/kitty*.desktop && \\
	sed -i "s|exec=kitty|exec=/home/$user/.local/kitty.app/bin/kitty|g" ~/.local/share/applications/kitty*.desktop && \\
    	exit 1
fi 

echo 'Install lazygit'

LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*') && \\
curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz" && \\
tar xf lazygit.tar.gz lazygit && \\
sudo install lazygit /usr/local/bin


echo "Installing nvim"
read

#install neovim
sudo snap install nvim --classic 
#install my neovim requirements
# --- packer
git clone --depth 1 https://github.com/wbthomason/packer.nvim\ ~/.local/share/nvim/site/pack/packer/start/packer.nvim && \\
# --- ripgrep
yes | sudo apt-get install ripgrep && \\
yes | sudo apt-get install fzf && \\ 
yes | sudo apt-get install xsel

echo "nvim installed"
read
if ! command -v google-chrome &> /dev/null 
then 
    	echo "google chrome could not be found, installing" 
	read
	#install chrome
	yes | wget https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && \\
	yes | sudo dpkg -i google-chrome-stable_current_amd64.deb && \\
    	exit 1
fi

#install stow
yes | sudo apt install stow 

if ! command -v i3 &> /dev/null 
then 
    	echo "i3 could not be found, installing" 
	read
	#install i3
	yes | /usr/lib/apt/apt-helper download-file https://debian.sur5r.net/i3/pool/main/s/sur5r-keyring/sur5r-keyring_2023.02.18_all.deb keyring.deb sha256:a511ac5f10cd811f8a4ca44d665f2fa1add7a9f09bef238cdfad8461f5239cc4 && \\
	yes | sudo apt install ./keyring.deb && \\
	yes | echo "deb http://debian.sur5r.net/i3/ $(grep '^distrib_codename=' /etc/lsb-release | cut -f2 -d=) universe" | sudo tee /etc/apt/sources.list.d/sur5r-i3.list && \\
	yes | sudo apt update && \\
	yes | sudo apt install i3 
    	exit 1
fi

echo "Installing dotfiles"

#install dotfiles
if ! test -d ~/.dotfiles; then
	echo "dotfiles not found"
	rm ~/.bashrc
	rm ~/.config/i3/config
	git clone git@github.com:Kblack0610/.dotfiles.git ~/.dotfiles && \\
	cd ~/.dotfiles
	stow . 
fi
 
i3-msg restart

echo "requirements to party installed successfully"
