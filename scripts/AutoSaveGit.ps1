param(
    [Parameter(Mandatory = $true)]
    [string]$RepositoryPath,

    [int]$IdleSeconds = 10,

    [string[]]$SensitivePatterns = @(
    '.env', '.env.*', '*.env',
    '*.key', '*.pem', '*.pfx', '*.p12',
    'id_rsa*', 'id_dsa*', 'id_ecdsa*', 'id_ed25519*',
    'secrets.*', 'credentials.*', '*secret*', '*password*'
    ),
    [int]$PushRetrySeconds = 5,

    [int]$PushMaxRetries = 3
)

# ============================================================
# VALIDATION INITIALE
# ============================================================
if (-not (Test-Path -LiteralPath $RepositoryPath -PathType Container)) {
    Write-Host "Erreur : le dossier du projet n'existe pas." -ForegroundColor Red
    exit 1
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Write-Host "Erreur : Git n'est pas installé ou accessible." -ForegroundColor Red
    exit 1
}

git -C $RepositoryPath rev-parse --is-inside-work-tree 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "Erreur : ce dossier n'est pas un dépôt Git." -ForegroundColor Red
    exit 1
}

Write-Host "Dépôt Git valide !" -ForegroundColor Green
Write-Host "Délai avant sauvegarde : $IdleSeconds secondes."

$remotes = @(git -C $RepositoryPath remote 2>$null)
if ($LASTEXITCODE -ne 0 -or $remotes -notcontains "origin") {
    Write-Host "Attention : aucun remote 'origin' configuré. Le push sera désactivé." -ForegroundColor Yellow
    $script:HasRemote = $false
} else {
    $script:HasRemote = $true
    Write-Host "Remote 'origin' détecté." -ForegroundColor Green
}

# ============================================================
# FIX BUG 1 : hash de contenu (pas juste status --porcelain)
# ============================================================
function Get-GitStateHash {
    param([string]$Path)

    $status   = (git -C $Path status --porcelain 2>$null) -join "`n"
    $unstaged = (git -C $Path diff 2>$null) -join "`n"
    $staged   = (git -C $Path diff --cached 2>$null) -join "`n"
    $combined = "$status|$unstaged|$staged"

    $bytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
    $sha   = [System.Security.Cryptography.SHA256]::Create()
    $hash  = $sha.ComputeHash($bytes)
    $sha.Dispose()

    return ([System.BitConverter]::ToString($hash) -replace '-', '')
}

function Test-GitChanges {
    param([string]$Path)

    $changes = @(git -C $Path status --porcelain 2>$null)
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
    $lastHash     = Get-GitStateHash -Path $Path
    $lastActivity = Get-Date

    while ($true) {
        Start-Sleep -Seconds 1
        $currentHash = Get-GitStateHash -Path $Path

        if ($currentHash -ne $lastHash) {
            $lastHash     = $currentHash
            $lastActivity = Get-Date
            Write-Host "Changement détecté : le délai repart à zéro."
        }

        if (((Get-Date) - $lastActivity).TotalSeconds -ge $Seconds) {
            Write-Host "Délai écoulé." -ForegroundColor Green
            return
        }
    }
}

