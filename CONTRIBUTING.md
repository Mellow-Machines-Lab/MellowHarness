# Contributing

Issues and pull requests are welcome.

```sh
swift build
swift test
```

- **Foundation only.** The package has no dependencies, and keeps it
  that way.
- **Beacon's tests pin the worked example.** They check its log and
  prompts word for word, so a change to what Beacon prints or sends
  updates them in the same pull request.
- **Pull requests are squash-merged**, so the title becomes the commit
  message. Keep it a plain one-line summary.

For a security problem, see [SECURITY.md](SECURITY.md) instead.
