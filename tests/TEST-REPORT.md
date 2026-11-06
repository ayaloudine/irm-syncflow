# Rapport de tests - IRM SyncFlow v0.3

## 1. Contexte

- Script testé : `scripts/AutoSaveGit.ps1` (Commit : `6d96d32`)
- Branche des tests : `feature/tests-v03`
- Environnement : Windows PowerShell 5.1, Pester 6.2.0, dépôts Git jetables
- Date : 06/11/2026

## 2. Résultats des 12 tests du PDF

| ID  | Scénario                     | Résultat | Ce que vérifie réellement le test                             |
| --- | ---------------------------- | -------- | ------------------------------------------------------------- |
| A   | Timer sur fichier suivi      | ✅ PASS  | 6 changements consécutifs = 1 seul commit après le délai.     |
| B   | Secrets (.env, .pem)         | ✅ PASS  | Fichiers absents de l'index et du commit.                     |
| C   | Fichier cassé                | ✅ PASS  | b.txt (erreur) exclu, a.txt commité.                          |
| D   | Push raté puis rattrapé      | ✅ PASS  | "Synchronisation réussie" au 2e cycle.                        |
| E   | Staging utilisateur          | ❌ FAIL  | Le script fait un `git reset` et détruit le `git add` manuel. |
| F   | Timer nouveau fichier        | ❌ FAIL  | Commit prématuré (edit 5) sans attendre la fin (edit 10).     |
| G   | Branche feature              | ✅ PASS  | Commit et push OK sur `feature/test-branch`.                  |
| H   | Aucun commit sans changement | ✅ PASS  | Le dépôt reste à 1 commit (init) si rien ne bouge.            |
| I   | Opération Git en cours       | ✅ PASS  | Commit annulé si `MERGE_HEAD` est présent.                    |
| J   | Fichier supprimé             | ✅ PASS  | La suppression est correctement commitée.                     |
| K   | Fichier ignoré               | ✅ PASS  | `__pycache__/` n'est pas commité (respect .gitignore).        |
| L   | Erreur Git sans perte        | ✅ PASS  | Le fichier `bad.txt` reste sur le disque malgré l'échec.      |

## 3. Bugs confirmés (À corriger par le développeur dans AutoSaveGit.ps1)

1. **Bug Staging (F05)** : Le script exécute `git reset` puis `git add -A`, et commite les fichiers que l'utilisateur avait stagés manuellement.
   - _Preuve Pester_ : Échec de E avec le message `Expected 'staged.txt' to be found...`.
   - _Log agent_ : `Staging résiduel détecté, nettoyage automatique...`

2. **Bug Fichiers non suivis** : Le timer ne repart pas quand un nouveau fichier (untracked) est modifié.
   - _Preuve Pester_ : Échec de F avec le message `Expected regular expression 'edit 10' to match 'edit 1 ... edit 5'`.

## 4. Limites

- Les tests utilisent uniquement des dépôts jetables (créés/supprimés par le helper).
- Aucun test n'a été effectué en conditions réelles (VS Code, Ctrl+S) ni sur un vrai projet.

## 5. Verdict

Le script est **non conforme** pour une utilisation en production tant que les bugs E et F ne sont pas corrigés.
