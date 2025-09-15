### Prerequisites
- Ensure you're in the directory where the script is saved (use `cd /path/to/directory` if needed).
- The script should start with a shebang like `#!/bin/bash` (which it does in the example).

### Steps
1. **Make the Script Executable** (if not already):
   This sets execute permissions so you can run it directly.
   ```
   sudo chmod +x script.sh
   ```
   - Replace `docker_install_and_ip_change.sh` with your actual script name.

2. **Run the Script with Sudo**:
   Use one of these methods:
   - **Preferred (Direct Execution)**:
     ```
     sudo ./script.sh
     ```
     - The `./` assumes the script is in your current directory. If it's elsewhere, use the full path (e.g., `sudo /home/user/scripts/script.sh`).
   - **Alternative (Via Bash Interpreter)**:
     ```
     sudo bash script.sh
     ```
     - This works even if the script isn't executable, as `bash` runs it.

3. **Enter Your Password** (if prompted):
   - You'll be asked for your user password to authorize `sudo`. This is normal and secure.

### Notes
- If `sudo` isn't installed or configured, install it with `apt install sudo` (but you'll need root access already for that).
- For security, only run scripts from trusted sources with `sudo`.
- If the script fails (e.g., due to permissions), check output for errors and ensure you're not in a restricted environment.

If this is for a specific script or you get an error, share the output for more help!
