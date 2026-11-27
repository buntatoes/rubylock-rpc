/* SPDX-License-Identifier: GPL-3.0-only */
/* Self-contained Windows installer & uninstaller for RubyLock RPC.
 * - Extracts embedded RLPC payload to %LOCALAPPDATA%\RubyLock-RPC
 * - Creates a Desktop shortcut ("RubyLock RPC.lnk") and Start Menu shortcut
 *   pointing to rubylock-rpc.exe with assets\icon.ico so launching Deadlock
 *   through the shortcut automatically starts Deadlock with -condebug and RPC.
 * - Registers Add/Remove Programs uninstall support (--uninstall).
 */

#define COBJMACROS
#include <windows.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <objbase.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define APP_DISPLAY_NAME  L"RubyLock RPC"
#define APP_VERSION       L"1.3.0"
#define APP_PUBLISHER     L"Buntato"
#define UNINSTALL_REG_KEY L"Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\RubyLockRpc"
#define PAYLOAD_RES_ID    101

static uint32_t read_le32(const uint8_t *p) {
    return ((uint32_t)p[0]) |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

static void ensure_parent_dirs(const wchar_t *filepath) {
    wchar_t buf[MAX_PATH * 2];
    wcsncpy(buf, filepath, (sizeof(buf) / sizeof(buf[0])) - 1);
    buf[(sizeof(buf) / sizeof(buf[0])) - 1] = L'\0';

    for (wchar_t *p = buf; *p; ++p) {
        if (*p == L'/') *p = L'\\';
    }
    for (wchar_t *p = buf + 3; *p; ++p) {
        if (*p == L'\\') {
            *p = L'\0';
            CreateDirectoryW(buf, NULL);
            *p = L'\\';
        }
    }
}

static int create_shortcut(
    const wchar_t *lnk_path,
    const wchar_t *target_exe,
    const wchar_t *work_dir,
    const wchar_t *icon_path,
    const wchar_t *description
) {
    IShellLinkW *psl = NULL;
    IPersistFile *ppf = NULL;
    HRESULT hr = CoCreateInstance(
        &CLSID_ShellLink,
        NULL,
        CLSCTX_INPROC_SERVER,
        &IID_IShellLinkW,
        (void **)&psl
    );
    if (FAILED(hr) || !psl) return 0;

    IShellLinkW_SetPath(psl, target_exe);
    IShellLinkW_SetWorkingDirectory(psl, work_dir);
    IShellLinkW_SetDescription(psl, description);
    if (icon_path && icon_path[0]) {
        IShellLinkW_SetIconLocation(psl, icon_path, 0);
    }

    hr = IShellLinkW_QueryInterface(psl, &IID_IPersistFile, (void **)&ppf);
    int ok = 0;
    if (SUCCEEDED(hr) && ppf) {
        hr = IPersistFile_Save(ppf, lnk_path, TRUE);
        ok = SUCCEEDED(hr) ? 1 : 0;
        IPersistFile_Release(ppf);
    }
    IShellLinkW_Release(psl);
    return ok;
}

static void get_install_dir(wchar_t *out, size_t count) {
    wchar_t local_app[MAX_PATH];
    if (SUCCEEDED(SHGetFolderPathW(NULL, CSIDL_LOCAL_APPDATA, NULL, 0, local_app))) {
        _snwprintf(out, count, L"%ls\\RubyLock-RPC", local_app);
    } else {
        _snwprintf(out, count, L"C:\\RubyLock-RPC");
    }
    out[count - 1] = L'\0';
}

static void get_desktop_shortcut_path(wchar_t *out, size_t count) {
    wchar_t desktop[MAX_PATH];
    if (SUCCEEDED(SHGetFolderPathW(NULL, CSIDL_DESKTOPDIRECTORY, NULL, 0, desktop))) {
        _snwprintf(out, count, L"%ls\\RubyLock RPC.lnk", desktop);
    } else {
        out[0] = L'\0';
    }
    out[count - 1] = L'\0';
}

static void get_startmenu_shortcut_path(wchar_t *out, size_t count) {
    wchar_t programs[MAX_PATH];
    if (SUCCEEDED(SHGetFolderPathW(NULL, CSIDL_PROGRAMS, NULL, 0, programs))) {
        _snwprintf(out, count, L"%ls\\RubyLock RPC.lnk", programs);
    } else {
        out[0] = L'\0';
    }
    out[count - 1] = L'\0';
}

static void remove_directory_recursive(const wchar_t *dir_path) {
    wchar_t pattern[MAX_PATH * 2];
    _snwprintf(pattern, sizeof(pattern) / sizeof(pattern[0]), L"%ls\\*", dir_path);

    WIN32_FIND_DATAW fd;
    HANDLE hFind = FindFirstFileW(pattern, &fd);
    if (hFind != INVALID_HANDLE_VALUE) {
        do {
            if (wcscmp(fd.cFileName, L".") == 0 || wcscmp(fd.cFileName, L"..") == 0) {
                continue;
            }
            wchar_t child[MAX_PATH * 2];
            _snwprintf(child, sizeof(child) / sizeof(child[0]), L"%ls\\%ls", dir_path, fd.cFileName);
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                remove_directory_recursive(child);
            } else {
                SetFileAttributesW(child, FILE_ATTRIBUTE_NORMAL);
                DeleteFileW(child);
            }
        } while (FindNextFileW(hFind, &fd));
        FindClose(hFind);
    }
    RemoveDirectoryW(dir_path);
}

