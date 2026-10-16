# Users and roles drift check (detection only)

Checks the users and roles on the Veeam Backup for Microsoft Azure appliance against files in `users/`. It **only reads** from the appliance. It never creates, changes or removes users, and it has no apply pipeline.

> Status: written but not yet run. The user-list response format is the part to confirm on first run.

## Files

```
scripts/Test-VbaUserDrift.ps1        the check (shares scripts/VbaCommon.ps1, which is unchanged)
users/*.json                         one file per user (desired state)
azure-pipelines/drift-check-users.yml  weekly pipeline
```

## What a user file looks like

```json
{
  "name": "<VBA-USERNAME>",
  "description": "Administrator account",
  "role": "PortalAdmin",
  "type": "Internal",
  "mfaEnabled": false
}
```

- Only the fields you list are compared. Leave a field out to ignore it.
- `role` is one of `PortalAdmin`, `PortalOperator`, `RestoreOperator`, `VeeamUpdater`, `IntegrationOperator`, `ReadOnlyUser`.
- `type` is `Internal` (local account) or `IdentityProvider` (SAML).
- Users are matched by **name**. Passwords are never stored or checked.
- The pipeline's own sign-in user (the one in Key Vault) must have MFA off, so the file for it should say `"mfaEnabled": false`.

## What is reported

| Result | Meaning |
|---|---|
| OK | The user exists and matches the file |
| DRIFT | A listed setting differs. Role, MFA and type are marked **SECURITY** in red and raised as pipeline errors |
| MISSING | A file exists but the user doesn't on the appliance |
| Unmanaged | A user exists on the appliance with no file. Raised as a pipeline warning and fails the run (`-FailOnUnmanaged`) |
| Hint | A missing user plus an unmanaged user with the same role may be a **rename** in the UI |

Exit codes: 0 clean, 1 drift or unmanaged, 2 missing or check failed.

## Set it up

1. **Capture a baseline** on your PC (read-only on the appliance; it writes local files only):

   ```powershell
   .\scripts\Test-VbaUserDrift.ps1 -Appliance <VBA-IP-ADDRESS> -ExportTo ./users
   ```

   It writes one JSON file per current user and never overwrites an existing file.
2. **Review the files.** Delete any user you don't want managed, and check each role is what it **should** be. The baseline records what is there today, which may include things you don't want.
3. **Run the check by hand** and confirm it reports every user as `OK`:

   ```powershell
   .\scripts\Test-VbaUserDrift.ps1 -Appliance <VBA-IP-ADDRESS> -FailOnUnmanaged
   ```

4. **Commit and push** `users/`, `scripts/Test-VbaUserDrift.ps1` and `azure-pipelines/drift-check-users.yml` to `main`.
5. Edit the `variables:` block in `drift-check-users.yml` to match your other pipelines.
6. In Azure DevOps create a pipeline from **Existing Azure Pipelines YAML file**, path `/azure-pipelines/drift-check-users.yml`, and name it `vba-user-drift-check`. Permit the service connection when asked.

## Test it

1. Run the pipeline. It should be green.
2. In the VBA portal change a user's role (use a test user). Run again: it should go red with a **SECURITY** message.
3. Create a new user in the portal. Run again: it should report an unmanaged user.
4. Rename a user: it should report a missing user, an unmanaged user and a rename hint.
5. Put everything back and confirm it returns to green.

## Limits

- Detection only. To fix a difference, change it in the portal, or change the file after a reviewed pull request.
- The repo is the source of truth. If someone edits both the portal and the file, the check reports OK. Protect `main` with required reviewers (branch policies), and limit who can edit the files in `users/`.
- Users are matched by name, so a rename shows as one missing user and one unmanaged user, not as drift.
- The check only knows the settings the API returns for a user: role, type, MFA, name and description.
