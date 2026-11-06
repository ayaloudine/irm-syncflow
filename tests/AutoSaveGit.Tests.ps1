# tests\AutoSaveGit.Tests.ps1
# Tests Pester v0.3 — scénarios A, B, C, D

BeforeAll {
    $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\AutoSaveGit.ps1"
    if (-not (Test-Path $scriptPath)) {
        throw "AutoSaveGit.ps1 introuvable : $scriptPath"
    }

    # Charger le script sans lancer la boucle ni les validations
    . $scriptPath -RepositoryPath $PSScriptRoot -NoLoop

    . (Join-Path $PSScriptRoot "helpers\New-TestRepo.ps1")
}

Describe "AutoSaveGit v0.3" {

    # --------------------------------------------------------
    Context "Test A - Le timer repart à chaque modification" {
        It "Une seule session de modifs continues = un seul commit" {
            $r = New-TestRepo
            try {
                # Modifs en arrière-plan toutes les 900 ms (8 modifs sur ~7 s)
                $job = Start-Job -ScriptBlock {
                    param($p)
                    for ($i = 1; $i -le 8; $i++) {
                        Add-Content "$p\a.txt" "edit $i"
                        Start-Sleep -Milliseconds 900
                    }
                } -ArgumentList $r.Work

                # Attendre la première modif
                $deadline = (Get-Date).AddSeconds(15)
                while ((Get-Date) -lt $deadline) {
                    if ((Get-Content "$($r.Work)\a.txt" -Raw) -match 'edit 1') { break }
                    Start-Sleep -Milliseconds 200
                }

                # 2 cycles de suite : le 2ᵉ ne doit rien trouver si le timer est correct
                $null = Invoke-SyncCycle -Path $r.Work -IdleSeconds 2 -SensitivePatterns @() -HasRemote $false
                $null = Invoke-SyncCycle -Path $r.Work -IdleSeconds 2 -SensitivePatterns @() -HasRemote $false

                Wait-Job $job -Timeout 30 | Out-Null
                Remove-Job $job -Force

                $commitCount = [int](git -C $r.Work rev-list --count HEAD)
                $commitCount | Should -Be 2   # 1 init + 1 backup
            }
            finally {
                Remove-TestRepo -Root $r.Root
            }
        }
    }

    # --------------------------------------------------------
        Context "Test B - Fichiers sensibles jamais commités" {
        It ".env, .env.local et server.pem ne sont pas dans l'index ni dans le commit" {
            $r = New-TestRepo
            try {
                # Créer des fichiers sensibles (qui ne sont PAS dans le .gitignore)
                Set-Content -LiteralPath "$($r.Work)\.env"       -Value "API_KEY=secret"
                Set-Content -LiteralPath "$($r.Work)\.env.local" -Value "LOCAL_KEY=secret"
                Set-Content -LiteralPath "$($r.Work)\server.pem" -Value "fake-pem"
                Add-Content -LiteralPath "$($r.Work)\a.txt"      -Value "valid"

                # Lancer un cycle
                $null = Invoke-SyncCycle -Path $r.Work -IdleSeconds 1 `
                    -SensitivePatterns @('.env', '.env.*', '*.pem') -HasRemote $false

                $tracked = @(git -C $r.Work ls-files)
                $tracked | Should -Contain     'a.txt'
                $tracked | Should -Not -Contain '.env'
                $tracked | Should -Not -Contain '.env.local'
                $tracked | Should -Not -Contain 'server.pem'

                $changed = @(git -C $r.Work show --name-only --pretty=format: HEAD) |
                           Where-Object { $_ -ne '' }
                $changed | Should -Not -Contain '.env'
                $changed | Should -Not -Contain '.env.local'
                $changed | Should -Not -Contain 'server.pem'
            }
            finally {
                Remove-TestRepo -Root $r.Root
            }
        }
    }

    # --------------------------------------------------------
    Context "Test C - Un fichier cassé ne bloque pas les autres" {
        It "b.txt avec erreur de format est exclu, a.txt est commité" {
            $r = New-TestRepo
            try {
                # Fichier avec espace en fin de ligne (erreur diff --check)
                "texte avec espace   " | Set-Content -LiteralPath "$($r.Work)\b.txt" -NoNewline
                Add-Content -LiteralPath "$($r.Work)\a.txt" -Value "valid"

                $null = Invoke-SyncCycle -Path $r.Work -IdleSeconds 1 `
                    -SensitivePatterns @() -HasRemote $false

                $changed = @(git -C $r.Work show --name-only --pretty=format: HEAD) |
                           Where-Object { $_ -ne '' }
                $changed | Should -Contain     'a.txt'
                $changed | Should -Not -Contain 'b.txt'

                # Anti-deadlock : une nouvelle modif doit passer
                Add-Content -LiteralPath "$($r.Work)\a.txt" -Value "after"
                $null = Invoke-SyncCycle -Path $r.Work -IdleSeconds 1 `
                    -SensitivePatterns @() -HasRemote $false

                $count2 = [int](git -C $r.Work rev-list --count HEAD)
                $count2 | Should -Be 3   # init + 2 backups
            }
            finally {
                Remove-TestRepo -Root $r.Root
            }
        }
    }

    # --------------------------------------------------------
    Context "Test D - Un push raté est rattrapé automatiquement" {
        It "Après retour du remote, les commits sont poussés" {
            $r = New-TestRepo -WithRemote
            try {
                # Casser le remote
                Rename-Item -LiteralPath $r.Remote -NewName "remote.git.off"
                Add-Content -LiteralPath "$($r.Work)\a.txt" -Value "offline"

                $r1 = Invoke-SyncCycle -Path $r.Work -IdleSeconds 1 `
                    -SensitivePatterns @() -HasRemote $true `
                    -PushRetrySeconds 1 -PushMaxRetries 1

                $r1.PushAttempted | Should -BeTrue
                $r1.PushSucceeded | Should -BeFalse
                $r1.UnpushedAfter | Should -BeGreaterThan 0

                # Restaurer le remote
                Rename-Item -LiteralPath "$($r.Remote).off" -NewName "remote.git"

                $r2 = Invoke-SyncCycle -Path $r.Work -IdleSeconds 1 `
                    -SensitivePatterns @() -HasRemote $true `
                    -PushRetrySeconds 1 -PushMaxRetries 2

                $r2.PushAttempted | Should -BeTrue
                $r2.PushSucceeded | Should -BeTrue

                $ahead = [int](git -C $r.Work rev-list --count 'origin/main..HEAD')
                $ahead | Should -Be 0
            }
            finally {
                Remove-TestRepo -Root $r.Root
            }
        }

    }

    # --------------------------------------------------------
    Context "Test E - Le staging de l'utilisateur est préservé" {
        It "Le fichier stagé reste stagé et n'est pas inclus dans le commit automatique" {
            $r = New-TestRepo
            try {
                Set-Content -LiteralPath "$($r.Work)\staged.txt" -Value "user manual staging"
                git -C $r.Work add staged.txt 2>&1 | Out-Null
                Add-Content -LiteralPath "$($r.Work)\a.txt" -Value "agent change"

                $null = Invoke-SyncCycle -Path $r.Work -IdleSeconds 1 -SensitivePatterns @() -HasRemote $false

                $staged = @(git -C $r.Work diff --cached --name-only)
                $staged | Should -Contain 'staged.txt'

                $changed = @(git -C $r.Work show --name-only --pretty=format: HEAD) |
                           Where-Object { $_ -ne '' }
                $changed | Should -Contain 'a.txt'
                $changed | Should -Not -Contain 'staged.txt'
            }
            finally { Remove-TestRepo -Root $r.Root }
        }
    }
    # --------------------------------------------------------
    Context "Test F - Le timer repart sur un fichier non suivi" {
        It "Un nouveau fichier modifié en continu est commité en entier, en un seul commit" {
            $r = New-TestRepo
            try {
                $job = Start-Job -ScriptBlock {
                    param($p)
                    for ($i = 1; $i -le 10; $i++) {
                        Add-Content "$p\untracked.py" "edit $i"
                        Start-Sleep -Milliseconds 700
                    }
                } -ArgumentList $r.Work

                # Attendre que le fichier existe avant de lancer le cycle
                $deadline = (Get-Date).AddSeconds(15)
                while (-not (Test-Path "$($r.Work)\untracked.py") -and (Get-Date) -lt $deadline) {
                    Start-Sleep -Milliseconds 200
                }

                $null = Invoke-SyncCycle -Path $r.Work -IdleSeconds 2 -SensitivePatterns @() -HasRemote $false

                Wait-Job $job -Timeout 20 | Out-Null
                Remove-Job $job -Force

                # Si le timer n'a pas repris, le commit part trop tôt et 'edit 10' manque
                $content = (git -C $r.Work show HEAD:untracked.py 2>$null) -join "`n"
                $content | Should -Match 'edit 10'
                @(git -C $r.Work status --porcelain).Count | Should -Be 0
            }
            finally { Remove-TestRepo -Root $r.Root }
        }
    }

    # --------------------------------------------------------
    Context "Test G - Fonctionne sur une branche autre que main" {
        It "Commit et push sur la branche feature/test-branch" {
            $r = New-TestRepo -WithRemote -BranchName "feature/test-branch"
            try {
                Add-Content -LiteralPath "$($r.Work)\a.txt" -Value "branch test"

                $null = Invoke-SyncCycle -Path $r.Work -IdleSeconds 1 -SensitivePatterns @() -HasRemote $true

                $branch = git -C $r.Work branch --show-current
                $branch | Should -Be "feature/test-branch"
                
                # Vérifier que le push a réussi sur la bonne branche
                $ahead = [int](git -C $r.Work rev-list --count 'origin/feature/test-branch..HEAD' 2>$null)
                $ahead | Should -Be 0
            }
            finally { Remove-TestRepo -Root $r.Root }
        }
    }

    # --------------------------------------------------------
    Context "Test H - Aucun commit sans changement" {
        It "Ne crée pas de commit si le dépôt est propre" {
            $r = New-TestRepo
            try {
                # On ne touche à rien, le dépôt est propre après l'init
                $null = Invoke-SyncCycle -Path $r.Work -IdleSeconds 1 -SensitivePatterns @() -HasRemote $false

                $commitCount = [int](git -C $r.Work rev-list --count HEAD)
                $commitCount | Should -Be 1 # Seulement le commit "init"
            }
            finally { Remove-TestRepo -Root $r.Root }
        }
    }

    # --------------------------------------------------------
    Context "Test I - Opération Git en cours" {
        It "Ne crée pas de commit pendant un merge" {
            $r = New-TestRepo
            try {
                # Simuler un merge en cours en créant le fichier MERGE_HEAD
                $gitDir = git -C $r.Work rev-parse --absolute-git-dir 2>$null
                "fake_merge_commit_hash" | Set-Content -LiteralPath "$gitDir\MERGE_HEAD"
                
                Add-Content -LiteralPath "$($r.Work)\a.txt" -Value "modif pendant merge"
                
                $null = Invoke-SyncCycle -Path $r.Work -IdleSeconds 1 -SensitivePatterns @() -HasRemote $false

                # Le commit doit être annulé
                $commitCount = [int](git -C $r.Work rev-list --count HEAD)
                $commitCount | Should -Be 1
            }
            finally { Remove-TestRepo -Root $r.Root }
        }
    }

        # --------------------------------------------------------
    Context "Test J - Prise en compte des suppressions" {
        It "Commit la suppression d'un fichier" {
            $r = New-TestRepo
            try {
                # Supprimer le fichier a.txt qui a été créé à l'init
                Remove-Item -LiteralPath "$($r.Work)\a.txt"
                
                $null = Invoke-SyncCycle -Path $r.Work -IdleSeconds 1 -SensitivePatterns @() -HasRemote $false

                # Vérifier que le fichier n'est plus suivi dans le dernier commit
                $changed = @(git -C $r.Work show --name-only --pretty=format: HEAD)
                $changed | Should -Contain 'a.txt' 
                # Vérifier que le fichier n'existe plus dans le dossier de travail
                Test-Path "$($r.Work)\a.txt" | Should -Be $false
            }
            finally { Remove-TestRepo -Root $r.Root }
        }
    }


    # --------------------------------------------------------
    Context "Test K - Fichiers ignorés" {
        It "Ne commit jamais un fichier listé dans .gitignore" {
            $r = New-TestRepo
            try {
                # Créer le dossier AVANT d'y mettre le fichier
                New-Item -ItemType Directory -Force -Path "$($r.Work)\__pycache__" | Out-Null
                Set-Content -LiteralPath "$($r.Work)\__pycache__\test.pyc" -Value "ignored"
                Add-Content -LiteralPath "$($r.Work)\a.txt" -Value "valid"
                
                $null = Invoke-SyncCycle -Path $r.Work -IdleSeconds 1 -SensitivePatterns @() -HasRemote $false

                # Vérifier que le fichier ignoré n'est pas dans le commit
                $changed = @(git -C $r.Work show --name-only --pretty=format: HEAD)
                $changed | Should -Not -Contain '__pycache__/test.pyc'
                $changed | Should -Contain 'a.txt'
            }
            finally { Remove-TestRepo -Root $r.Root }
        }
    }   

        # --------------------------------------------------------
    Context "Test L - Les erreurs Git ne détruisent pas les fichiers" {
        It "Le fichier reste présent sur le disque même si le commit échoue" {
            $r = New-TestRepo
            try {
                # Fichier avec une erreur de format (espace à la fin)
                "texte avec espace   " | Set-Content -LiteralPath "$($r.Work)\bad.txt" -NoNewline
                
                $null = Invoke-SyncCycle -Path $r.Work -IdleSeconds 1 -SensitivePatterns @() -HasRemote $false

                # Le commit échoue pour bad.txt, mais le fichier ne doit pas être supprimé du disque
                Test-Path "$($r.Work)\bad.txt" | Should -Be $true
            }
            finally { Remove-TestRepo -Root $r.Root }
        }
    }
    
}