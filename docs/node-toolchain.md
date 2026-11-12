# Node and npm for Blitz Neo

`config/node-toolchain.json` is the canonical toolchain definition: exact Node LTS
and npm versions plus checksums of their official release archives. Build scripts,
the GitHub setup action and the installed runtime use this same file. The signed
app carries a copy at `Contents/Resources/node-toolchain.json`.

Blitz does not follow a moving `current` or `latest` alias. A system runtime is
reused for builds only when both executable versions match the manifest. The
private runtime at `~/.blitz/node-runtime` keeps the installed iPhone MCP independent
of subsequent changes to the user's shell or version manager.

## Local builds

```bash
source scripts/node-toolchain.sh
blitz_resolve_node_toolchain config/node-toolchain.json
node --version
npm --version
bash scripts/build-iphone-mcp.sh
```

Selection order is an explicit `BLITZ_NODE_BIN`, the active Node binary's directory,
then the private Blitz runtime. An explicit incompatible override fails clearly;
it is never silently replaced. The resolver performs no installation or download.
`bundle.sh` and `build-pkg.sh` use the same validation.

The upstream ASC documentation website has its own Node configuration. Its
`website/.nvmrc` does not apply to the Swift app, Go helper or iPhone MCP. Leave
the pinned upstream checkout intact; an intentional website build follows that
website's instructions separately.

## Packaging and runtime updates

The maintained iPhone MCP is built from its pinned source and overlay. Its archive
must contain the exact dependency lock and source provenance. Installation uses
`npm ci` with dependency scripts disabled, explicitly builds the required native
`unix-dgram` addon, then checks that the addon and MCP can start with the selected
Node version. A successful npm command alone is insufficient.

The runtime installer downloads only the archives named by the manifest and
verifies their pinned checksums before extraction. It prepares Node, npm and the
maintained MCP together in a separate directory. The existing runtime is exchanged
only after those checks pass and remains available as a rollback directory.
Existing Node processes are not killed. Clients use the new runtime when they next
start their MCP connection.

For a toolchain update, verify the Node release's LTS status, choose the exact
Node/npm pair, and update versions, URLs and checksums together in the manifest.
Run the offline installer and packaging regressions, a real staged installation,
native-addon loading and MCP initialization, followed by the app's regression
checks and signed release build. The GitHub workflows consume the same manifest;
their existing free-runner restrictions remain in force.
