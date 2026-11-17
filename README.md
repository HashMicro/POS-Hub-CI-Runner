# POS Hub CI Runner

Dedicated GitHub Actions CI Runner repository for compiling **Android** (.apk) and **Windows** (.exe installer / Release.zip) builds orchestrated by **POS Hub**.

## Structure

- .github/workflows/pos-hub-build.yml: Main workflow triggered via workflow_dispatch or epository_dispatch (pos-hub-build) without requiring code commits.
- scripts/windows-build.ps1: Build and client-identity patching script supporting hmx, pos_logger, and capacitor app types.

## Required GitHub Actions Secrets

Configure the following secrets in **Settings -> Secrets and variables -> Actions**:

| Secret Name | Description |
|---|---|
| POSHUB_GIT_CLONE_USERNAME | Username for GitLab source repository clone (default: oauth2) |
| POSHUB_GIT_CLONE_TOKEN | Personal Access Token / Deploy Token with read access to git.hashmicro.com POS repositories |
