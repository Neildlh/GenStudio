# Security policy

## Supported versions

Security support applies to the current `main` branch only.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability, leaked credential, signing-material exposure, or privacy problem. Use GitHub's private vulnerability-reporting feature when it is enabled for this repository. If it is not available, contact the repository owner through GitHub before publishing details.

Please include a clear reproduction, affected commit, impact, and any safe mitigation you found. Do not attach secrets, private model files, personal media, Apple certificates, provisioning profiles, or keys.

## Scope

GenStudio is local-first. Important report areas include unsafe child-process execution, path traversal, model/archive verification, workflow import/export, provenance records, runtime-bootstrap downloads, and accidental credential logging. Third-party models and their publishers' hosted services have their own security channels.