# ============================================================
# DÉTECTION D'OPÉRATION GIT EN COURS
# ============================================================
function Test-GitOperationInProgress {
    param([string]$Path)

    $gitDirectory = git -C $Path rev-parse --absolute-git-dir 2>$null
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

# ============================================================
# FIX BUG 4 : détection de fichiers sensibles
# ============================================================
function Get-SensitiveFiles {
    param(
        [string]$Path,
        [string[]]$Patterns
    )

    $status    = @(git -C $Path status --porcelain 2>$null)
    $sensitive = @()

    foreach ($line in $status) {
        if ($line.Length -lt 4) { continue }

        $filePath = $line.Substring(3).Trim()

        if ($filePath -match ' -> (.+)$') {
            $filePath = $Matches[1]
        }
        $filePath = $filePath.Trim('"')

        $fileName = Split-Path -Leaf $filePath

        foreach ($pattern in $Patterns) {
            if ($fileName -like $pattern -or $filePath -like $pattern) {
                $sensitive += $filePath
                break
            }
        }
    }

    return $sensitive
}

# ============================================================
# FIX BUG 2 : reset propre en cas d'échec (anti-deadlock)
# ============================================================
function Reset-StagingSafely {
    param([string]$Path)

    git -C $Path reset 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-AutoCommit {
    param(
        [string]$Path,
        [string[]]$SensitivePatterns
    )

    if (Test-GitOperationInProgress -Path $Path) {
        Write-Host "Commit annulé : une opération Git est en cours." -ForegroundColor Yellow
        return $false
    }

    # Anti-deadlock : nettoyer un staging résiduel d'un cycle précédent
    git -C $Path diff --cached --quiet 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Staging résiduel détecté, nettoyage automatique..." -ForegroundColor Yellow
        if (-not (Reset-StagingSafely -Path $Path)) {
            Write-Host "Impossible de nettoyer le staging, cycle ignoré." -ForegroundColor Red
            return $false
        }
    }

    if (-not (Test-GitChanges -Path $Path)) {
        Write-Host "Aucune modification à sauvegarder."
        return $false
    }

    # Filtre des fichiers sensibles
        # Détection 1 : fichiers modifiés/nouveaux correspondant aux motifs
    $sensitive = Get-SensitiveFiles -Path $Path -Patterns $SensitivePatterns

    # Détection 2 : fichiers DÉJÀ trackés correspondant aux motifs (ex: .env committé par erreur)
    $tracked = @(git -C $Path ls-files 2>$null)
    foreach ($f in $tracked) {
        $fileName = Split-Path -Leaf $f
        foreach ($pattern in $SensitivePatterns) {
            if ($fileName -like $pattern -or $f -like $pattern) {
                if ($sensitive -notcontains $f) { $sensitive += $f }
                break
            }
        }
    }

        if ($sensitive.Count -gt 0) {
        Write-Host "Fichiers sensibles détectés, exclusion automatique :" -ForegroundColor Yellow
        foreach ($f in $sensitive) { Write-Host "  - $f" -ForegroundColor Yellow }
        Write-Host "Conseil : ajoute-les à ton .gitignore et retire-les de Git (git rm --cached)." -ForegroundColor Cyan
    }

    # Les fichiers sensibles ne sont jamais ajoutés à l'index
    $addArgs = @('add', '-A', '--', '.')
    foreach ($f in $sensitive) { $addArgs += ":(exclude,literal)$f" }
    git -C $Path @addArgs 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Erreur lors de la préparation des fichiers." -ForegroundColor Red
        $null = Reset-StagingSafely -Path $Path
        return $false
    }

    git -C $Path add -A 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Erreur lors de la préparation des fichiers." -ForegroundColor Red
        $null = Reset-StagingSafely -Path $Path
        return $false
    }

    git -C $Path diff --cached --quiet 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Rien à committer après filtrage."
        $null = Reset-StagingSafely -Path $Path
        return $false
    }

    # FIX C : exclure uniquement les fichiers fautifs, ne pas tout bloquer
    $checkRaw = git -C $Path diff --cached --check 2>&1
    if ($LASTEXITCODE -ne 0) {
        $problemFiles = @()
        foreach ($line in $checkRaw) {
            if ($line -match '^([^:]+):\d+:') { $problemFiles += $Matches[1].Trim() }
        }
        $problemFiles = $problemFiles | Select-Object -Unique
        foreach ($f in $problemFiles) {
            git -C $Path reset HEAD -- $f 2>&1 | Out-Null
            Write-Host "Fichier exclu (erreur de format) : $f" -ForegroundColor Yellow
        }
        git -C $Path diff --cached --quiet 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Host "Aucun fichier valide à committer ce cycle." -ForegroundColor Yellow
            return $false
        }
        Write-Host "Commit partiel : seuls les fichiers valides sont inclus." -ForegroundColor Cyan
    }

    $message = "Auto-backup: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    git -C $Path commit -m $message 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "Commit créé avec succès." -ForegroundColor Green
        return $true
    }

    Write-Host "Échec du commit. Nettoyage du staging..." -ForegroundColor Red
    $null = Reset-StagingSafely -Path $Path
    return $false
}

