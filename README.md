# Navidrome on Azure Container Apps

This project deploys the official Navidrome container to Azure Container Apps and syncs a selected OneDrive folder into Azure Files with rclone. Navidrome scans the Azure Files copy; it does not mount OneDrive directly. The sync job reads OneDrive and writes only to Azure.

## What gets created

- One Azure Container Apps environment with a system-assigned identity.
- One public HTTPS Navidrome app, scaled to zero while idle and limited to one replica. Its Azure Files data mount uses `nobrl` to avoid SMB lock conflicts with Navidrome's SQLite database.
- Three private Azure Files shares: music, Navidrome state, and the rclone configuration.
- A scheduled rclone job, created only after OneDrive authorization, that mirrors supported audio and companion files every six hours; Navidrome rescans the library hourly.
- A free Azure-managed TLS certificate after the custom-domain DNS records are configured.
- Two small wrapper images, built by GitHub Actions from the official Navidrome and rclone images, that run as a non-root user.

Azure Storage is configured for standard locally redundant storage with public blob access disabled. Files are encrypted at rest. The Container Apps environment uses managed identity to mount shares; no Azure storage key is saved in this repository. Azure Storage capacity, network transfer, and any active Container Apps compute are billable. The app scales to zero when idle. Review Azure pricing for your region and expected library size before running the deployment.

## Prerequisites

- Windows PowerShell, Azure CLI with permission to create resources and assign an Azure role, and Git.
- An Azure subscription selected with `az account set`.
- rclone installed locally for the OneDrive OAuth setup.
- A GitHub CLI sign-in to `michaelsrichter` to publish the public repository.
- DNS access for `mikerichter.app` at Namecheap.

No Azure, GitHub, or OneDrive credentials belong in this repository. The image workflow uses GitHub's short-lived built-in `GITHUB_TOKEN`; no repository secret is required. `.deployment.local.json` contains only resource names and is ignored by Git.

## Deploy the app

From the repository folder:

```powershell
az login
az account set --subscription "<your subscription>"
.\scripts\deploy.ps1 -Location eastus2
```

The script asks for a typed `DEPLOY` confirmation before creating resources. It writes the generated storage account name and resource names to the ignored `.deployment.local.json` file so later commands use the same deployment.

The public image package must exist before deployment. Push the repository's `main` branch and wait for the **Publish container images** workflow to finish successfully; on the first run, verify the `navidrome-onedrive` package in GitHub is public.

User registration is disabled in this deployment. Create the first administrator from an Azure Container Apps terminal so the password stays out of chat:

```powershell
az containerapp exec --name navidrome-music --resource-group rg-navidrome-onedrive
```

In the container shell, run `navidrome --datafolder /data --nobanner user create --username <your-user> --admin` and enter the password at its prompt. The login page will not accept an account until this administrator exists.

## Navidrome plugins

The Navidrome image includes two pinned, MIT-licensed community plugins. Versions and source commits are in `infra/plugins.json`; `scripts/build-plugins.sh` verifies the lyrics package checksum and builds the cover-art plugin against the same Navidrome PDK version as the server. GitHub Actions runs this build before publishing the image. License notices are included in the repository and image.

- **nd-lyrics** fetches lyrics from LRCLIB and lyrics.ovh. The Navidrome web UI does not display plugin lyrics; use a compatible Subsonic client. Lyrics are not written to music files: the plugin is configured read-only, and the music share is mounted read-only.
- **coverartarchive** looks up album artwork through MusicBrainz and the Cover Art Archive. It is last in the metadata-agent order, so it acts as a fallback after the configured built-in agents.

After the image is published and deployed, use the Navidrome plugin UI or its CLI to enable the installed plugins. The CLI is available in the container:

```sh
navidrome --datafolder /data --nobanner plugin rescan
navidrome --datafolder /data --nobanner plugin enable coverartarchive
navidrome --datafolder /data --nobanner plugin edit nd-lyrics \
  --config '{"lyricsFormats":"ttml,elrc,lyricsfile,lrc,srt,plain","providersList":[{"provider":"lrclib"},{"provider":"lyrics.ovh"}],"providerMode":"priority","writeLyrics":false,"enableCache":true}' \
  --all-users --all-libraries --no-write-access
navidrome --datafolder /data --nobanner plugin enable nd-lyrics
```

The `nd-lyrics` plugin requests broad outbound HTTP access for its provider support; its file-writing capability remains disabled. **AudioMuse-AI is not installed:** its Navidrome plugin requires a separate core service, worker, PostgreSQL database, and a library analysis.

## Connect your personal OneDrive

1. Install rclone from [rclone.org/downloads](https://rclone.org/downloads/).
2. Run `rclone config` locally. Create a remote named `onedrive`, choose Microsoft OneDrive, and sign in to your **personal Microsoft account** in the browser. Do not send your password, OAuth token, or `rclone.conf` to anyone.
3. For least-privilege read-only access, create a Microsoft app registration that supports personal Microsoft accounts, use the redirect URI `http://localhost:53682/`, add delegated `Files.Read`, `offline_access`, and `User.Read` permissions, and set rclone's `access_scopes` to `Files.Read` before authorizing. Enter the app ID and secret only in rclone's local prompts. The shared rclone app may request broader access. Never configure application-only access for this personal library.
4. Run `.\scripts\connect-onedrive.ps1`. It lists top-level folders locally, asks for the music folder path, confirms the mirror behavior, uploads the private rclone configuration directly to the Azure Files share, creates the scheduled job, and starts the first sync.

The script requires the rclone remote name `onedrive` by default; use `-RemoteName` if you named it differently. A folder path is required so the whole OneDrive is never synced accidentally. Supported audio extensions and common artwork, playlist, cue-sheet, and lyric files are included; other OneDrive files are excluded. Because the job uses `rclone sync`, deleting a file from the selected OneDrive folder also removes its Azure copy on the next run. The job never writes back to OneDrive.

The rclone configuration contains refresh tokens. It stays out of Git and is stored in the private Azure Files config share. The connection script grants your Azure identity the file-data role needed to upload that file to the config share without using a storage key. Re-run the connection script after changing the local rclone configuration or the selected folder.

## Custom domain

The app is initially available at its Azure Container Apps hostname. Run:

```powershell
.\scripts\show-domain-records.ps1
```

Add the displayed CNAME and TXT records in Namecheap Advanced DNS. After they resolve publicly, run:

```powershell
.\scripts\bind-domain.ps1
```

The script requests an Azure-managed certificate and binds `https://music.mikerichter.app`.

## Updates

Update the pinned upstream versions in `infra/images.json`, then push to `main`. GitHub Actions builds and publishes the non-root images with versioned tags. After that workflow succeeds, run:

```powershell
.\scripts\update.ps1
```

To override versions without editing the file:

```powershell
.\scripts\update.ps1 -NavidromeImage "navidrome/navidrome:<tag>" -RcloneImage "rclone/rclone:<tag>"
```

After the first image workflow completes, open the `navidrome-onedrive` package under your GitHub profile and set its visibility to **Public** if GitHub created it as private. Azure must be able to pull these images without a registry credential.

The deployment uses thin non-root wrappers around the official upstream container images; this repository contains no Navidrome or rclone application source.
