# Server Lockout Recovery Guide (Oracle Cloud)

This guide helps you recover access to your Oracle Cloud VPS if you are locked out due to firewall misconfiguration or SSH issues.

## Problem Diagnosis
Based on the error `sudo: ufw: command not found`, `ufw` was likely not installed. If you subsequently installed it and enabled it without allowing OpenSSH, or modified `iptables` directly, port 22 (SSH) might be blocked. Or if you modified `/etc/ssh/sshd_config`, SSH service might be down.

Since you are using an **Oracle Always Free** instance, you have two powerful recovery methods that don't require SSH.

## Method 1: Oracle Cloud "Run Command" (Easiest)
Oracle Cloud instances have an agent running by default that allows executing commands as root from the web console.

1.  Log in to the **Oracle Cloud Console**.
2.  Navigate to **Compute** -> **Instances**.
3.  Click on your instance (`instance-202X...` or your specific name).
4.  Scroll down to the **Resources** section on the left sidebar.
5.  Click on **Run Command**.
6.  Click **Create command**.
7.  In the "Command source" usually select "Paste script".
8.  Paste the following script to disable all firewalls and simplistic rules:

    ```bash
    #!/bin/bash
    # Disable UFW if active
    ufw disable
    
    # Flush all iptables rules (DANGEROUS but recovers access)
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    iptables -t mangle -F
    iptables -t mangle -X
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT

    # Ensure SSH service is running
    systemctl restart sshd
    ```

9.  Click **Run**.
10. Wait for the command to complete (check the status).
11. Try to SSH again.

## Method 2: Serial Console Connection (If Run Command fails)
If the Oracle Cloud Agent is not running, you can access the server via a virtual serial console.

1.  Log in to the **Oracle Cloud Console**.
2.  Navigate to **Compute** -> **Instances** -> Your Instance.
3.  Scroll down to **Resources** -> **Console connection**.
4.  Click **Launch Cloud Shell connection**.
5.  This opens a terminal in your browser.
    *   **If prompted for login**: Try `ubuntu` and your password if you set one. If you only use SSH keys, you won't have a password.
    *   **If no password**: You must reboot into single-user mode.

### Rebooting into Single-User Mode (Reset Password/Firewall)
1.  Keep the **Cloud Shell connection** open.
2.  In the Oracle Console, click **Reboot** (top of the page).
3.  Immediately switch back to the Cloud Shell window.
4.  Watch for the boot process. When you see the GRUB menu (list of kernels), **press `e` immediately** to edit.
5.  Find the line starting with `linux` or `linuxefi`.
6.  Append `init=/bin/bash` to the end of that line.
7.  Press **Ctrl+X** or **F10** to boot.
8.  You will drop into a root shell `#`.
9.  Remount the filesystem as read-write:
    ```bash
    mount -o remount,rw /
    ```
10. Fix the issue:
    *   Disable firewall: `ufw disable` or `iptables -F`
    *   Set a password for `ubuntu` user (so you can login via console next time): `passwd ubuntu`
    *   Check SSH config: `nano /etc/ssh/sshd_config`
11. Reboot:
    ```bash
    exec /sbin/init
    # OR forcefully
    reboot -f
    ```

## Method 3: Check Security Lists (Oracle Cloud Firewall)
Sometimes the issue is outside the VM, in the Oracle Virtual Cloud Network (VCN).

1.  Go to **Compute** -> **Instances** -> Your Instance.
2.  Click the link under **Subnet** (e.g., `subnet-202X...`).
3.  Click on the **Security List** applicable to your subnet.
4.  Check **Ingress Rules**.
5.  Ensure there is a rule:
    *   **Source**: `0.0.0.0/0` (or your IP)
    *   **IP Protocol**: TCP
    *   **Destination Port Range**: `22`
6.  If missing, add it.

