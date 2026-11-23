#Requires -Version 5.1
$ErrorActionPreference='Stop'
$private=Join-Path ([IO.Path]::GetTempPath()) ('georoute-process-'+[guid]::NewGuid().ToString('N'));$program=$private
[IO.Directory]::CreateDirectory($private)|Out-Null
try{
 $source=Join-Path (Split-Path $PSScriptRoot -Parent) '_service\WarpSetup.ps1'
 $tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
 $function=$ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Run-WarpTool'},$false)[0]
 . ([scriptblock]::Create($function.Extent.Text))
 $fixture=Join-Path $private 'fixture.py';$python=(Get-Command python.exe).Source
 [IO.File]::WriteAllText($fixture,"print('validation completed')",[Text.UTF8Encoding]::new($false))
 Run-WarpTool $python @('-I',('"'+$fixture+'"'))
 if((Get-Content -Raw -LiteralPath (Join-Path $private 'bootstrap-output.log')) -notmatch 'validation completed'){throw 'Successful child output lost'}
 [IO.File]::WriteAllText($fixture,"import sys; print('rejected', file=sys.stderr); sys.exit(9)",[Text.UTF8Encoding]::new($false))
 $rejected=$false;try{Run-WarpTool $python @('-I',('"'+$fixture+'"'))}catch{$rejected=$_.Exception.Message -match 'bootstrap failed'}
 if(-not $rejected -or (Get-Content -Raw -LiteralPath (Join-Path $private 'bootstrap-error.log')) -notmatch 'rejected'){throw 'Nonzero exit must fail with retained diagnostic'}
 [IO.File]::WriteAllText($fixture,'import time; time.sleep(10)',[Text.UTF8Encoding]::new($false))
 $timedOut=$false;$watch=[Diagnostics.Stopwatch]::StartNew();try{Run-WarpTool $python @('-I',('"'+$fixture+'"')) 1}catch{$timedOut=$_.Exception.Message -match 'timed out'}
 if(-not $timedOut -or $watch.Elapsed.TotalSeconds -gt 6){throw 'Timeout must stop only the owned child promptly'}
 Write-Output 'Installer subprocess: real successful exit, failure diagnostics and bounded timeout passed in Windows PowerShell 5.1.'
}finally{
 $full=[IO.Path]::GetFullPath($private)
 if(-not $full.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($full) -notmatch '^georoute-process-[a-f0-9]{32}$'){throw 'Unsafe cleanup'}
 if(Test-Path -LiteralPath $full){Remove-Item -LiteralPath $full -Recurse -Force}
}
