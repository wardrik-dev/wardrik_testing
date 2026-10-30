# Changelog

## 0.1.0-rc.1 (2026-10-30)

- `WardrikTesting.Server`, a `Wardrik.Server` that runs Wardrik's operations as a script, for
  packages that can't depend on Wardrik itself.
- A message to the test for each operation, stream, message and worker's tools.
- The protocol's example output for most operations. The `:offered` agents are listed and defined,
  and `acme/missing` is never found.
- `WardrikTesting.Script`, which answers messages in the conversation's log: `echo` waits on a
  call, `fail` fails, and anything else is answered.
- Handed to an HTTP surface or a channel as `{WardrikTesting.Server, name}`, as Wardrik passes
  itself.
