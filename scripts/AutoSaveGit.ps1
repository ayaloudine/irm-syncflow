
param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [int]$IdleSeconds = 10
)

if (-not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) {
    Write-Host "Erreur : le dossier du projet n'existe pas." -ForegroundColor Red
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Erreur : Git n'est pas installé ou accessible." -ForegroundColor Red
    exit 1
}

git -C $RepositoryPath rev-parse --is-inside-work-tree | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Erreur : ce dossier n'est pas un dépôt Git." -ForegroundColor Red
    exit 1
}

Write-Host "Dépôt Git valide !" -ForegroundColor Green
Write-Host "Délai avant sauvegarde : $IdleSeconds secondes."

function Test-GitChanges {
    param([string]$Path)

    $changes = @(git -C $Path status --porcelain)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Erreur lors de la vérification Git." -ForegroundColor Red
        return $false
    }

    return ($changes.Count -gt 0)
}

function Wait-ForIdle {
    param(
        [string]$Path,
        [int]$Seconds = 10
    )

    Write-Host "Attente de stabilité des modifications..." -ForegroundColor Cyan
    $lastChange = (git -C $Path status --porcelain) -join "`n"
    $lastActivity = Get-Date

    while ($true) {
        Start-Sleep -Seconds 1
        $currentChange = (git -C $Path status --porcelain) -join "`n"

        if ($currentChange -ne $lastChange) {
            $lastChange = $currentChange
            $lastActivity = Get-Date
            Write-Host "Changement détecté : le délai repart à zéro."
        }

        if (((Get-Date) - $lastActivity).TotalSeconds -ge $Seconds) {
            Write-Host "Délai écoulé." -ForegroundColor Green
            return
        }
    }
}

function Test-GitOperationInProgress {
    param([string]$Path)

    $gitDirectory = git -C $Path rev-parse --absolute-git-dir
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Impossible de trouver le dossier Git." -ForegroundColor Red
        return $true
    }

    foreach ($file in @("MERGE_HEAD", "REBASE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD")) {
        if (Test-Path (Join-Path $gitDirectory $file)) {
            Write-Host "Opération Git en cours : $file" -ForegroundColor Yellow
            return $true
        }
    }

    return $false
}

function Invoke-AutoCommit {
    param([string]$Path)

    if (Test-GitOperationInProgress -Path $Path) {
        Write-Host "Commit annulé : une opération Git est en cours." -ForegroundColor Yellow
        return $false
    }

    git -C $Path diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Commit annulé : vérifie d'abord la zone de préparation Git." -ForegroundColor Yellow
        return $false
    }

    if (-not (Test-GitChanges -Path $Path)) {
        Write-Host "Aucune modification à sauvegarder."
        return $false
    }

    git -C $Path add -A
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Erreur lors de la préparation des fichiers." -ForegroundColor Red
        return $false
    }

    git -C $Path diff --cached --check
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Commit annulé : vérifie les erreurs signalées." -ForegroundColor Yellow
        return $false
    }

    $message = "Auto-backup: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    git -C $Path commit -m $message

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Commit créé avec succès." -ForegroundColor Green
        return $true
    }

    Write-Host "Échec de la création du commit." -ForegroundColor Red
    return $false
}

function Invoke-GitPush {
    param(
        [string]$Path,
        [int]$RetrySeconds = 5,
        [int]$MaxRetries = 3
    )

    $remotes = @(git -C $Path remote)
    if ($LASTEXITCODE -ne 0 -or $remotes -notcontains "origin") {
        Write-Host "Erreur : aucun dépôt distant origin configuré." -ForegroundColor Red
        return $false
    }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        Write-Host "Tentative $attempt sur $MaxRetries..." -ForegroundColor Cyan
        git -C $Path push origin HEAD

        if ($LASTEXITCODE -eq 0) {
            Write-Host "Synchronisation réussie." -ForegroundColor Green
            return $true
        }

        if ($attempt -lt $MaxRetries) {
            Write-Host "Échec de l'envoi. Nouvelle tentative dans $RetrySeconds secondes." -ForegroundColor Yellow
            Start-Sleep -Seconds $RetrySeconds
        }
    }

    Write-Host "Échec après $MaxRetries tentatives. Les commits locaux sont conservés." -ForegroundColor Red
    return $false
}

Write-Host "Surveillance automatique démarrée. Ctrl+C pour arrêter." -ForegroundColor Cyan

while ($true) {
    if (Test-GitChanges -Path $RepositoryPath) {
        Wait-ForIdle -Path $RepositoryPath -Seconds $IdleSeconds

        if (Test-GitChanges -Path $RepositoryPath) {
            $commitCreated = Invoke-AutoCommit -Path $RepositoryPath

            if ($commitCreated) {
                Invoke-GitPush -Path $RepositoryPath
            }
        }
    }

    Start-Sleep -Seconds 2
}
