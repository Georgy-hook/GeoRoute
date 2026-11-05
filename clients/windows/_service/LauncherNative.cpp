#include "LauncherNative.h"
#include <fstream>

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
    namespace fs = std::filesystem;
    using namespace georoute;
    fs::path root;
    bool quiet = false;
    try {
        int argc = 0;
        LPWSTR* raw = CommandLineToArgvW(GetCommandLineW(), &argc);
        Check(raw != nullptr);
        std::vector<std::wstring> args;
        for (int i = 1; i < argc; ++i) args.emplace_back(raw[i]);
        LocalFree(raw);
        quiet = Has(args, L"-SmokeTest") || Has(args, L"-RenderPreview");
        std::vector<wchar_t> buffer(32768);
        DWORD length = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
        Check(length != 0 && length < buffer.size());
        fs::path base = fs::path(std::wstring(buffer.data(), length)).parent_path();
        root = base / L"_service";
        if (!fs::exists(root / L"NextDNS-GUI.ps1")) root = base.parent_path();
        fs::path script = root / L"NextDNS-GUI.ps1";
        if (!fs::exists(script)) throw std::runtime_error("Missing _service/NextDNS-GUI.ps1");
        // Validate the full argument contract before signalling another instance.
        Arguments(script.wstring(), args, L"");
        Instance instance;
        if (!quiet && !instance.Acquire(root.wstring(), Has(args,L"-Repair"), Has(args,L"-Tray"))) return 0;
        length = GetSystemDirectoryW(buffer.data(), static_cast<UINT>(buffer.size()));
        Check(length != 0 && length < buffer.size());
        fs::path powershell = fs::path(std::wstring(buffer.data(), length)) / L"WindowsPowerShell" / L"v1.0" / L"powershell.exe";
        std::wstring modules = (powershell.parent_path() / L"Modules").wstring();
        DWORD programLength = GetEnvironmentVariableW(L"ProgramFiles", buffer.data(), static_cast<DWORD>(buffer.size()));
        if (programLength && programLength < buffer.size())
            modules = (fs::path(std::wstring(buffer.data(), programLength)) / L"WindowsPowerShell" / L"Modules").wstring() + L";" + modules;
        Check(SetEnvironmentVariableW(L"PSModulePath", modules.c_str()) != 0);
        std::wstring command = Quote(powershell.wstring()) + L" " + Arguments(script.wstring(), args, quiet ? L"" : instance.eventName);
        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESHOWWINDOW;
        startup.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION child{};
        Check(CreateProcessW(powershell.c_str(), command.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, root.c_str(), &startup, &child) != 0);
        Handle process(child.hProcess), thread(child.hThread);
        Check(WaitForSingleObject(process.value, INFINITE) == WAIT_OBJECT_0);
        DWORD exit = 1;
        Check(GetExitCodeProcess(process.value, &exit) != 0);
        return static_cast<int>(exit);
    } catch (const std::exception& error) {
        try { if (!root.empty()) std::ofstream(root / L"launcher-error.log", std::ios::app) << error.what() << '\n'; } catch (...) { }
        if (!quiet) MessageBoxW(nullptr, L"Не удалось открыть GeoRoute. Проверьте целостность папки приложения. Подробности: _service\\launcher-error.log", L"GeoRoute", MB_OK | MB_ICONERROR);
        return 1;
    }
}
