#!/usr/bin/env bash
. ./post_installation_scripts/install_requirements_functions.sh
pids=""
failures=0
(install_reqs) && \\ 
(install_system_settings) && \
(install_stow)
(install_zsh) && \
(install_oh_my_zsh) && \
(install_starship) && \
(install_flatpak)
(install_dotfiles)
(install_nerd_fonts)
(install_tools) 
(install_git)
(install_prompt_reqs) 
(install_kitty)
(install_lazygit)
(install_nvim)
(install_tmux)
(install_browser)
(install_i3)

# Ubuntu installation script with improved logging and error tracking
# Last updated: $(date +"%Y-%m-%d")
# Don't show commands but do exit on error for most operations
# set +x
# set -e
#
# # Source the functions file
# . $HOME/.dotfiles/.local/bin/installation_scripts/linux/ubuntu/installation_scripts/install_requirements_functions.sh
#
# # Create a log directory and files
# LOG_DIR="$HOME/.dotfiles/logs"
# mkdir -p "$LOG_DIR"
# INSTALL_LOG="$LOG_DIR/install_$(date +"%Y%m%d_%H%M%S").log"
# ERROR_LOG="$LOG_DIR/install_errors_$(date +"%Y%m%d_%H%M%S").log"
#
# # Initialize arrays to track installation status
# declare -a SUCCESSFUL_INSTALLS
# declare -a FAILED_INSTALLS
# declare -a INSTALL_TIMES
#
# # Log function with timestamps
# log() {
#     local level="$1"
#     local message="$2"
#     local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
#     echo "[$timestamp] [$level] $message" | tee -a "$INSTALL_LOG"
#     
#     # Also write errors to the error log
#     if [[ "$level" == "ERROR" ]]; then
#         echo "[$timestamp] [$level] $message" >> "$ERROR_LOG"
#     fi
# }
#
# # Function to run an installation step and track its status
# run_install_step() {
#     local func_name="$1"
#     local start_time=$(date +%s)
#     
#     log "INFO" "Starting installation of $func_name..."
#     
#     # Run the installation function and capture its exit code
#     set +e  # Temporarily disable exit on error
#     $func_name
#     local status=$?
#     set -e  # Re-enable exit on error
#     
#     local end_time=$(date +%s)
#     local duration=$((end_time - start_time))
#     
#     if [ $status -eq 0 ]; then
#         log "SUCCESS" "$func_name completed successfully (took ${duration}s)"
#         SUCCESSFUL_INSTALLS+=("$func_name")
#         INSTALL_TIMES+=("$func_name: ${duration}s")
#     else
#         log "ERROR" "$func_name failed with exit code $status (took ${duration}s)"
#         FAILED_INSTALLS+=("$func_name")
#         INSTALL_TIMES+=("$func_name: ${duration}s (FAILED)")
#     fi
#     
#     return $status
# }
#
# # Print welcome message
# log "INFO" "Starting Ubuntu installation process"
# log "INFO" "Logs will be saved to $INSTALL_LOG"
#
# # Run all installation steps
# run_install_step install_reqs
# run_install_step install_tools
# run_install_step install_git
# run_install_step install_bash_reqs
# run_install_step install_kitty
# run_install_step install_lazygit
# run_install_step install_nvim
# run_install_step install_tmux
# run_install_step install_google_chrome
# run_install_step install_stow
# run_install_step install_i3
# run_install_step install_dotfiles
#
# # Print summary report
# log "INFO" "====== Installation Summary ======"
# log "INFO" "Total installation steps: $((${#SUCCESSFUL_INSTALLS[@]} + ${#FAILED_INSTALLS[@]}))"
# log "INFO" "Successful installations: ${#SUCCESSFUL_INSTALLS[@]}"
# log "INFO" "Failed installations: ${#FAILED_INSTALLS[@]}"
#
# if [ ${#SUCCESSFUL_INSTALLS[@]} -gt 0 ]; then
#     log "INFO" "Successfully installed:"
#     for item in "${SUCCESSFUL_INSTALLS[@]}"; do
#         log "INFO" "  - $item"
#     done
# fi
#
# if [ ${#FAILED_INSTALLS[@]} -gt 0 ]; then
#     log "ERROR" "Failed to install:"
#     for item in "${FAILED_INSTALLS[@]}"; do
#         log "ERROR" "  - $item"
#     done
# fi
#
# log "INFO" "Installation timing:"
# for time_info in "${INSTALL_TIMES[@]}"; do
#     log "INFO" "  - $time_info"
# done
#
# # Check if there were any failures
# if [ ${#FAILED_INSTALLS[@]} -gt 0 ]; then
#     log "ERROR" "Installation completed with errors. Please check $ERROR_LOG for details."
#     echo -e "\n\033[1;31mInstallation completed with errors. Please check $ERROR_LOG for details.\033[0m"
#     exit 1
# else
#     log "SUCCESS" "Installation completed successfully!"
#     echo -e "\n\033[1;32mInstallation completed successfully!\033[0m"
#     exit 0
# fi
