
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [int]$IdleSeconds = 10
)

# Vérifier que le dossier du projet existe
if (-not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) {
    Write-Host "Erreur : le dossier du projet n'existe pas." -ForegroundColor Red
    exit 1
}

# Vérifier que Git est installé
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Erreur : Git n'est pas installé ou accessible." -ForegroundColor Red
    exit 1
}

# Vérifier que le dossier est un dépôt Git
git -C $RepositoryPath rev-parse --is-inside-work-tree

if ($LASTEXITCODE -ne 0) {
    Write-Host "Erreur : ce dossier n'est pas un dépôt Git." -ForegroundColor Red
    exit 1
}

Write-Host "Dépôt Git valide !" -ForegroundColor Green
Write-Host "Délai avant sauvegarde : $IdleSeconds secondes."


function Test-GitChanges {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $changes = git -C $Path status --porcelain

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Erreur lors de la vérification Git." -ForegroundColor Red
        return $false
    }

    return ($changes.Count -gt 0)
}

function Wait-ForIdle {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [int]$Seconds = 10
    )

    Write-Host "Surveillance des modifications..." -ForegroundColor Cyan

    $lastChange = (git -C $Path status --porcelain) -join "`n"
    $lastActivity = Get-Date

    while ($true) {
        Start-Sleep -Seconds 1

        $currentChange = (git -C $Path status --porcelain) -join "`n"

        if ($currentChange -ne $lastChange) {
            $lastChange = $currentChange
            $lastActivity = Get-Date
            Write-Host "Modification détectée. Le délai repart à zéro."
        }

        if (((Get-Date) - $lastActivity).TotalSeconds -ge $Seconds) {
            Write-Host "Délai écoulé." -ForegroundColor Green
            return
        }
    }
}

function Test-GitOperationInProgress {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $gitDirectory = git -C $Path rev-parse --git-dir

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Impossible de trouver le dossier Git." -ForegroundColor Red
        return $true
    }

    $gitDirectory = Join-Path $Path $gitDirectory

    $operationFiles = @(
        "MERGE_HEAD",
        "REBASE_HEAD",
        "CHERRY_PICK_HEAD",
        "REVERT_HEAD"
    )

    foreach ($file in $operationFiles) {
        if (Test-Path (Join-Path $gitDirectory $file)) {
            Write-Host "Opération Git en cours : $file" -ForegroundColor Yellow
            return $true
        }
    }

    return $false
}

function Test-GitStagingAreaEmpty {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    git -C $Path diff --cached --quiet

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Zone de préparation vide." -ForegroundColor Green
        return $true
    }

    if ($LASTEXITCODE -eq 1) {
        Write-Host "Attention : des changements sont déjà préparés." -ForegroundColor Yellow
        return $false
    }

    Write-Host "Erreur pendant la vérification de la zone de préparation." -ForegroundColor Red
    return $false
}

function Invoke-AutoCommit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-GitOperationInProgress -Path $Path) {
        Write-Host "Commit annulé : une opération Git est en cours." -ForegroundColor Yellow
        return
    }

    if (-not (Test-GitStagingAreaEmpty -Path $Path)) {
        Write-Host "Commit annulé : la zone de préparation n'est pas vide." -ForegroundColor Yellow
        return
    }

    if (-not (Test-GitChanges -Path $Path)) {
        Write-Host "Aucune modification à sauvegarder."
        return
    }

    git -C $Path add -A

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Erreur lors de la préparation des fichiers." -ForegroundColor Red
        return
    }

    git -C $Path diff --cached --check

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Commit annulé : vérifie les espaces ou erreurs signalés." -ForegroundColor Yellow
        return
    }

    $message = "Auto-backup: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"

    git -C $Path commit -m $message

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Commit créé avec succès." -ForegroundColor Green
    }
    else {
        Write-Host "Échec de la création du commit." -ForegroundColor Red
    }
}

function Invoke-GitPush {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [int]$RetrySeconds = 5
    )

    $remotes = git -C $Path remote

    if ($LASTEXITCODE -ne 0 -or $remotes -notcontains "origin") {
        Write-Host "Erreur : aucun dépôt distant origin configuré." -ForegroundColor Red
        return $false
    }

    while ($true) {
        Write-Host "Envoi des commits vers GitHub..." -ForegroundColor Cyan

        git -C $Path push

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Synchronisation réussie." -ForegroundColor Green
            return $true
        }

        Write-Host "Échec de l'envoi. Nouvelle tentative dans $RetrySeconds secondes." -ForegroundColor Yellow
        Start-Sleep -Seconds $RetrySeconds
    }
}

function Invoke-GitPush {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [int]$RetrySeconds = 5,
        [int]$MaxRetries = 3
    )

    $remotes = git -C $Path remote

    if ($LASTEXITCODE -ne 0 -or $remotes -notcontains "origin") {
        Write-Host "Erreur : aucun dépôt distant origin configure." -ForegroundColor Red
        return $false
    }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        Write-Host "Tentative $attempt sur $MaxRetries..." -ForegroundColor Cyan

        git -C $Path push origin HEAD

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Synchronisation reussie." -ForegroundColor Green
            return $true
        }

        if ($attempt -lt $MaxRetries) {
            Write-Host "Echec de l'envoi. Nouvelle tentative dans $RetrySeconds secondes." -ForegroundColor Yellow
            Start-Sleep -Seconds $RetrySeconds
        }
    }

    Write-Host "Echec apres $MaxRetries tentatives. Les commits locaux sont conserves." -ForegroundColor Red
    return $false
}


