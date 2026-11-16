# rmm

`main` auto-syncs to production. Before merging anything from the `always-on`
work, run `scripts/check-placeholders.sh`: it fails while any `SEAL-ME-`
SealedSecret placeholder (filled by `scripts/seal-rmm-keys.sh`) or `REPLACE-`
value is left. Offsite database backups come later (R2 bucket).
