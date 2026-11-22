<#
Deploys Hikae on testnet and measures the first Base Sepolia -> Reactive Lasna -> Unichain Sepolia loops.

Run it from this folder, in your own terminal:
    pwsh -File .\deploy.ps1
or  powershell -ExecutionPolicy Bypass -File .\deploy.ps1

It asks for the keystore password once, writes it to a temporary file that only forge and cast read, and deletes
the file when it finishes, even on errors. Every value a step produces is saved in deployments\testnet.env, so a
second run skips the steps that already finished. Use -Fresh to deploy everything again.

With -Retro it deploys, next to the v1 pool, a second reactive contract, the retro hook with its pool and a demo
router, then runs the race demo (latency/race.ts) instead of the latency rounds.

With -Verify it also verifies the contracts on Sourcify, which publishes their source code.
#>
param(
    [string]$Account = "wallet-0x75",
    [string]$Sender = "0x75464f762bc50d0A0B127ab5a085504BF102Bb88",
    [int]$Rounds = 10,
    [switch]$Retro,
    [switch]$Verify,
    [switch]$Fresh
)

$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$BaseRpc = "https://sepolia.base.org"
$LasnaRpc = "https://lasna-rpc.rnk.dev/"
$Faucet = "0x2afaFD298b23b62760711756088F75B7409f5967" # Reactive faucet on Base Sepolia: 1 ETH = 100 lREACT
$StateFile = Join-Path $PSScriptRoot "deployments\testnet.env"

New-Item -ItemType Directory -Force (Split-Path $StateFile) | Out-Null
if ($Fresh -and (Test-Path $StateFile)) {
    Move-Item $StateFile "$StateFile.$(Get-Date -Format yyyyMMdd-HHmmss).bak"
}
if (Test-Path $StateFile) {
    foreach ($line in Get-Content $StateFile) {
        if ($line -match '^([A-Z0-9_]+)=(.+)$') { Set-Item "Env:$($Matches[1])" $Matches[2] }
    }
    Write-Host "Resuming from $StateFile" -ForegroundColor Yellow
}

function Save-Value([string]$Name, [string]$Value) {
    Set-Item "Env:$Name" $Value
    Add-Content $StateFile "$Name=$Value"
    Write-Host "  $Name=$Value" -ForegroundColor Green
}

function Invoke-Step([string]$Title, [string]$Script, [string]$Rpc) {
    Write-Host "`n== $Title" -ForegroundColor Cyan
    # Windows PowerShell 5.1 turns any stderr line of a native command into an error record, and forge prints
    # harmless warnings there. Judge the step by its exit code instead.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $lines = & forge script $Script --rpc-url $Rpc --broadcast --slow --account $Account --sender $Sender 2>&1 |
            ForEach-Object { "$_" }
    } finally {
        $ErrorActionPreference = $previous
    }
    $lines | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) { throw "$Title failed, see the output above. Run the script again to resume." }
    foreach ($line in $lines) {
        if ($line -match '^\s*([A-Z0-9_]+)=(0x[0-9a-fA-F]+)\s*$') { Save-Value $Matches[1] $Matches[2] }
    }
}

function Invoke-Verify([string]$Address, [string]$Contract, [int]$ChainId) {
    if (-not $Address) { return }
    Write-Host "  Sourcify: $Contract at $Address (chain $ChainId)"
    $previous = $ErrorActionPreference
    $ErrorActionPreference = "Continue" # a failed verification must not stop the deploy
    try {
        & forge verify-contract --verifier sourcify --chain-id $ChainId $Address $Contract 2>&1 |
            ForEach-Object { "$_" } | Select-Object -Last 2 | ForEach-Object { Write-Host "    $_" }
    } catch {
        Write-Host "    verification failed: $_" -ForegroundColor Yellow
    } finally {
        $ErrorActionPreference = $previous
    }
}

function Get-LasnaBalance {
    [double](& cast balance $Sender --ether --rpc-url $LasnaRpc)
}

