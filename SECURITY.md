# Security policy

Report vulnerabilities through [GitHub Private Vulnerability Reporting](https://github.com/xx3-bot/umi-capture/security/advisories/new),
with the affected commit, reproducible steps, impact, and any proposed mitigation.
Avoid posting vulnerability details in public issues. If the private reporting
form is unavailable, request that maintainers enable it without disclosing the
vulnerability publicly. Do not include real capture data,
pairing tokens, Apple credentials, or signing material.

UMI Capture's Receiver is designed for a trusted isolated LAN, not direct Internet
exposure. Treat pairing tokens, upload authorization state, capture ZIPs, and
hardware calibration profiles as sensitive. The public source Receiver fails
closed on stale authorization state, unauthorized uploads, unsafe envelope file
names, declared whole-file size mismatch, and whole-file SHA-256 mismatch. It
does not inspect ZIP contents and therefore does not validate malformed archives,
duplicate entries, symlinks, internal orientation, artifact declarations, or
coordinate transforms. Treat every committed ZIP as unvalidated input; the
downstream package validator and historical importer are not included.
