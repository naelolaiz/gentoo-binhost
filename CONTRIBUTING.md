# Contributing

Changes to the package lists (`packages/tiers/`), the Portage configuration
(`config/profiles/`), the scripts or the workflows are welcome as pull
requests.

- Say in the pull request what the change is for.  For a configuration
  change, mention that machines using the binhost need the same setting to
  keep getting binaries for the affected packages.
- A workaround in `package.mask` or `package.use` needs an entry in
  `config/workarounds.json`, so that the weekly check reports when it can be
  removed.
- CI runs lint, the unit tests and the end-to-end test on every pull
  request.  [docs/TESTING.md](docs/TESTING.md) shows how to run them locally
  in containers.

Pre-built packages are not accepted: everything published here is built and
signed by the workflow.

Please be respectful.
