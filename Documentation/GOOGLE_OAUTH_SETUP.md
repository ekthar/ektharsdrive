# Google Drive setup

## Easiest: rclone's shared client

In Ekthar Drive choose **Google Drive > Connect**, leave "Use my own Google Cloud OAuth client" closed, and click **Sign in with Google**. Your browser opens Google's consent page. rclone receives the result on `http://127.0.0.1:53682` and stores the token in the app's encrypted rclone.conf. Ekthar Drive then calls the Drive API (`about`) and only reports success if that call works.

The shared client is used by many rclone users, so Google rate-limits it. For a 5 TB drive, use your own client.

## Recommended: your own OAuth client (about 5 minutes)

1. Open [Google Cloud Console](https://console.cloud.google.com/) and create a project, e.g. "Ekthar Drive".
2. Go to **APIs & Services > Library**, find **Google Drive API**, and click **Enable**.
3. Go to **APIs & Services > OAuth consent screen**:
   - User type: **External**. App name: Ekthar Drive. Add your e-mail as the support and developer contact.
   - Scopes: add `https://www.googleapis.com/auth/drive`. Full Drive scope is required to see files that Ekthar Drive did not create; `drive.file` would hide your existing files.
   - Test users: add your own Google account.
   - Publishing status: leaving it in **Testing** works for yourself. Tokens of apps in Testing expire after 7 days, so **Publish** it to avoid weekly re-sign-in. As a personal app you can ignore the verification prompt; you will see an "unverified app" warning during sign-in.
4. Go to **APIs & Services > Credentials > Create credentials > OAuth client ID**, with application type **Desktop app**.
5. Copy the **Client ID** and **Client secret** into Ekthar Drive (Connect sheet > "Use my own Google Cloud OAuth client"), then sign in.

## Disconnecting

**Settings > Accounts > Google Drive > Disconnect** sends the refresh token to `https://oauth2.googleapis.com/revoke`, deletes the remote from rclone.conf, and removes the client secret from the Keychain. You can also check [myaccount.google.com/permissions](https://myaccount.google.com/permissions).

## Troubleshooting

| Message | Fix |
|---|---|
| "Google rejected the saved sign-in" | The token was revoked or expired (common with a Testing-mode consent screen). Use Reconnect. |
| "Google rejected the OAuth client ID" | Check the ID/secret, and that the client type is *Desktop app*. |
| Browser did not open | Use the link shown in the sheet. It points at rclone's local listener on 127.0.0.1. |
| Port 53682 in use | Another rclone authorization is running. Close it and try again. |
