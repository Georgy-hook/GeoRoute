#pragma once
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <sddl.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <filesystem>
#include <string>
#include <vector>
#include <stdexcept>

namespace georoute {
struct Handle {
    HANDLE value = nullptr;
    Handle() = default;
    explicit Handle(HANDLE h) : value(h) {}
    Handle(const Handle&) = delete;
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
};
inline void Check(bool success) {
    if (!success) throw std::runtime_error("Windows error " + std::to_string(GetLastError()));
}
inline std::wstring Quote(const std::wstring& text) {
    std::wstring result = L"\"";
    size_t slashes = 0;
    for (wchar_t c : text) {
        if (c == L'\\') { ++slashes; continue; }
        result.append(c == L'"' ? slashes * 2 + 1 : slashes, L'\\');
        result += c;
        slashes = 0;
    }
    result.append(slashes * 2, L'\\');
    return result + L'"';
}
inline bool Is(const std::wstring& a, const wchar_t* b) { return _wcsicmp(a.c_str(), b) == 0; }
inline bool Has(const std::vector<std::wstring>& args, const wchar_t* flag) {
    for (const auto& a : args) if (Is(a, flag)) return true;
    return false;
}
inline std::wstring Arguments(const std::wstring& script, const std::vector<std::wstring>& args, const std::wstring& event) {
    std::wstring result = L"-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File " + Quote(script);
    for (size_t i = 0; i < args.size(); ++i) {
        const auto& a = args[i];
        if (Is(a,L"-SmokeTest") || Is(a,L"-Tray") || Is(a,L"-RenderPreview") || Is(a,L"-Repair")) result += L" " + a;
        else if (Is(a,L"-PreviewPath") || Is(a,L"-PreviewWidth") || Is(a,L"-PreviewHeight") || Is(a,L"-HealthSnapshotPath")) {
            if (++i == args.size()) throw std::runtime_error("Missing launcher argument value");
            result += L" " + a + L" " + Quote(args[i]);
        } else throw std::runtime_error("Unsupported launcher argument");
    }
    if (!event.empty()) result += L" -ActivationEvent " + Quote(event);
    return result;
}
inline std::wstring Identity(const std::wstring& root) {
    Handle token;
    Check(OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token.value) != 0);
    DWORD size = 0;
    GetTokenInformation(token.value, TokenUser, nullptr, 0, &size);
    Check(size != 0);
    std::vector<BYTE> data(size);
    Check(GetTokenInformation(token.value, TokenUser, data.data(), size, &size) != 0);
    LPWSTR sid = nullptr;
    Check(ConvertSidToStringSidW(reinterpret_cast<TOKEN_USER*>(data.data())->User.Sid, &sid) != 0);
    std::wstring user(sid);
    LocalFree(sid);
    int count = LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, root.data(), static_cast<int>(root.size()), nullptr, 0, nullptr, nullptr, 0);
    Check(count != 0);
    std::wstring lower(count, L'\0');
    Check(LCMapStringEx(LOCALE_NAME_INVARIANT, LCMAP_LOWERCASE, root.data(), static_cast<int>(root.size()), lower.data(), count, nullptr, nullptr, 0) != 0);
    count = WideCharToMultiByte(CP_UTF8, 0, lower.data(), static_cast<int>(lower.size()), nullptr, 0, nullptr, nullptr);
    Check(count != 0);
    std::vector<BYTE> bytes(count);
    Check(WideCharToMultiByte(CP_UTF8, 0, lower.data(), static_cast<int>(lower.size()), reinterpret_cast<char*>(bytes.data()), count, nullptr, nullptr) != 0);
    BYTE hash[32];
    if (BCryptHash(BCRYPT_SHA256_ALG_HANDLE, nullptr, 0, bytes.data(), static_cast<ULONG>(bytes.size()), hash, sizeof(hash)) < 0)
        throw std::runtime_error("Cannot compute launcher instance identity");
    const wchar_t* hex = L"0123456789ABCDEF";
    std::wstring digest;
    for (int i = 0; i < 12; ++i) { digest += hex[hash[i] >> 4]; digest += hex[hash[i] & 15]; }
    return L"Local\\NextDNS.Manager." + user + L"." + digest;
}
struct Instance {
    Handle mutex, event;
    std::wstring eventName;
    bool Acquire(const std::wstring& root, bool repair, bool background) {
        std::wstring name = Identity(root) + (repair ? L".Repair" : L".Main");
        eventName = name + L".Activate";
        event.value = CreateEventW(nullptr, FALSE, FALSE, eventName.c_str());
        Check(event.value != nullptr);
        mutex.value = CreateMutexW(nullptr, TRUE, name.c_str());
        DWORD error = GetLastError();
        Check(mutex.value != nullptr);
        if (error != ERROR_ALREADY_EXISTS) return true;
        if (!background) Check(SetEvent(event.value) != 0);
        return false;
    }
};
}
