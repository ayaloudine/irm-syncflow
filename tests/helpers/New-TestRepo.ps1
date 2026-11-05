# tests\helpers\New-TestRepo.ps1
# Crée un dépôt Git jetable pour les tests Pester.

function New-TestRepo {
    param(
        [switch]$WithRemote
    )

    # PS 5.1 : avec EAP=Stop (imposé par Pester), tout stderr natif
    # devient une exception. On bascule en Continue le temps des git.
    $savedEAP = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    try {
        $root   = Join-Path $env:TEMP ("IRM-Test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        $work   = Join-Path $root "work"
        $remote = Join-Path $root "remote.git"

        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType Directory -Path $work -Force | Out-Null

        git -C $work init -b main 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git init a échoué" }

        git -C $work config user.name  "Test" 2>&1 | Out-Null
        git -C $work config user.email "test@example.invalid" 2>&1 | Out-Null

        Set-Content -LiteralPath "$work\a.txt"       -Value "init"
        Set-Content -LiteralPath "$work\.gitignore"  -Value ".env"
        git -C $work add -A 2>&1 | Out-Null
        git -C $work commit -m "init" 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git commit init a échoué" }

        if ($WithRemote) {
            git init --bare $remote 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git init --bare a échoué : $remote" }

            git -C $work remote add origin $remote 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git remote add a échoué" }

            git -C $work push -u origin main 2>&1 | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git push initial a échoué (code $LASTEXITCODE)" }
        }

        return [PSCustomObject]@{
            Root       = $root
            Work       = $work
            Remote     = if ($WithRemote) { $remote } else { $null }
            WithRemote = [bool]$WithRemote
        }
    }
    finally {
        $ErrorActionPreference = $savedEAP
    }
}

function Remove-TestRepo {
    param([string]$Root)
    if ($Root -and (Test-Path -LiteralPath $Root)) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}