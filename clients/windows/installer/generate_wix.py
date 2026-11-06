"""Generate a declarative per-user MSI from the verified portable payload."""
import argparse
import hashlib
from pathlib import Path
import uuid
import xml.etree.ElementTree as ET

NS = 'http://schemas.microsoft.com/wix/2006/wi'
ET.register_namespace('', NS)
COMPONENT_NAMESPACE = uuid.UUID('67fbcc2d-4d61-4f18-b080-04ad34214478')


def element(parent, tag, text=None, **attrs):
    node = ET.SubElement(parent, '{' + NS + '}' + tag, attrs)
    node.text = text
    return node


def identity(prefix, path):
    return prefix + hashlib.sha256(path.encode('utf-8')).hexdigest()[:24]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    wix = ET.Element('{' + NS + '}Wix')
    product = element(wix, 'Product', Id='*', Name='GeoRoute', Language='1049', Codepage='1251',
                      Version=args.version, Manufacturer='GeoRoute contributors',
                      UpgradeCode='{406D415F-84DD-42A8-9865-2B63D7BD5C33}')
    element(product, 'Package', InstallerVersion='500', Compressed='yes',
            InstallScope='perUser', InstallPrivileges='limited', Platform='x64', SummaryCodepage='1251',
            Description='GeoRoute: ChatGPT и Gemini')
    element(product, 'MajorUpgrade', Schedule='afterInstallInitialize',
            AllowSameVersionUpgrades='yes', DowngradeErrorMessage='Уже установлена более новая версия GeoRoute.')
    element(product, 'MediaTemplate', EmbedCab='yes', CompressionLevel='high')
    element(product, 'Condition', 'Installed OR VersionNT64', Message='Нужна 64-разрядная Windows.')
    element(product, 'Property', Id='ARPURLINFOABOUT', Value='https://github.com/Georgy-hook/GeoRoute')
    element(product, 'Property', Id='ARPPRODUCTICON', Value='AppIcon')
    element(product, 'Icon', Id='AppIcon', SourceFile=str(root / '_service/assets/app.ico'))
    element(product, 'Property', Id='WIXUI_INSTALLDIR', Value='INSTALLFOLDER')
    saved = element(product, 'Property', Id='SAVEDINSTALLFOLDER')
    element(saved, 'RegistrySearch', Id='FindPreviousFolder', Root='HKCU',
            Key='Software\\GeoRoute', Name='InstallFolder', Type='raw', Win64='yes')
    element(product, 'SetProperty', 'SAVEDINSTALLFOLDER', Id='INSTALLFOLDER',
            Value='[SAVEDINSTALLFOLDER]', Before='CostFinalize', Sequence='both')
    target = element(product, 'Directory', Id='TARGETDIR', Name='SourceDir')
    local = element(target, 'Directory', Id='LocalAppDataFolder')
    programs = element(local, 'Directory', Id='UserPrograms', Name='Programs')
    install = element(programs, 'Directory', Id='INSTALLFOLDER', Name='GeoRoute')
    element(target, 'Directory', Id='ProgramMenuFolder')
    element(target, 'Directory', Id='DesktopFolder')
    dirs = {'': install}
    components = []
    for path in sorted(root.rglob('*')):
        if not path.is_file():
            continue
        relative = path.relative_to(root).as_posix()
        parent = ''
        for part in path.relative_to(root).parts[:-1]:
            child = parent + '/' + part if parent else part
            if child not in dirs:
                dirs[child] = element(dirs[parent], 'Directory', Id=identity('D', child), Name=part)
            parent = child
        cid = identity('C', relative)
        mutable = relative in {'_service/profiles.json', '_service/connection-routes.json'} or relative.startswith('_service/profiles/')
        flags = {'Permanent': 'yes', 'NeverOverwrite': 'yes'} if mutable else {}
        comp = element(dirs[parent], 'Component', Id=cid,
                       Guid='{' + str(uuid.uuid5(COMPONENT_NAMESPACE, relative)) + '}', Win64='yes', **flags)
        element(comp, 'RegistryValue', Root='HKCU', Key='Software\\GeoRoute\\Components', Name=cid,
                Type='integer', Value='1', KeyPath='yes')
        element(comp, 'File', Id=identity('F', relative), Source=str(path), Name=path.name)
        components.append(cid)
    shortcuts = element(install, 'Component', Id='AppShortcuts',
                        Guid='{A2B1743E-52F6-49F0-84AD-EEC7176D507D}', Win64='yes')
    element(shortcuts, 'RegistryValue', Root='HKCU', Key='Software\\GeoRoute', Name='InstallFolder',
            Type='string', Value='[INSTALLFOLDER]', KeyPath='yes')
    for directory in ('ProgramMenuFolder', 'DesktopFolder'):
        element(shortcuts, 'Shortcut', Id='Shortcut' + directory, Directory=directory, Name='GeoRoute',
                Target='[System64Folder]WindowsPowerShell\\v1.0\\powershell.exe',
                Arguments='-NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "[INSTALLFOLDER]_service\\NextDNS-GUI.ps1"',
                WorkingDirectory=identity('D', '_service'), Icon='AppIcon', IconIndex='0', Advertise='no')
    components.append('AppShortcuts')
    feature = element(product, 'Feature', Id='Complete', Title='GeoRoute', Level='1')
    for cid in components:
        element(feature, 'ComponentRef', Id=cid)
    ui = element(product, 'UI')
    element(ui, 'UIRef', Id='WixUI_InstallDir')
    element(ui, 'Publish', '1', Dialog='WelcomeDlg', Control='Next', Event='NewDialog', Value='InstallDirDlg', Order='2')
    element(ui, 'Publish', '1', Dialog='InstallDirDlg', Control='Back', Event='NewDialog', Value='WelcomeDlg', Order='2')
    element(ui, 'Error', 'Закройте GeoRoute через трей перед установкой. Перед удалением выключите подключение. Подробности находятся в журнале установщика.', Id='1722')
    # Fixed visible read-only checks: no encoded commands, downloads or network changes.
    prefix = '"[System64Folder]WindowsPowerShell\\v1.0\\powershell.exe" -NoLogo -NoProfile -NonInteractive -Command '
    running = "try{$m=[Threading.Mutex]::OpenExisting('Local\\GeoRoute.Setup.Application');$m.Dispose();Write-Error 'Close GeoRoute through its tray menu first';exit 1}catch [Threading.WaitHandleCannotBeOpenedException]{exit 0}"
    hosts = "$p=Join-Path $env:SystemRoot 'System32\\drivers\\etc\\hosts';try{if([IO.File]::ReadAllText($p).Contains('# BEGIN CHATGPT-US-WINDOWS')){Write-Error 'Disable GeoRoute before uninstalling';exit 1}}catch{Write-Error $_;exit 1}"
    sequence = element(product, 'InstallExecuteSequence')
    for name, code, condition, after in [
        ('CheckRunningApp', running, 'NOT UPGRADINGPRODUCTCODE', 'CostFinalize'),
        ('CheckDisabledRoute', hosts, 'REMOVE="ALL" AND NOT UPGRADINGPRODUCTCODE', 'CheckRunningApp')]:
        escaped = ''.join('[\\' + c + ']' if c in '[]{}' else c for c in code)
        element(product, 'SetProperty', condition, Id='WixQuietExec64CmdLine', Action='Set'+name,
                Value=prefix+'"'+escaped+'"', Before=name, Sequence='execute')
        element(product, 'CustomAction', Id=name, BinaryKey='WixCA', DllEntry='WixQuietExec64', Execute='immediate', Return='check')
        element(sequence, 'Custom', condition, Action=name, After=after)
    cleanup = '"[System64Folder]WindowsPowerShell\\v1.0\\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "[INSTALLFOLDER]_service\\InstallerActions.ps1"'
    element(product, 'SetProperty', 'REMOVE="ALL" AND NOT UPGRADINGPRODUCTCODE', Id='CleanOwnStartup', Value=cleanup,
            Before='CleanOwnStartup', Sequence='execute')
    element(product, 'CustomAction', Id='CleanOwnStartup', BinaryKey='WixCA', DllEntry='WixQuietExec64',
            Execute='deferred', Impersonate='yes', Return='check')
    element(sequence, 'Custom', 'REMOVE="ALL" AND NOT UPGRADINGPRODUCTCODE', Action='CleanOwnStartup', Before='RemoveFiles')
    ET.indent(wix)
    ET.ElementTree(wix).write(args.output, encoding='utf-8', xml_declaration=True)
    print(f'Generated MSI source for {len(components)-1} payload files; no custom launcher or uninstaller EXE.')


if __name__ == '__main__':
    main()