static int extract_payload(const wchar_t *install_dir) {
    HRSRC hRes = FindResourceW(NULL, MAKEINTRESOURCEW(PAYLOAD_RES_ID), MAKEINTRESOURCEW(10));
    if (!hRes) return 0;

    DWORD res_size = SizeofResource(NULL, hRes);
    HGLOBAL hData = LoadResource(NULL, hRes);
    if (!hData || res_size < 8) return 0;

    const uint8_t *buf = (const uint8_t *)LockResource(hData);
    if (!buf || memcmp(buf, "RLPC", 4) != 0) return 0;

    uint32_t file_count = read_le32(buf + 4);
    size_t offset = 8;

    CreateDirectoryW(install_dir, NULL);

    for (uint32_t i = 0; i < file_count; ++i) {
        if (offset + 8 > res_size) return 0;
        uint32_t path_len = read_le32(buf + offset);
        uint32_t data_len = read_le32(buf + offset + 4);
        offset += 8;

        if (offset + path_len + data_len > res_size) return 0;

        char rel_utf8[MAX_PATH];
        if (path_len >= sizeof(rel_utf8)) return 0;
        memcpy(rel_utf8, buf + offset, path_len);
        rel_utf8[path_len] = '\0';
        offset += path_len;

        wchar_t rel_wide[MAX_PATH];
        MultiByteToWideChar(CP_UTF8, 0, rel_utf8, -1, rel_wide, MAX_PATH);
        for (wchar_t *p = rel_wide; *p; ++p) {
            if (*p == L'/') *p = L'\\';
        }

        wchar_t full_path[MAX_PATH * 2];
        _snwprintf(full_path, sizeof(full_path) / sizeof(full_path[0]), L"%ls\\%ls", install_dir, rel_wide);
        ensure_parent_dirs(full_path);

        HANDLE hFile = INVALID_HANDLE_VALUE;
        for (int attempt = 0; attempt < 25; ++attempt) {
            hFile = CreateFileW(
                full_path,
                GENERIC_WRITE,
                0,
                NULL,
                CREATE_ALWAYS,
                FILE_ATTRIBUTE_NORMAL,
                NULL
            );
            if (hFile != INVALID_HANDLE_VALUE) break;
            if (GetLastError() != ERROR_SHARING_VIOLATION && GetLastError() != ERROR_ACCESS_DENIED) break;
            Sleep(200);
        }
        if (hFile == INVALID_HANDLE_VALUE) return 0;

        DWORD written = 0;
        if (data_len > 0) {
            BOOL ok = WriteFile(hFile, buf + offset, data_len, &written, NULL);
            CloseHandle(hFile);
            if (!ok || written != data_len) return 0;
        } else {
            CloseHandle(hFile);
        }
        offset += data_len;
    }

    return 1;
}

static void register_uninstall(const wchar_t *install_dir, const wchar_t *setup_copy, const wchar_t *icon_path) {
    HKEY hKey = NULL;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, UNINSTALL_REG_KEY, 0, NULL, 0, KEY_WRITE, NULL, &hKey, NULL) != ERROR_SUCCESS) {
        return;
    }

    wchar_t uninstall_cmd[MAX_PATH * 2];
    _snwprintf(uninstall_cmd, sizeof(uninstall_cmd) / sizeof(uninstall_cmd[0]), L"\"%ls\" --uninstall", setup_copy);

    RegSetValueExW(hKey, L"DisplayName", 0, REG_SZ, (const BYTE *)APP_DISPLAY_NAME, (DWORD)((wcslen(APP_DISPLAY_NAME) + 1) * sizeof(wchar_t)));
    RegSetValueExW(hKey, L"DisplayVersion", 0, REG_SZ, (const BYTE *)APP_VERSION, (DWORD)((wcslen(APP_VERSION) + 1) * sizeof(wchar_t)));
    RegSetValueExW(hKey, L"Publisher", 0, REG_SZ, (const BYTE *)APP_PUBLISHER, (DWORD)((wcslen(APP_PUBLISHER) + 1) * sizeof(wchar_t)));
    RegSetValueExW(hKey, L"InstallLocation", 0, REG_SZ, (const BYTE *)install_dir, (DWORD)((wcslen(install_dir) + 1) * sizeof(wchar_t)));
    RegSetValueExW(hKey, L"DisplayIcon", 0, REG_SZ, (const BYTE *)icon_path, (DWORD)((wcslen(icon_path) + 1) * sizeof(wchar_t)));
    RegSetValueExW(hKey, L"UninstallString", 0, REG_SZ, (const BYTE *)uninstall_cmd, (DWORD)((wcslen(uninstall_cmd) + 1) * sizeof(wchar_t)));
    DWORD no_modify = 1;
    RegSetValueExW(hKey, L"NoModify", 0, REG_DWORD, (const BYTE *)&no_modify, sizeof(no_modify));
    RegSetValueExW(hKey, L"NoRepair", 0, REG_DWORD, (const BYTE *)&no_modify, sizeof(no_modify));

    RegCloseKey(hKey);
}

