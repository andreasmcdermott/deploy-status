# Deploy Status

A native macOS menu bar app for following GitHub deployments. Each row tracks a GitHub deployment environment or an Actions workflow. Click a row for the commit, workflow link, and last observed success and failure times.

## Run on your Mac

Requires macOS 14 or later. For a source build, install Xcode 15 or later and run:

```sh
./scripts/build-app.sh
open "dist/Deploy Status.app"
```

The app appears as a shipping box in the menu bar. Open **Connect GitHub…** to get started. You can move the app to Applications and add it in **System Settings → General → Login Items** if you want it to start at login.

## Connect GitHub once

Choose **Connect GitHub… → Account** and pick a method.

- **GitHub CLI** uses your existing github.com login on this Mac. Select **Use GitHub CLI**. If you need to sign in first, run `gh auth login --hostname github.com --web` in Terminal. Deploy Status reads the selected account’s token from the CLI when it needs to contact GitHub and saves the account name for future sessions. Signing out of Deploy Status leaves your CLI login available.
- **Personal token** accepts a fine-grained personal access token. Select your work organization as resource owner, select the repositories you follow, and give **Deployments** read-only access. Paste the token into the secure field and connect. Deploy Status stores it in your login Keychain. Your organization’s token approval and SSO policies apply.
- **GitHub App** uses a separately registered client with device flow. If your team already has an installation, enter its client ID. Registration instructions are below.

After connecting, choose **Services → Add service** and select a repository. Under **Workflow**, search by name or YAML filename and check one or more workflows. Your selections carry across searches. Click **Follow workflow** or **Follow N workflows** to add them together. To change a display name later, open **Services**, click **•••** beside the item, and choose **Rename…**. The next time you add a service, the picker opens on your last repository if you still have access. Workflow rows show the outcome of the whole run, including runs across branches. In **Environment → Browse…**, choose a GitHub environment to track an individual rollout. Both lists include entries with no recent activity.

Fine-grained tokens and GitHub Apps need **Actions: read** to list workflows and runs, **Contents: read** to discover workflow inputs, **Deployments: read** to track rollouts, and **Environments: read** to browse environments. You can also enter the exact name of a previously deployed environment with Deployments access alone.

### Optional GitHub App registration

1. Use an existing Deploy Status GitHub App client ID if your team has one. Otherwise register a GitHub App under the account or organization that owns your repositories. Choose a unique name and provide a homepage URL. Under **Identifying and authorizing users**, enable **Device Flow**. Leave token expiration enabled. Disable the webhook.
2. Grant the **Deployments** repository permission **Read-only**. GitHub includes read-only Metadata. A private app can be installed on its owner's account. If your app and repositories belong to different accounts, the app must allow installation on the target account. An organization owner may need to approve installation.
3. From the app's GitHub settings, choose **Install App**, select the destination account, and grant access to the repositories you want to follow.
4. Copy the **Client ID** from the app's General settings into **Deploy Status → Account**. Select **Sign in with GitHub**, then **Copy code and open GitHub**. Paste the one-time code and approve access. The Mac app refreshes expiring credentials locally. It stores tokens in your login Keychain.

Each installation can share its public client ID. To include it in a build, set `DEPLOY_STATUS_CLIENT_ID` when running the build script. The local release is ad-hoc signed. Set `CODE_SIGN_IDENTITY` to sign with your own identity.

[Register a GitHub App](https://github.com/settings/apps/new) · [GitHub device flow](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app#using-the-device-flow)

## Filter workflow runs

Open **Services → ••• → Filter runs…** beside a workflow. The app reads its `on.workflow_dispatch.inputs` definition from the default branch. Choice and boolean inputs get a picker. Text, number, and environment inputs accept a value. For **Zero - Deploy API**, select **Environment equals → production**. **Force equals** is available independently. Select **All runs** to clear a filter.

Input discovery requires repository **Contents: read** in addition to **Actions: read**. GitHub CLI uses its existing repository access. Title filtering remains available with Actions access alone.

For each manual run, the app reads the workflow version at that commit. It matches values confirmed by the published run title, an executed conditional step, or runner-printed lines from a completed job that match the workflow script. GitHub’s run API does not return the original dispatch payload. A default, an ambiguous expression, an expired log, or a masked value cannot confirm a match. A workflow that never exposes an input value may offer the input in the picker and have no confirmed matches. **Run title contains** filters published titles across all trigger types.

## Shortcut environments

These records in `useshortcut/monorepo` matched the example deployments:

| Service | Environment | GitHub environment to follow |
| --- | --- | --- |
| graphql | staging | backend-graphql-staging |
| korey-ai-api | production | backend-korey-ai-api-production |
| shortcut-frontend | production | shortcut-frontend-production |
| korey-async-worker | production | backend-korey-async-worker-production |

## What the status means

The newest deployment determines the headline. Queued, waiting, and in-progress states stay distinct. If an earlier observed deployment is still active, its count appears under the latest attempt. Times come from GitHub deployment-status records and display in local time. The Actions job or environment that publishes those records determines what counts as a successful rollout. For services that only publish workflow runs, choose Workflow when adding the service.

The app polls about once per minute when idle or every 15 seconds while a followed deployment is active. It shares the recent deployment list across services in the same repository, refreshes on wake, and backs off when GitHub requests it. An unsuccessful refresh leaves the last reading and check time visible. The latest confirmed success and failure persist as newer attempts arrive. Initial history loads in small batches, so an older outcome can appear after later refreshes.

Notifications are off by default. Open **Manage services…** in the menu bar panel’s options menu. In **Services**, open the options beside a service and select **Failed** for failures only, or select any combination of transitions. The first reading establishes a quiet baseline. Later polls can report transitions that occurred between checks.

The watchlist and timestamps are stored in `~/Library/Application Support/Deploy Status/Watchlist.json`. Signing out removes local credentials and pauses polling. You can also revoke the relevant token or app authorization in your GitHub account settings.

Run `swift test` for the deployment, polling, and OAuth tests.