# ============================================================
# FIX BUG 3 : comptage des commits non envoyés
# ============================================================
function Get-UnpushedCommitCount {
    param([string]$Path)

    $count = git -C $Path rev-list --count '@{u}..HEAD' 2>$null
    if ($LASTEXITCODE -eq 0 -and $count) {
        return [int]$count
    }

    $count = git -C $Path rev-list --count 'origin/main..HEAD' 2>$null
    if ($LASTEXITCODE -eq 0 -and $count) {
        return [int]$count
    }

    return 0
}

function Invoke-GitPush {
    param(
        [string]$Path,
        [int]$RetrySeconds = 5,
        [int]$MaxRetries = 3
    )

    if (-not $script:HasRemote) {
        Write-Host "Push ignoré : pas de remote configuré." -ForegroundColor Yellow
        return $false
    }

    for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
        Write-Host "Tentative $attempt sur $MaxRetries..." -ForegroundColor Cyan
        git -C $Path push origin HEAD 2>&1 | Out-Null

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

# ============================================================
# CYCLE TESTABLE (refactor v0.2)
# ============================================================
function Invoke-SyncCycle {
    param(
        [string]$Path,
        [int]$IdleSeconds,
        [string[]]$SensitivePatterns,
        [bool]$HasRemote
    )

    $result = [PSCustomObject]@{
        HadChanges     = $false
        CommitCreated  = $false
        PushAttempted  = $false
        PushSucceeded  = $false
        UnpushedBefore = 0
        UnpushedAfter  = 0
    }

    # Étape 1 : attendre la stabilité puis committer
    if (Test-GitChanges -Path $Path) {
        $result.HadChanges = $true
        Wait-ForIdle -Path $Path -Seconds $IdleSeconds

        if (Test-GitChanges -Path $Path) {
            $result.CommitCreated = Invoke-AutoCommit -Path $Path -SensitivePatterns $SensitivePatterns
        }
    }

    # Étape 2 : rattraper TOUS les commits non envoyés (bug 3)
    if ($HasRemote) {
        $result.UnpushedBefore = Get-UnpushedCommitCount -Path $Path
        if ($result.UnpushedBefore -gt 0) {
            Write-Host "$($result.UnpushedBefore) commit(s) en attente d'envoi..." -ForegroundColor Cyan
            $result.PushAttempted = $true
            $result.PushSucceeded = Invoke-GitPush -Path $Path -RetrySeconds $PushRetrySeconds -MaxRetries $PushMaxRetries
            $result.UnpushedAfter = Get-UnpushedCommitCount -Path $Path
        }
    }

    return $result
}

# ============================================================
# BOUCLE PRINCIPALE
# ============================================================
Write-Host "Surveillance automatique démarrée. Ctrl+C pour arrêter." -ForegroundColor Cyan

while ($true) {
    try {
        $cycle = Invoke-SyncCycle -Path $RepositoryPath -IdleSeconds $IdleSeconds -SensitivePatterns $SensitivePatterns -HasRemote $script:HasRemote

        if ($cycle.PushAttempted -and $cycle.UnpushedAfter -eq 0) {
            Write-Host "Tout est synchronisé." -ForegroundColor Green
        } elseif ($cycle.PushAttempted) {
            Write-Host "Encore $($cycle.UnpushedAfter) commit(s) en attente." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Erreur cycle : $($_.Exception.Message)" -ForegroundColor Red
    }

    Start-Sleep -Seconds 2
}