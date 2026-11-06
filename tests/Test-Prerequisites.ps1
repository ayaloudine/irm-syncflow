# Test-AutoSaveGit.ps1
# Tests de base pour AutoSaveGit.ps1
# Ces tests utilisent un dépôt Git temporaire et ne publient rien sur GitHub.

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $projectRoot "scripts\AutoSaveGit.ps1"
$tempRepo = Join-Path $env:TEMP ("IRM-SyncFlow-Test-" + [guid]::NewGuid().ToString("N"))

$passed = 0
$failed = 0

function Assert-Test {
    param(
        [string]$Name,
        [bool]$Condition
    )

    if ($Condition) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
        $script:passed++
    }
    else {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        $script:failed++
    }
}

try {
    # TEST 1 : vérifier que le script existe.
    Assert-Test "Le script existe" (Test-Path -LiteralPath $scriptPath -PathType Leaf)

    if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
        throw "Le script AutoSaveGit.ps1 est introuvable."
    }

    # TEST 2 : analyser la syntaxe sans exécuter la surveillance.
    $tokens = $null
    $parseErrors = $null

    [System.Management.Automation.Language.Parser]::ParseFile(
        $scriptPath,
        [ref]$tokens,
        [ref]$parseErrors
    ) | Out-Null

    Assert-Test "La syntaxe PowerShell est valide" ($parseErrors.Count -eq 0)

    if ($parseErrors.Count -gt 0) {
        $parseErrors | Format-List Message, Extent
        throw "Corrige les erreurs de syntaxe avant de continuer."
    }

    # TEST 3 : créer un dépôt temporaire isolé.
    New-Item -ItemType Directory -Path $tempRepo | Out-Null

    git -C $tempRepo init -b main
    if ($LASTEXITCODE -ne 0) {
        throw "Impossible d'initialiser le dépôt temporaire."
    }

    git -C $tempRepo config user.name "IRM-SyncFlow Tests"
    git -C $tempRepo config user.email "tests@example.invalid"

    Set-Content -LiteralPath (Join-Path $tempRepo "README.md") `
        -Value "# Depot temporaire de test"

    git -C $tempRepo add README.md
    git -C $tempRepo commit -m "test: create temporary baseline"

    if ($LASTEXITCODE -ne 0) {
        throw "Impossible de créer le commit initial de test."
    }

    Assert-Test "Le dépôt temporaire est initialisé" (
        (git -C $tempRepo rev-parse --is-inside-work-tree) -eq "true"
    )

    # TEST 4 : un dépôt propre ne contient aucun changement.
    $before = @(git -C $tempRepo status --porcelain)
    Assert-Test "Le dépôt propre ne contient aucun changement" ($before.Count -eq 0)

    # TEST 5 : créer une modification et vérifier que Git la détecte.
    Set-Content -LiteralPath (Join-Path $tempRepo "test-change.txt") `
        -Value "Modification utilisée pour le test."

    $after = @(git -C $tempRepo status --porcelain)
    Assert-Test "Git détecte un nouveau fichier" ($after.Count -gt 0)

    # TEST 6 : vérifier qu'un fichier ignoré reste ignoré.
    Set-Content -LiteralPath (Join-Path $tempRepo ".gitignore") `
        -Value "secret-test.txt"

    Set-Content -LiteralPath (Join-Path $tempRepo "secret-test.txt") `
        -Value "Fichier factice ignoré."

    git -C $tempRepo check-ignore -q secret-test.txt
    Assert-Test "Git reconnaît le fichier ignoré" ($LASTEXITCODE -eq 0)

    # TEST 7 : vérifier que le dépôt temporaire n'a pas de remote.
    $remotes = @(git -C $tempRepo remote)
    Assert-Test "Le dépôt temporaire n'a aucun remote" ($remotes.Count -eq 0)

    # TEST 8 : vérifier qu'aucun commit automatique n'a été créé
    # par les tests eux-mêmes.
    $commitCount = [int](git -C $tempRepo rev-list --count HEAD)
    Assert-Test "Les tests préparatoires ne créent pas de commit automatique" ($commitCount -eq 1)

    Write-Host ""
    Write-Host "Résultat : $passed réussis ; $failed échoués." -ForegroundColor Cyan
    Write-Host "Attention : ces tests vérifient les prérequis Git, pas encore le cycle complet de sauvegarde automatique."

    if ($failed -gt 0) {
        exit 1
    }
}
catch {
    Write-Host "Erreur de test : $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    # Le dossier est uniquement temporaire et ne contient aucune donnée du projet.
    if (Test-Path -LiteralPath $tempRepo) {
        Remove-Item -LiteralPath $tempRepo -Recurse -Force
    }
}