static int do_uninstall(int silent) {
    wchar_t install_dir[MAX_PATH];
    wchar_t desktop_lnk[MAX_PATH];
    wchar_t startmenu_lnk[MAX_PATH];

    get_install_dir(install_dir, MAX_PATH);
    get_desktop_shortcut_path(desktop_lnk, MAX_PATH);
    get_startmenu_shortcut_path(startmenu_lnk, MAX_PATH);

    if (!silent) {
        int res = MessageBoxW(
            NULL,
            L"Uninstall RubyLock RPC and remove its Desktop and Start Menu shortcuts?",
            APP_DISPLAY_NAME,
            MB_ICONQUESTION | MB_YESNO
        );
        if (res != IDYES) return 0;
    }

    if (desktop_lnk[0]) DeleteFileW(desktop_lnk);
    if (startmenu_lnk[0]) DeleteFileW(startmenu_lnk);
    RegDeleteTreeW(HKEY_CURRENT_USER, UNINSTALL_REG_KEY);
    remove_directory_recursive(install_dir);
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, NULL, NULL);

    if (!silent) {
        MessageBoxW(
            NULL,
            L"RubyLock RPC has been uninstalled.",
            APP_DISPLAY_NAME,
            MB_ICONINFORMATION | MB_OK
        );
    }
    return 0;
}

static int do_install(int silent) {
    wchar_t install_dir[MAX_PATH];
    wchar_t exe_target[MAX_PATH * 2];
    wchar_t icon_path[MAX_PATH * 2];
    wchar_t setup_self[MAX_PATH];
    wchar_t setup_copy[MAX_PATH * 2];
    wchar_t desktop_lnk[MAX_PATH];
    wchar_t startmenu_lnk[MAX_PATH];

    get_install_dir(install_dir, MAX_PATH);

    if (!silent) {
        wchar_t prompt[1024];
        _snwprintf(
            prompt,
            sizeof(prompt) / sizeof(prompt[0]),
            L"Install RubyLock RPC v" APP_VERSION L"?\n\n"
            L"Install folder:\n%ls\n\n"
            L"This will also create a \"RubyLock RPC\" shortcut on your Desktop to launch Deadlock with Discord Rich Presence.",
            install_dir
        );
        int res = MessageBoxW(NULL, prompt, APP_DISPLAY_NAME, MB_ICONINFORMATION | MB_OKCANCEL);
        if (res != IDOK) return 0;
    }

    if (!extract_payload(install_dir)) {
        if (!silent) {
            MessageBoxW(NULL, L"Installation failed while extracting application files.", APP_DISPLAY_NAME, MB_ICONERROR | MB_OK);
        }
        return 1;
    }

    _snwprintf(exe_target, sizeof(exe_target) / sizeof(exe_target[0]), L"%ls\\rubylock-rpc.exe", install_dir);
    _snwprintf(icon_path, sizeof(icon_path) / sizeof(icon_path[0]), L"%ls\\assets\\icon.ico", install_dir);
    _snwprintf(setup_copy, sizeof(setup_copy) / sizeof(setup_copy[0]), L"%ls\\RubyLock-RPC-Setup.exe", install_dir);

    if (GetModuleFileNameW(NULL, setup_self, MAX_PATH) > 0) {
        CopyFileW(setup_self, setup_copy, FALSE);
    }

    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    get_desktop_shortcut_path(desktop_lnk, MAX_PATH);
    get_startmenu_shortcut_path(startmenu_lnk, MAX_PATH);

    if (desktop_lnk[0]) {
        create_shortcut(
            desktop_lnk,
            exe_target,
            install_dir,
            icon_path,
            L"Launch Deadlock with Discord Rich Presence (RubyLock RPC)"
        );
    }
    if (startmenu_lnk[0]) {
        create_shortcut(
            startmenu_lnk,
            exe_target,
            install_dir,
            icon_path,
            L"Launch Deadlock with Discord Rich Presence (RubyLock RPC)"
        );
    }
    CoUninitialize();

    register_uninstall(install_dir, setup_copy, icon_path);
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, NULL, NULL);

    if (!silent) {
        MessageBoxW(
            NULL,
            L"Installation complete!\n\nUse the \"RubyLock RPC\" shortcut on your Desktop to launch Deadlock with Discord Rich Presence.",
            APP_DISPLAY_NAME,
            MB_ICONINFORMATION | MB_OK
        );
    }
    return 0;
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE hPrev, LPSTR lpCmdLine, int nCmdShow) {
    (void)hInst;
    (void)hPrev;
    (void)nCmdShow;

    int silent = (lpCmdLine && strstr(lpCmdLine, "--silent") != NULL);
    int uninstall = (lpCmdLine && strstr(lpCmdLine, "--uninstall") != NULL);

    if (uninstall) {
        return do_uninstall(silent);
    }
    return do_install(silent);
}
