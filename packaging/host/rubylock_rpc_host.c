/* SPDX-License-Identifier: GPL-3.0-only */
/* Native host executable for RubyLock RPC.
 * Windows: GUI subsystem wrapper (rubylock-rpc.exe) that launches Ruby cleanly
 *          without flashing a console window when opened via the Desktop shortcut.
 * Linux:   Native ELF wrapper (rubylock-rpc).
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>

static int file_exists(const char *path) {
    DWORD attr = GetFileAttributesA(path);
    return (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY));
}

static int find_ruby_binary(const char *app_dir, const char *exe_name, char *out_path, size_t out_size) {
    if (snprintf(out_path, out_size, "%s\\ruby\\bin\\%s", app_dir, exe_name) > 0 && file_exists(out_path)) {
        return 1;
    }

    DWORD found = SearchPathA(NULL, exe_name, NULL, (DWORD)out_size, out_path, NULL);
    if (found > 0 && found < out_size) return 1;

    WIN32_FIND_DATAA fd;
    HANDLE hFind = FindFirstFileA("C:\\Ruby*-x64", &fd);
    if (hFind != INVALID_HANDLE_VALUE) {
        do {
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                if (snprintf(out_path, out_size, "C:\\%s\\bin\\%s", fd.cFileName, exe_name) > 0 && file_exists(out_path)) {
                    FindClose(hFind);
                    return 1;
                }
            }
        } while (FindNextFileA(hFind, &fd));
        FindClose(hFind);
    }

    return 0;
}

static int is_cli_flag(int argc, char **argv) {
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--help") == 0 ||
            strcmp(argv[i], "-h") == 0 ||
            strcmp(argv[i], "--version") == 0 ||
            strcmp(argv[i], "-v") == 0 ||
            strcmp(argv[i], "--generate-config") == 0) {
            return 1;
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    char exe_path[MAX_PATH];
    char app_dir[MAX_PATH];
    char ruby_exe[MAX_PATH * 2];
    char script_path[MAX_PATH * 2];
    char cmdline[4096];

    DWORD len = GetModuleFileNameA(NULL, exe_path, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) {
        return 1;
    }

    strncpy(app_dir, exe_path, MAX_PATH);
    app_dir[MAX_PATH - 1] = '\0';
    char *last_slash = strrchr(app_dir, '\\');
    if (last_slash) *last_slash = '\0';

    int cli_mode = is_cli_flag(argc, argv);
    int found = 0;
    if (cli_mode) {
        found = find_ruby_binary(app_dir, "ruby.exe", ruby_exe, sizeof(ruby_exe));
    } else {
        found = find_ruby_binary(app_dir, "rubyw.exe", ruby_exe, sizeof(ruby_exe));
        if (!found) {
            found = find_ruby_binary(app_dir, "ruby.exe", ruby_exe, sizeof(ruby_exe));
        }
    }

    if (!found) {
        MessageBoxA(
            NULL,
            "Ruby 3.2+ was not found on PATH or C:\\Ruby*-x64.\nPlease install Ruby (https://rubyinstaller.org/) to run RubyLock RPC.",
            "RubyLock RPC",
            MB_ICONERROR | MB_OK
        );
        return 1;
    }

    snprintf(script_path, sizeof(script_path), "%s\\bin\\rubylock-rpc", app_dir);
    snprintf(cmdline, sizeof(cmdline), "\"%s\" \"%s\"", ruby_exe, script_path);

    for (int i = 1; i < argc; ++i) {
        strncat(cmdline, " \"", sizeof(cmdline) - strlen(cmdline) - 1);
        strncat(cmdline, argv[i], sizeof(cmdline) - strlen(cmdline) - 1);
        strncat(cmdline, "\"", sizeof(cmdline) - strlen(cmdline) - 1);
    }

    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    ZeroMemory(&pi, sizeof(pi));

    DWORD flags = cli_mode ? 0 : CREATE_NO_WINDOW;
    if (!CreateProcessA(NULL, cmdline, NULL, NULL, TRUE, flags, NULL, app_dir, &si, &pi)) {
        MessageBoxA(
            NULL,
            "Failed to start RubyLock RPC runtime.",
            "RubyLock RPC",
            MB_ICONERROR | MB_OK
        );
        return 1;
    }

    if (cli_mode) {
        WaitForSingleObject(pi.hProcess, INFINITE);
        DWORD exit_code = 0;
        GetExitCodeProcess(pi.hProcess, &exit_code);
        CloseHandle(pi.hProcess);
        CloseHandle(pi.hThread);
        return (int)exit_code;
    }

    CloseHandle(pi.hProcess);
    CloseHandle(pi.hThread);
    return 0;
}
#else
#include <limits.h>
#include <libgen.h>
#include <unistd.h>

int main(int argc, char **argv) {
    char exe_path[PATH_MAX];
    char script_path[PATH_MAX];
    ssize_t len = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
    if (len <= 0) {
        perror("readlink");
        return 1;
    }
    exe_path[len] = '\0';
    char *dir = dirname(exe_path);
    snprintf(script_path, sizeof(script_path), "%s/bin/rubylock-rpc", dir);

    char **new_argv = calloc((size_t)argc + 3, sizeof(char *));
    if (!new_argv) return 1;
    new_argv[0] = "ruby";
    new_argv[1] = script_path;
    for (int i = 1; i < argc; ++i) {
        new_argv[i + 1] = argv[i];
    }
    new_argv[argc + 1] = NULL;

    execvp("ruby", new_argv);
    perror("execvp(ruby)");
    free(new_argv);
    return 1;
}
#endif
