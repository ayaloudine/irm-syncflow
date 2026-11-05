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
        It ".env et id_rsa ne sont pas dans l'index ni dans le commit" {
            $r = New-TestRepo
            try {
                Set-Content -LiteralPath "$($r.Work)\.env"   -Value "API_KEY=secret"
                Set-Content -LiteralPath "$($r.Work)\id_rsa" -Value "fake-ssh-key"
                Add-Content -LiteralPath "$($r.Work)\a.txt"  -Value "valid"

                $null = Invoke-SyncCycle -Path $r.Work -IdleSeconds 1 `
                    -SensitivePatterns @('.env', 'id_rsa*') -HasRemote $false

                $tracked = @(git -C $r.Work ls-files)
                $tracked | Should -Contain     'a.txt'
                $tracked | Should -Not -Contain '.env'
                $tracked | Should -Not -Contain 'id_rsa'

                $changed = @(git -C $r.Work show --name-only --pretty=format: HEAD) |
                           Where-Object { $_ -ne '' }
                $changed | Should -Not -Contain '.env'
                $changed | Should -Not -Contain 'id_rsa'
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
}