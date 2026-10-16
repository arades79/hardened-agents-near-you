# VSIX staging directory

Drop `.vsix` extension packages into this directory before running
`docker build`. Every `*.vsix` found here is installed into the image's
pre-installed VS Code Server at build time, using the server's own offline
extension CLI (`code-server --install-extension`).

Typical use on an air-gapped fleet:

1. On a connected machine, download the VSIX packages your team needs, e.g.
   from the marketplace's per-extension page ("Download Extension") or with
   `code --install-extension <id>` into a scratch profile followed by
   `~/.vscode-server/extensions`-style extraction - any `.vsix` file works.
2. Transfer them to the build host and copy them here.
3. Build: `docker build -t agent-ide-base:rocky9 .`

Notes:

- VSIX contents are **not** kept in the resulting image: the build copies this
  directory into a throwaway stage and mounts it read-only only while the
  extensions are installed. The files stay on the build host, which keeps the
  image (and the `docker save` archive you carry across the air gap) small.
- The build fails if a VSIX cannot be installed - better a loud failure at
  build time than a silently missing extension in an isolated environment.
- This file only exists so the directory is part of the build context. Removing
  it will break the build.