$secure = Read-Host "Password for keystore '$Account'" -AsSecureString
$passwordFile = Join-Path $env:TEMP ("hikae-" + [guid]::NewGuid().ToString() + ".tmp")
try {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        [IO.File]::WriteAllText($passwordFile, [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr))
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
    $env:ETH_PASSWORD = $passwordFile
    $env:ETH_KEYSTORE_ACCOUNT = $Account
    $env:WALLET = $Sender

    # 0. lREACT for the reactive contract (deploy gas, its funding and reserves need ~2.5; more for -Retro).
    $minLreact = if ($Retro -and -not $env:RETRO_WIRED) { 3.0 } else { 2.5 }
    $lreact = Get-LasnaBalance
    Write-Host "`n== lREACT on Lasna: $lreact" -ForegroundColor Cyan
    if ($lreact -lt $minLreact) {
        Write-Host "Requesting 5 lREACT from the faucet (0.05 Base Sepolia ETH)..."
        & cast send $Faucet "request(address)" $Sender --value 0.05ether --rpc-url $BaseRpc
        if ($LASTEXITCODE -ne 0) { throw "Faucet request failed." }
        $deadline = (Get-Date).AddMinutes(10)
        while ((Get-LasnaBalance) -lt $minLreact) {
            if ((Get-Date) -gt $deadline) { throw "lREACT did not arrive in 10 minutes. Run the script again later." }
            Write-Host "  waiting for lREACT..."
            Start-Sleep -Seconds 10
        }
        Write-Host "  lREACT on Lasna: $(Get-LasnaBalance)" -ForegroundColor Green
    }

    if (-not $env:REF_POOL_ID) { Invoke-Step "1. Base Sepolia: reference pool" "script/01_ReferencePool.s.sol" "base_sepolia" }
    if (-not $env:REACTIVE) { Invoke-Step "2. Lasna: reactive contract" "script/02_Reactive.s.sol" "lasna" }
    if (-not $env:HOOK) { Invoke-Step "3. Unichain Sepolia: hook and protected pool" "script/03_HookAndPool.s.sol" "unichain_sepolia" }
    if (-not $env:WIRED) {
        Invoke-Step "4. Lasna: wire the reactive contract to the hook" "script/04_Wire.s.sol" "lasna"
        Save-Value "WIRED" "0x1"
    }

    if ($Verify) {
        Write-Host "`n== Verifying contracts on Sourcify" -ForegroundColor Cyan
        Invoke-Verify $env:REACTIVE "src/HikaeReactive.sol:HikaeReactive" 5318007
        Invoke-Verify $env:HOOK "src/HikaeHook.sol:HikaeHook" 1301
    }

    if ($Retro) {
        if (-not $env:RETRO_REACTIVE) {
            $env:PREFIX = "RETRO_"
            Invoke-Step "R1. Lasna: reactive contract for the retro hook" "script/02_Reactive.s.sol" "lasna"
            Remove-Item Env:PREFIX
        }
        if (-not $env:RETRO_HOOK) {
            Invoke-Step "R2. Unichain Sepolia: retro hook, its pool and the demo router" "script/06_RetroHookAndPool.s.sol" "unichain_sepolia"
        }
        if (-not $env:RETRO_WIRED) {
            $env:PREFIX = "RETRO_"
            Invoke-Step "R3. Lasna: wire the second reactive contract to the retro hook" "script/04_Wire.s.sol" "lasna"
            Remove-Item Env:PREFIX
            Save-Value "RETRO_WIRED" "0x1"
        }
        if ($Verify) {
            Invoke-Verify $env:RETRO_REACTIVE "src/HikaeReactive.sol:HikaeReactive" 5318007
            Invoke-Verify $env:RETRO_HOOK "src/HikaeRetroHook.sol:HikaeRetroHook" 1301
            Invoke-Verify $env:DEMO_ROUTER "test/mocks/MsgSenderRouter.sol:MsgSenderRouter" 1301
        }
        Write-Host "`n== Race demo: arbitrage ahead of the callback, and a swap before the move" -ForegroundColor Cyan
        & node latency/race.ts
        if ($LASTEXITCODE -ne 0) { throw "Race demo failed, see the output above. Run the script again to retry." }
        Write-Host "`nDone. Results in latency\race-*.json" -ForegroundColor Green
    } else {
        # 5. Move the price on Base and time each callback on Unichain.
        Write-Host "`n== 5. Full-loop latency, $Rounds rounds" -ForegroundColor Cyan
        $env:ROUNDS = "$Rounds"
        & node latency/measure.ts
        if ($LASTEXITCODE -ne 0) { throw "Latency run failed, see the output above." }
        Write-Host "`nDone. Addresses in $StateFile, latency results in latency\results-*.json" -ForegroundColor Green
    }
} finally {
    if (Test-Path $passwordFile) { Remove-Item $passwordFile -Force }
    Remove-Item Env:ETH_PASSWORD -ErrorAction SilentlyContinue
}
