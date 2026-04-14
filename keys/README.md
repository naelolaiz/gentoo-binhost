# Gentoo Binhost Signing Key — Placeholder

This file is a placeholder.  The actual signing key is stored as a GitHub
Actions secret (`GPG_PRIVATE_KEY`) and is **never** committed to the repository.

## Setting Up GPG Signing

### 1. Generate a dedicated signing key

```bash
gpg --batch --gen-key <<EOF
%no-protection
Key-Type: RSA
Key-Length: 4096
Subkey-Type: RSA
Subkey-Length: 4096
Name-Real: Gentoo Binhost
Name-Email: binhost@naelolaiz.github.io
Expire-Date: 2y
%commit
EOF
```

### 2. Export the private key (armored)

```bash
gpg --armor --export-secret-keys binhost@naelolaiz.github.io
```

Copy the output (including the `-----BEGIN PGP PRIVATE KEY BLOCK-----` header
and footer) into the GitHub repository secret named **`GPG_PRIVATE_KEY`**.

### 3. Set the passphrase secret

If you protected the key with a passphrase, store it in **`GPG_PASSPHRASE`**.
Leave the secret empty (or do not create it) for an unprotected key.

### 4. Export the public key for users

```bash
gpg --armor --export binhost@naelolaiz.github.io > keys/binhost-signing-key.asc
```

Commit this file so users can import the public key and verify packages:

```bash
gpg --import keys/binhost-signing-key.asc
```

### 5. (Optional) Store the key fingerprint

Set the GitHub Actions secret **`GPG_KEY_FINGERPRINT`** to the full 40-character
fingerprint printed by:

```bash
gpg --fingerprint binhost@naelolaiz.github.io
```

This is used by the build scripts when calling `--gpg-key`.

---

Once you have committed the **public** key as `keys/binhost-signing-key.asc`,
delete this `README.md` placeholder (or keep it for documentation).
