#include "../_service/LauncherNative.h"
#include <iostream>
int wmain() {
    using namespace georoute;
    try {
        for (const std::wstring value : {L"C:\\path with spaces\\file.png",L"quote\"and\\trailing\\",L"semi;dollar$'brackets[]",L""}) {
            std::wstring command=L"test.exe " + Quote(value);
            int count=0;
            LPWSTR* parsed=CommandLineToArgvW(command.c_str(),&count);
            bool valid=parsed && count==2 && std::wstring(parsed[1])==value;
            if(parsed) LocalFree(parsed);
            if(!valid) throw std::runtime_error("Argument round-trip failed");
        }
        for (const std::vector<std::wstring> args : {std::vector<std::wstring>{L"-Command",L"anything"},std::vector<std::wstring>{L"-PreviewPath"}}) {
            bool rejected=false;
            try { Arguments(L"test.ps1",args,L""); } catch(const std::runtime_error&) { rejected=true; }
            if(!rejected) throw std::runtime_error("Unknown/incomplete argument accepted");
        }
        Instance instance;
        std::wstring root=std::filesystem::current_path().wstring()+L"\\native-test-"+std::to_wstring(GetCurrentProcessId());
        if(!instance.Acquire(root,false,false)) throw std::runtime_error("Instance acquire failed");
        Instance second;
        if(second.Acquire(root,false,false)) throw std::runtime_error("Second instance accepted");
        if(WaitForSingleObject(instance.event.value,0)!=WAIT_OBJECT_0 || WaitForSingleObject(instance.event.value,0)!=WAIT_TIMEOUT) throw std::runtime_error("Activation/reset failed");
        std::wcout << L"7 native launcher checks passed: argument boundaries, rejection and single-instance activation.\n";
        return 0;
    } catch(const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
}
