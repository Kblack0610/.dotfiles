While CUPS is the standard for printing on Linux, you're right that it can sometimes feel complex for a simple task. The good news is that for most modern printers, the process is much simpler than it used to be, and you might not need to delve into the nitty-gritty of CUPS configuration.

The Easiest Method: Driverless Printing

For most modern printers, you can use driverless printing. This means you don't have to hunt for specific drivers for your brother's printer. Here's how to set it up on Arch Linux:

    Install CUPS and Avahi:
    Bash

sudo pacman -S cups avahi

Enable and start the services:
Bash

    sudo systemctl enable --now cups.service
    sudo systemctl enable --now avahi-daemon.service

That's it! Your system should now automatically discover printers on the network. When you go to print a document, your brother's printer should appear in the print dialog.

# USE LP FOR COMMAND LINE PRINTING

Other Options

If driverless printing doesn't work, here are a couple of other options:

    CUPS Web Interface: CUPS has a web-based configuration tool that's fairly straightforward. Open your web browser and go to http://localhost:631. From there, you can manually add your brother's printer. You'll likely need the printer's IP address.

    Alternative Printing System (LPRng): There is an older, simpler printing system called LPRng. However, it has much more limited printer support than CUPS. If you're having trouble with CUPS, it's unlikely that LPRng will be a better option.

    The Non-Technical Solution: The absolute simplest way to "send files to your brother's printer" is to just send the files directly to your brother via email, a messaging app, or a shared folder, and have him print them. This completely bypasses any need for you to set up printing on your system.

For a visual guide on setting up printing on Arch Linux, this video provides a helpful overview:

For a step-by-step tutorial on how to get printing to work in Arch Linux, check out this helpful video: Linux & Printing
