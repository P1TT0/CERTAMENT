CERTAMENT deployment assets

Contents:
- customer-manifest.example.json : example deployment inventory used by CD pipeline
- release-notes\                : placeholder folder for version-specific release notes

Intended flow:
1. Copy customer-manifest.example.json to a secured real manifest outside the public repo or to a protected variable/file in the pipeline.
2. Keep real tenant/subscription/server metadata out of broad-access repositories.
3. Use rings to control rollout order: 0 -> 1 -> 2 -> 3.

Recommended next step:
- Create a real customer-manifest.json in a protected internal location and wire the CD pipeline to that source.