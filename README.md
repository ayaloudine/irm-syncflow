# IRM SyncFlow

**Automatic Project Backup & GitHub Sync**

*Code freely. Sync automatically. Never lose your progress.*

IRM SyncFlow is an open-source tool designed to automate Git backups for software development projects on Windows.

## Features

- Automatic detection of project changes
- Configurable inactivity delay before backup
- Automatic Git commits
- Automatic synchronization with GitHub
- Retry handling for network failures
- Logging for backup operations and errors

## Technologies

- PowerShell
- Git
- GitHub CLI
- Windows 11
- Visual Studio Code

## How It Works

IRM SyncFlow monitors a configured Git repository. When file changes stop for a specified period, it creates a Git commit and attempts to push the changes to GitHub.

## Project Status

🚧 Under development.

## Security

Never commit passwords, API keys, access tokens, or other sensitive information. Review your `.gitignore` file before enabling automatic backups.

**Important:** GitHub synchronization is not a replacement for an independent backup.

## License

This project will be released under the MIT License.